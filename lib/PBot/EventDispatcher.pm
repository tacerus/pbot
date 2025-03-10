# File: EventDispatcher.pm
#
# Purpose: Registers event handlers and dispatches events to them.
#
# Note: PBot::EventDispatcher has no relation to PBot::EventQueue.

# SPDX-FileCopyrightText: 2021 Pragmatic Software <pragma78@gmail.com>
# SPDX-License-Identifier: MIT

package PBot::EventDispatcher;
use parent 'PBot::Class';

use PBot::Imports;

sub initialize {
    my ($self, %conf) = @_;

    # hash table of event handlers
    $self->{handlers} = {};
}

# add an event handler
sub register_handler {
    my ($self, $event_name, $subref) = @_;

    # get the package of the calling subroutine
    my ($package) = caller(0);

    # internal identifier to find calling package's event handler
    my $handler_id = "$package-$event_name";

    # add the event handler
    $self->{handlers}->{$event_name}->{$handler_id} = $subref;

    # debugging
    if ($self->{pbot}->{registry}->get_value('eventdispatcher', 'debug')) {
        $self->{pbot}->{logger}->log("EventDispatcher: Add handler: $handler_id\n");
    }
}

# remove an event handler
sub remove_handler {
    my ($self, $event_name) = @_;

    # get the package of the calling subroutine
    my ($package) = caller(0);

    # internal identifier to find calling package's event handler
    my $handler_id = "$package-$event_name";

    # remove the event handler
    if (exists $self->{handlers}->{$event_name}) {
        delete $self->{handlers}->{$event_name}->{$handler_id};

        # remove root event-name key if it has no more handlers
        if (not keys %{$self->{handlers}->{$event_name}}) {
            delete $self->{handlers}->{$event_name};
        }
    }

    # debugging
    if ($self->{pbot}->{registry}->get_value('eventdispatcher', 'debug')) {
        $self->{pbot}->{logger}->log("EventDispatcher: Remove handler: $handler_id\n");
    }
}

# send an event to its handlers
sub dispatch_event {
    my ($self, $event_name, $event_data) = @_;

    # debugging flag
    my $debug = $self->{pbot}->{registry}->get_value('eventdispatcher', 'debug') // 0;

    # undef means no handlers have handled this event
    my $dispatch_result= undef;

    # if the event-name has handlers
    if (exists $self->{handlers}->{$event_name}) {
        # then dispatch the event to each one
        foreach my $handler_id (keys %{$self->{handlers}->{$event_name}}) {
            # get event handler subref
            my $subref = $self->{handlers}->{$event_name}->{$handler_id};

            # debugging
            if ($debug) {
                $self->{pbot}->{logger}->log("Dispatching $event_name to handler $handler_id\n");
            }

            # invoke an event handler. a handler may return undef to indicate
            # that it decided not to handle this event.
            my $handler_result = eval { $subref->($event_name, $event_data) };

            # update $dispatch_result only when handler result is a defined
            # value so we remember if any handlers have handled this event.
            $dispatch_result = $handler_result if defined $handler_result;

            # check for exception
            if (my $exception = $@) {
                $self->{pbot}->{logger}->log("Exception in event handler: $exception");
            }
        }
    }

    # return undef if no handlers have handled this event; otherwise the return
    # value of the last event handler to handle this event.
    return $dispatch_result;
}

1;
