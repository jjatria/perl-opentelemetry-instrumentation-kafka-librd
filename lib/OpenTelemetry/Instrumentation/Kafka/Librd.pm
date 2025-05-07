package OpenTelemetry::Instrumentation::Kafka::Librd;
# ABSTRACT: OpenTelemetry instrumentation for Kafka::Librd

our $VERSION = '0.000002';

use strict;
use warnings;
use experimental 'signatures';

use feature 'lexical_subs';

use Class::Inspector;
use Class::Method::Modifiers 'install_modifier';
use OpenTelemetry::Constants qw( SPAN_KIND_CONSUMER SPAN_KIND_PRODUCER SPAN_KIND_CLIENT );
use OpenTelemetry::Trace;
use OpenTelemetry;
use Scalar::Util 'refaddr';
use Sub::Util 'set_subname';

use parent 'OpenTelemetry::Instrumentation';

sub dependencies { 'Kafka::Librd' }

my ( %ORIGINAL, $LOADED );

my sub wrap ( $package, $symbol, $wrapper, $orig = undef ) {
    $orig //= $package->can($symbol)
        or die "The package $package does not have a sub named $symbol";

    install_modifier $package => around => $symbol,
        set_subname $symbol => $wrapper;

    $orig;
}

my sub maybe_wrap ( $package, $symbol, $wrapper ) {
    wrap( $package, $symbol, $wrapper, $package->can($symbol) || return );
}

my sub links_from_messages ($messages) {
    my @links;

    for (@$messages) {
        last unless $_->can('headers');

        my $ctx  = OpenTelemetry->propagator->extract($_->headers);
        my $sctx = OpenTelemetry::Trace->span_from_context($ctx)->context;
        next unless $sctx->valid;

        push @links, { context => $sctx };
    }

    return \@links;
}

my %PROCESS_SPANS;
my $BACKGROUND;
my sub create_process_span (
    $config,
    $kafka,
    $messages,
    $context //= OpenTelemetry::Context->current,
    $tracer  //= OpenTelemetry->tracer_provider,
) {
    my $address = refaddr $kafka;
    my $topic = $messages->[0]->topic;

    my %attributes = (
        'messaging.system'           => 'kafka',
        'messaging.destination.name' => $topic,
        'messaging.operation.name'   => 'process',
        'messaging.operation.type'   => 'process',
    );

    # Some attributes we only set if we are processing a single message
    if (@$messages == 1) {
        my $msg = $messages->[0];
        $attributes{'messaging.kafka.offset'}             = $msg->offset;
        $attributes{'messaging.destination.partition.id'} = $msg->partition;

        my $key = $msg->key;
        if ( defined $key ) {
            $key = $config->{key_processor}->($key) if $config->{key_processor};
            $attributes{'messaging.kafka.message.key'} = $key;
        }
    }

    my $span = $PROCESS_SPANS{$address} = $tracer->create_span(
        name       => "process $topic",
        kind       => SPAN_KIND_CONSUMER,
        links      => links_from_messages($messages),
        attributes => \%attributes,
    );
}

my sub end_process_span ( $kafka ) {
    my $span = delete $PROCESS_SPANS{ refaddr $kafka } or return;
    $span->end;
    OpenTelemetry::Context->current = $BACKGROUND;
    undef $BACKGROUND;
}

sub uninstall ( $class ) {
    return unless %ORIGINAL;

    for my $package ( keys %ORIGINAL ) {
        for my $method ( keys %{ $ORIGINAL{$package} } ) {
            my $original = delete $ORIGINAL{$package}{$method} or next;

            no strict 'refs';
            no warnings 'redefine';
            delete $Class::Method::Modifiers::MODIFIER_CACHE{$package}{$method};
            *{"${package}::${method}"} = $original;
        }
    }

    %ORIGINAL= ();
    undef $LOADED;
    return;
}

sub install ( $class, %config ) {
    return if $LOADED;
    return unless Class::Inspector->loaded('Kafka::Librd');

    die "Cannot set both 'key_processor' and 'key_uses_schema_framing'"
        if $config{key_processor} && $config{key_uses_schema_framing};

    # If using Kafka::Librd to process messages where the key is Avro-encoded
    # and it uses the Confluent schema framing header (a 5-byte header where
    # the first byte is \0 and the next four encode the ID of the schema used
    # to encode the message) then we need to strip these before recording the
    # key in the span's attributes.
    $config{key_processor} = sub ($key) { substr $key, 5 }
        if $config{key_uses_schema_framing};

    $config{create_poll_span}    //= 1;
    $config{create_process_span} //= 1;

    $ORIGINAL{'Kafka::Librd'}{consumer_poll} = wrap 'Kafka::Librd' => consumer_poll => sub {
        my ( $code, $self, @rest ) = @_;

        end_process_span($self);

        my $tracer = OpenTelemetry->tracer_provider->tracer(
            name    => __PACKAGE__,
            version => $VERSION,
        );

        my $record;
        if ( $config{create_poll_span} ) {
            $record = $tracer->in_span(
                # Name has no destination, since this could be for mutiple topics
                poll => (
                    kind => SPAN_KIND_CONSUMER,
                    attributes => {
                        'messaging.system'         => 'kafka',
                        'messaging.operation.name' => 'poll',
                        'messaging.operation.type' => 'receive',
                    },
                ) => sub { $self->$code(@rest) },
            );
        }
        else {
            $record = $self->$code(@rest);
        }

        return $record unless $config{create_process_span};

        my $span = create_process_span(\%config, $self, [$record], undef, $tracer)
            if $record;

        # If we are managing the process span, then we create it here
        # and end it the next time this method is called. This is
        # unconventional, but consistent with other instrumentations
        # (eg. the one for Python). We store the current context
        # before unconditionally overwriting it so we can restore it
        # when we are done. As long as we do this, we _should_ play
        # nicely with any other part of the application that consistently
        # sets their context dynamically.
        # If this is undesirable, the user is free to opt-out and do this
        # themselves.
        $BACKGROUND = OpenTelemetry::Context->current;
        OpenTelemetry::Context->current
            = OpenTelemetry::Trace->context_with_span($span);

        return $record;
    } if $config{create_poll_span} || $config{create_process_span};

    $ORIGINAL{'Kafka::Librd'}{commit_message} = wrap 'Kafka::Librd' => commit_message => sub {
        my ( $code, $self, $message, @rest ) = @_;

        my $topic     = $message->topic;
        my $partition = $message->partition;

        my $tracer = OpenTelemetry->tracer_provider->tracer(
            name    => __PACKAGE__,
            version => $VERSION,
        );

        my %attributes = (
            'messaging.system'            => 'kafka',
            'messaging.operation.name'    => 'commit',
            'messaging.operation.type'    => 'settle',
            'messaging.destination.name'  => $topic,
        );
        $attributes{'messaging.destination.partition.id'} = $partition if defined $partition;

        $tracer->in_span(
            "commit $topic" => (
                kind       => SPAN_KIND_CLIENT,
                attributes => \%attributes,
                links      => links_from_messages([$message]),
            ) => sub {
                $self->$code($message, @rest);
            },
        );
    };

    $ORIGINAL{'Kafka::Librd'}{producev} = maybe_wrap 'Kafka::Librd' => producev => sub {
        my ( $code, $self, $params, @rest ) = @_;

        my $topic     = $params->{topic};
        my $key       = $params->{key};
        my $partition = $params->{partition};
        my %headers   = %{ $params->{headers} // {} };

        my $tracer = OpenTelemetry->tracer_provider->tracer(
            name    => __PACKAGE__,
            version => $VERSION,
        );

        my %attributes = (
            'messaging.system'            => 'kafka',
            'messaging.operation.name'    => 'send',
            'messaging.operation.type'    => 'send',
            'messaging.destination.name'  => $topic,
        );

        $attributes{'messaging.destination.partition.id'} = $partition if defined $partition;

        if ( defined $key ) {
            $key = $config{key_processor}->($key) if $config{key_processor};
            $attributes{'messaging.kafka.message.key'} = $key;
        }

        $tracer->in_span(
            "send $topic" => (
                kind       => SPAN_KIND_PRODUCER,
                attributes => \%attributes,
            ) => sub {
                OpenTelemetry->propagator->inject(\%headers);
                $self->$code( { %$params, headers => \%headers }, @rest );
            },
        );
    };

    # FIXME: This method does not support headers, so it cannot propagate
    $ORIGINAL{'Kafka::Librd::Topic'}{produce} = wrap 'Kafka::Librd::Topic' => produce => sub {
        my ( $code, $self, $partition, $flags, $payload, $key, @rest ) = @_;

        my $tracer = OpenTelemetry->tracer_provider->tracer(
            name    => __PACKAGE__,
            version => $VERSION,
        );

        my %attributes = (
            'messaging.system'            => 'kafka',
            'messaging.operation.name'    => 'send',
            'messaging.operation.type'    => 'send',
        );

        $attributes{'messaging.destination.partition.id'} = $partition if defined $partition;

        if ( defined $key ) {
            $key = $config{key_processor}->($key) if $config{key_processor};
            $attributes{'messaging.kafka.message.key'} = $key;
        }

        $tracer->in_span(
            send => (
                kind => SPAN_KIND_PRODUCER,
                attributes => \%attributes,
            ) => sub {
                $self->$code( $partition, $flags, $payload, $key, @rest );
            },
        );
    };

    return $LOADED = 1;
}

1;
