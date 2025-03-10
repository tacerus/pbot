# File: IgnoreList.pm
#
# Purpose: Manages ignore list.

# SPDX-FileCopyrightText: 2021 Pragmatic Software <pragma78@gmail.com>
# SPDX-License-Identifier: MIT

package PBot::IgnoreList;
use parent 'PBot::Class';

use PBot::Imports;

use Time::Duration qw/concise duration/;

sub initialize {
    my ($self, %conf) = @_;

    $self->{filename} = $conf{filename};

    $self->{storage} = PBot::DualIndexHashObject->new(pbot => $self->{pbot}, name => 'IgnoreList', filename => $self->{filename});
    $self->{storage}->load;
    $self->enqueue_ignores;

    $self->{pbot}->{commands}->register(sub { $self->cmd_ignore(@_) },   "ignore",   1);
    $self->{pbot}->{commands}->register(sub { $self->cmd_unignore(@_) }, "unignore", 1);

    $self->{pbot}->{capabilities}->add('admin', 'can-ignore',   1);
    $self->{pbot}->{capabilities}->add('admin', 'can-unignore', 1);

    $self->{pbot}->{capabilities}->add('chanop', 'can-ignore',   1);
    $self->{pbot}->{capabilities}->add('chanop', 'can-unignore', 1);
}

sub cmd_ignore {
    my ($self, $context) = @_;

    my ($target, $channel, $length) = $self->{pbot}->{interpreter}->split_args($context->{arglist}, 3);

    return "Usage: ignore <hostmask> [channel [timeout]] | ignore list" if not defined $target;

    if ($target =~ /^list$/i) {
        my $text = "Ignored:\n\n";
        my $now  = time;
        my $ignored = 0;

        foreach my $channel (sort $self->{storage}->get_keys) {
            $text .= $channel eq '.*' ? "global:\n" : "$channel:\n";
            my @list;
            foreach my $hostmask (sort $self->{storage}->get_keys($channel)) {
                my $timeout = $self->{storage}->get_data($channel, $hostmask, 'timeout');
                if ($timeout == -1) {
                    push @list, "  $hostmask";
                } else {
                    push @list, "  $hostmask (" . (concise duration $timeout - $now) . ')';
                }
                $ignored++;
            }
            $text .= join ";\n", @list;
            $text .= "\n";
        }
        return "Ignore list is empty." if not $ignored;
        return "/msg $context->{nick} $text";
    }

    if (not defined $channel) {
        $channel = ".*";    # all channels
    }

    if (not defined $length) {
        $length = -1;       # permanently
    } else {
        my $error;
        ($length, $error) = $self->{pbot}->{parsedate}->parsedate($length);
        return $error if defined $error;
    }

    return $self->add($channel, $target, $length, $context->{hostmask});
}

sub cmd_unignore {
    my ($self, $context) = @_;
    my ($target, $channel) = $self->{pbot}->{interpreter}->split_args($context->{arglist}, 2);
    if (not defined $target) { return "Usage: unignore <hostmask> [channel]"; }
    if (not defined $channel) { $channel = '.*'; }
    return $self->remove($channel, $target);
}

sub enqueue_ignores {
    my ($self) = @_;
    my $now    = time;

    foreach my $channel ($self->{storage}->get_keys) {
        foreach my $hostmask ($self->{storage}->get_keys($channel)) {
            my $timeout = $self->{storage}->get_data($channel, $hostmask, 'timeout');
            next if $timeout == -1; # permanent ignore

            my $interval = $timeout - $now;
            $interval = 0 if $interval < 0;

            $self->{pbot}->{event_queue}->enqueue_event(sub {
                    $self->remove($channel, $hostmask);
                }, $interval, "ignore_timeout $channel $hostmask"
            );
        }
    }
}

sub add {
    my ($self, $channel, $hostmask, $length, $owner) = @_;

    if ($hostmask !~ /!/) {
        $hostmask .= '!*@*';
    } elsif ($hostmask !~ /@/) {
        $hostmask .= '@*';
    }

    $channel = '.*' if $channel !~ /^#/;

    my $regex = quotemeta $hostmask;
    $regex =~ s/\\\*/.*?/g;
    $regex =~ s/\\\?/./g;

    my $data = {
        owner => $owner,
        created_on => time,
        regex => $regex,
    };

    if ($length < 0) {
        $data->{timeout} = -1;
    } else {
        $data->{timeout} = time + $length;
    }

    $self->{storage}->add($channel, $hostmask, $data);

    if ($length > 0) {
        $self->{pbot}->{event_queue}->dequeue_event("ignore_timeout $channel $hostmask");

        $self->{pbot}->{event_queue}->enqueue_event(sub {
                $self->remove($channel, $hostmask);
            }, $length, "ignore_timeout $channel $hostmask"
        );
    }

    my $duration = $data->{timeout} == -1 ? 'all eternity' : duration $length;
    return "$hostmask ignored for $duration";
}

sub remove {
    my ($self, $channel, $hostmask) = @_;

    if ($hostmask !~ /!/) {
        $hostmask .= '!*@*';
    } elsif ($hostmask !~ /@/) {
        $hostmask .= '@*';
    }

    $channel = '.*' if $channel !~ /^#/;

    $self->{pbot}->{event_queue}->dequeue_event("ignore_timeout $channel $hostmask");
    return $self->{storage}->remove($channel, $hostmask);
}

sub is_ignored {
    my ($self, $channel, $hostmask) = @_;

    return 0 if $self->{pbot}->{users}->loggedin_admin($channel, $hostmask);

    foreach my $chan ('.*', $channel) {
        foreach my $ignored ($self->{storage}->get_keys($chan)) {
            my $regex = $self->{storage}->get_data($chan, $ignored, 'regex');
            return 1 if $hostmask =~ /^$regex$/i;
        }
    }

    return 0;
}

1;
