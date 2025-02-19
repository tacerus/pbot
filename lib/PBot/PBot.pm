# File: PBot.pm
#
# Purpose: IRC Bot
#
# PBot was started around 2004, 2005. It has been lovingly maintained;
# however, it does use the ancient but simple Net::IRC package (if it
# ain't broke) instead of packages based on significantly more complex
# Enterprise-level event-loop frameworks. PBot uses pure Perl 5 blessed
# classes instead of something like Moo or Object::Pad, though this may
# change eventually.
#
# PBot has forked the Net::IRC package internally as PBot::IRC. It contains
# numerous bugfixes and supports various new features such as IRCv3 client
# capability negotiation and SASL user authentication.

# SPDX-FileCopyrightText: 2021 Pragmatic Software <pragma78@gmail.com>
# SPDX-License-Identifier: MIT

package PBot::PBot;

use PBot::Imports;

use Carp ();
use PBot::Logger;
use PBot::VERSION;
use PBot::AntiFlood;
use PBot::AntiSpam;
use PBot::BanList;
use PBot::BlackList;
use PBot::Capabilities;
use PBot::Commands;
use PBot::Channels;
use PBot::ChanOps;
use PBot::DualIndexHashObject;
use PBot::DualIndexSQLiteObject;
use PBot::EventDispatcher;
use PBot::EventQueue;
use PBot::Factoids;
use PBot::Functions;
use PBot::HashObject;
use PBot::IgnoreList;
use PBot::Interpreter;
use PBot::IRC;
use PBot::IRCHandlers;
use PBot::LagChecker;
use PBot::MessageHistory;
use PBot::Modules;
use PBot::MiscCommands;
use PBot::NickList;
use PBot::Plugins;
use PBot::ProcessManager;
use PBot::Registry;
use PBot::Refresher;
use PBot::SelectHandler;
use PBot::StdinReader;
use PBot::Updater;
use PBot::Users;
use PBot::Utils::ParseDate;
use PBot::WebPaste;

use Encode;
use File::Basename;

# set standard output streams to encode as utf8
binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

# decode command-line arguments from utf8
@ARGV = map { decode('UTF-8', $_, 1) } @ARGV;

sub new {
    my ($class, %args) = @_;
    my $self = bless {}, $class;
    $self->initialize(%args);
    return $self;
}

sub initialize {
    my ($self, %conf) = @_;

    $self->{startup_timestamp} = time;

    # process command-line arguments for path and registry overrides
    foreach my $arg (@ARGV) {
        if ($arg =~ m/^-?(?:general\.)?((?:data|module|plugin|update)_dir)=(.*)$/) {
            # check command-line arguments for directory overrides
            my $override = $1;
            my $value    = $2;
            $value =~ s/[\\\/]$//; # strip trailing directory separator
            $conf{data_dir}    = $value if $override eq 'data_dir';
            $conf{module_dir}  = $value if $override eq 'module_dir';
            $conf{update_dir}  = $value if $override eq 'update_dir';
        } else {
            # check command-line arguments for registry overrides
            my ($item, $value) = split /=/, $arg, 2;

            if (not defined $item or not defined $value) {
                print STDERR "Fatal error: unknown argument `$arg`; arguments must be in the form of `section.key=value` or `path_dir=value` (e.g.: irc.botnick=newnick or data_dir=path)\n";
                exit;
            }

            my ($section, $key) = split /\./, $item, 2;

            if (not defined $section or not defined $key) {
                print STDERR "Fatal error: bad argument `$arg`; registry entries must be in the form of section.key (e.g.: irc.botnick)\n";
                exit;
            }

            $section =~ s/^-//;    # remove a leading - to allow arguments like -irc.botnick due to habitual use of -args
            $self->{overrides}->{"$section.$key"} = $value;
        }
    }

    # make sure the paths exist
    foreach my $path (qw/data_dir module_dir update_dir/) {
        if (not -d $conf{$path}) {
            print STDERR "$path path ($conf{$path}) does not exist; aborting.\n";
            exit;
        }
    }

    # insist that data directory be copied
    if (basename($conf{data_dir}) eq 'data') {
        print STDERR "Data directory ($conf{data_dir}) cannot be named `data`. This is to ensure the directory is copied from its default location. Please follow doc/QuickStart.md.\n";
        exit;
    }

    # let modules register atexit subroutines
    $self->{atexit} = PBot::Registerable->new(pbot => $self, %conf);

    # register default signal handlers
    $self->register_signal_handlers;

    # prepare and open logger
    $self->{logger} = PBot::Logger->new(pbot => $self, filename => "$conf{data_dir}/log/log", %conf);

    # log command-line arguments
    $self->{logger}->log("Args: @ARGV\n") if @ARGV;

    # log configured paths
    $self->{logger}->log("module_dir: $conf{module_dir}\n");
    $self->{logger}->log("  data_dir: $conf{data_dir}\n");
    $self->{logger}->log("update_dir: $conf{update_dir}\n");

    # prepare the updater
    $self->{updater} = PBot::Updater->new(pbot => $self, data_dir => $conf{data_dir}, update_dir => $conf{update_dir});

    # update any data files to new locations/formats
    # --- this must happen before any data files are opened! ---
    if ($self->{updater}->update) {
        $self->{logger}->log("Update failed.\n");
        exit 0;
    }

    # create capabilities so commands can add new capabilities
    $self->{capabilities} = PBot::Capabilities->new(pbot => $self, filename => "$conf{data_dir}/capabilities", %conf);

    # create commands so the modules can register new commands
    $self->{commands} = PBot::Commands->new(pbot => $self, filename => "$conf{data_dir}/commands", %conf);

    # add 'cap' capability command here since $self->{commands} is created after $self->{capabilities}
    $self->{commands}->register(sub { $self->{capabilities}->cmd_cap(@_) }, "cap");

    # prepare the version information and `version` command
    $self->{version} = PBot::VERSION->new(pbot => $self, %conf);
    $self->{logger}->log($self->{version}->version . "\n");

    # prepare registry
    $self->{registry} = PBot::Registry->new(pbot => $self, filename => "$conf{data_dir}/registry", %conf);

    # ensure user has attempted to configure the bot
    if (not length $self->{registry}->get_value('irc', 'botnick')) {
        $self->{logger}->log("Fatal error: IRC nickname not defined; please set registry key irc.botnick in $conf{data_dir}/registry to continue.\n");
        exit;
    }

    # prepare the IRC engine
    $self->{irc} = PBot::IRC->new(pbot => $self);

    # prepare remaining core PBot modules -- do not change this order
    $self->{event_queue}      = PBot::EventQueue->new(pbot => $self, name => 'PBot event queue', %conf);
    $self->{event_dispatcher} = PBot::EventDispatcher->new(pbot => $self, %conf);
    $self->{users}            = PBot::Users->new(pbot => $self, filename => "$conf{data_dir}/users", %conf);
    $self->{antiflood}        = PBot::AntiFlood->new(pbot => $self, %conf);
    $self->{antispam}         = PBot::AntiSpam->new(pbot => $self, %conf);
    $self->{banlist}          = PBot::BanList->new(pbot => $self, %conf);
    $self->{blacklist}        = PBot::BlackList->new(pbot => $self, filename => "$conf{data_dir}/blacklist", %conf);
    $self->{channels}         = PBot::Channels->new(pbot => $self, filename => "$conf{data_dir}/channels", %conf);
    $self->{chanops}          = PBot::ChanOps->new(pbot => $self, %conf);
    $self->{factoids}         = PBot::Factoids->new(pbot => $self, filename => "$conf{data_dir}/factoids.sqlite3", %conf);
    $self->{functions}        = PBot::Functions->new(pbot => $self, %conf);
    $self->{refresher}        = PBot::Refresher->new(pbot => $self);
    $self->{ignorelist}       = PBot::IgnoreList->new(pbot => $self, filename => "$conf{data_dir}/ignorelist", %conf);
    $self->{irchandlers}      = PBot::IRCHandlers->new(pbot => $self, %conf);
    $self->{interpreter}      = PBot::Interpreter->new(pbot => $self, %conf);
    $self->{lagchecker}       = PBot::LagChecker->new(pbot => $self, %conf);
    $self->{misc_commands}    = PBot::MiscCommands->new(pbot => $self, %conf);
    $self->{messagehistory}   = PBot::MessageHistory->new(pbot => $self, filename => "$conf{data_dir}/message_history.sqlite3", %conf);
    $self->{modules}          = PBot::Modules->new(pbot => $self, %conf);
    $self->{nicklist}         = PBot::NickList->new(pbot => $self, %conf);
    $self->{parsedate}        = PBot::Utils::ParseDate->new(pbot => $self, %conf);
    $self->{plugins}          = PBot::Plugins->new(pbot => $self, %conf);
    $self->{process_manager}  = PBot::ProcessManager->new(pbot => $self, %conf);
    $self->{select_handler}   = PBot::SelectHandler->new(pbot => $self, %conf);
    $self->{stdin_reader}     = PBot::StdinReader->new(pbot => $self, %conf);
    $self->{webpaste}         = PBot::WebPaste->new(pbot => $self, %conf);

    # register command/factoid interpreters
    $self->{interpreter}->register(sub { $self->{commands}->interpreter(@_) });
    $self->{interpreter}->register(sub { $self->{factoids}->interpreter(@_) });

    # give botowner all capabilities
    # -- this must happen last after all modules have registered their capabilities --
    $self->{capabilities}->rebuild_botowner_capabilities;

    # fire all pending save events at exit
    $self->{atexit}->register(sub {
            $self->{event_queue}->execute_and_dequeue_event('save .*');
            return;
        }
    );
}

sub random_nick {
    my ($self, $length) = @_;
    $length //= 9;
    my @chars = ("A" .. "Z", "a" .. "z", "0" .. "9");
    my $nick  = $chars[rand @chars - 10];               # nicks cannot start with a digit
    $nick .= $chars[rand @chars] for 1 .. $length;
    return $nick;
}

# TODO: add disconnect subroutine and connect/disconnect/reconnect commands
sub connect {
    my ($self) = @_;
    return if $ENV{PBOT_LOCAL};

    if ($self->{connected}) {
        # TODO: disconnect, clean-up, etc
    }

    my $server  = $self->{registry}->get_value('irc', 'server');
    my $port    = $self->{registry}->get_value('irc', 'port');
    my $delay   = $self->{registry}->get_value('irc', 'reconnect_delay') // 10;
    my $retries = $self->{registry}->get_value('irc', 'reconnect_retries') // 10;

    $self->{logger}->log("Connecting to $server:$port\n");

    for (my $attempt = 0; $attempt < $retries; $attempt++) {
        my %config = (
            Nick        => $self->{registry}->get_value('irc', 'randomize_nick') ? $self->random_nick : $self->{registry}->get_value('irc', 'botnick'),
            Username    => $self->{registry}->get_value('irc', 'username'),
            Ircname     => $self->{registry}->get_value('irc', 'realname'),
            Server      => $server,
            Port        => $port,
            Pacing      => 1,
            UTF8        => 1,
            TLS         => $self->{registry}->get_value('irc', 'tls'),
            Debug       => $self->{registry}->get_value('irc', 'debug'),
            PBot        => $self,
        );

        # set TLS stuff
        my $tls_ca_file = $self->{registry}->get_value('irc', 'tls_ca_file');

        if (length $tls_ca_file and $tls_ca_file ne 'none') {
            $config{TLS_ca_file} = $tls_ca_file;
        }

        my $tls_ca_path = $self->{registry}->get_value('irc', 'tls_ca_path');

        if (length $tls_ca_file and $tls_ca_file ne 'none') {
            $config{TLS_ca_file} = $tls_ca_file;
        }

        # attempt to connect
        $self->{conn} = $self->{irc}->newconn(%config);

        # connection succeeded
        last if $self->{conn};

        # connection failed
        $self->{logger}->log("$0: Can't connect to $server:$port: $!\nRetrying in $delay seconds...\n");
        sleep $delay;
    }

    $self->{connected} = 1;

    # set up handlers for the IRC engine
    $self->{conn}->add_default_handler(sub { $self->{irchandlers}->default_handler(@_) }, 1);
    $self->{conn}->add_handler([251, 252, 253, 254, 255, 302], sub { $self->{irchandlers}->on_init(@_) });

    # ignore these events
    $self->{conn}->add_handler(
        [
            'myinfo',
            'whoisserver',
            'whoiscountry',
            'whoischannels',
            'whoisidle',
            'motdstart',
            'endofmotd',
            'away',
        ],
        sub { }
    );
}

sub register_signal_handlers {
    my ($self) = @_;

    $SIG{INT} = sub {
        my $msg = "SIGINT received, exiting immediately.\n";
        if (exists $self->{logger}) {
            $self->{logger}->log($msg);
        } else {
            print $msg;
        }
        $self->atexit;
        exit 0;
    };
}

# called when PBot terminates
sub atexit {
    my ($self) = @_;
    $self->{atexit}->execute_all;
    if (exists $self->{logger}) {
        $self->{logger}->log("Good-bye.\n");
    } else {
        print "Good-bye.\n";
    }
}

# convenient function to exit PBot
sub exit {
    my ($self, $exitval) = @_;
    $exitval //= 0;

    my $msg = "Exiting immediately.\n";

    if (exists $self->{logger}) {
        $self->{logger}->log($msg);
    } else {
        print $msg;
    }
    $self->atexit;
    exit $exitval;
}

# main loop
sub do_one_loop {
    my ($self) = @_;

    # do an irc engine loop (select, eventqueues, etc)
    $self->{irc}->do_one_loop;

    # invoke PBot events (returns seconds until next event)
    my $waitfor = $self->{event_queue}->do_events;

    # tell irc select loop to sleep for this many seconds
    # (or until its own internal eventqueue has an event)
    $self->{irc}->timeout($waitfor);
}

# main entry point
sub start {
    my ($self) = @_;

    $self->connect;

    while (1) {
        $self->do_one_loop;
    }
}

1;
