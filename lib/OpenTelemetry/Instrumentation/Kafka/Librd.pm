package OpenTelemetry::Instrumentation::Kafka::Librd;
# ABSTRACT: OpenTelemetry instrumentation for Kafka::Librd

our $VERSION = '0.001';

use strict;
use warnings;
use experimental 'signatures';

use Scalar::Util 'refaddr';
use Class::Inspector;
use Class::Method::Modifiers 'install_modifier';
use OpenTelemetry::Constants qw( SPAN_KIND_CONSUMER SPAN_KIND_PRODUCER SPAN_KIND_CLIENT );
use OpenTelemetry::Trace;
use OpenTelemetry;

use parent 'OpenTelemetry::Instrumentation';

sub dependencies { 'Kafka::Librd' }

my ( %ORIGINAL, $LOADED );

sub uninstall ( $class ) {
    return unless %ORIGINAL;

    for my $package ( keys %ORIGINAL ) {
        for my $method ( keys %{ $ORIGINAL{$package} } ) {
            no strict 'refs';
            no warnings 'redefine';
            delete $Class::Method::Modifiers::MODIFIER_CACHE{$package}{$method};
            *{"${package}::${method}"} = delete $ORIGINAL{$package}{$method};
        }
    }

    undef $LOADED;
    return;
}

sub links_from_messages ($messages) {
    my @links;

    for (@$messages) {
        last unless $_->can('headers');

        my $context = OpenTelemetry->propagator->extract($_->headers);
        my $span = OpenTelemetry::Trace->span_from_context($context);
        push @links, { context => $span->context };
    }

    return \@links;
}

my %SPANS;
my $BACKGROUND;
sub create_consumer_span (
    $config,
    $kafka,
    $messages,
    $context //= OpenTelemetry::Context->current,
    $tracer  //= OpenTelemetry->tracer_provider,
) {
    my $address = refaddr $kafka;

    my $links = links_from_messages($messages);

    my $topic = $messages->[0]->topic;

    my %attributes = (
        'messaging.system'           => 'kafka',
        'messaging.destination.name' => $topic,
        'messaging.operation.name'   => 'process',
        'messaging.operation.type'   => 'process',
    );

    if (@$messages == 1) {
        my $msg = $messages->[0];
        $attributes{'messaging.kafka.offset'}             = $msg->offset;
        $attributes{'messaging.destination.partition.id'} = $msg->partition;

        my $key = $msg->key;
        if ( defined $key ) {
            if ( $config->{key}{strip_schema_header} ) {
                open my $fh, '<', \$key or die $!; # TODO: never die
                $fh->read(5);
                $key = do { local $/; <$fh> };
            }
            $attributes{'messaging.kafka.message.key'} = $key;
        }
    }

    my $span = $SPANS{$address}{consumer} = $tracer->create_span(
        name       => "process $topic",
        kind       => SPAN_KIND_CONSUMER,
        links      => $links,
        attributes => \%attributes,
    );
}

sub end_consumer_span ( $kafka ) {
    my $span = delete $SPANS{ refaddr $kafka }{consumer} or return;
    $span->end;
    OpenTelemetry::Context->current = $BACKGROUND;
    undef $BACKGROUND;
}

sub install ( $class, %config ) {
    return if $LOADED;
    return unless Class::Inspector->loaded('Kafka::Librd');

    $ORIGINAL{'Kafka::Librd'}{consumer_poll} = \&Kafka::Librd::consumer_poll;
    install_modifier 'Kafka::Librd' => around => consumer_poll => sub {
        my ( $code, $self, @rest ) = @_;

        end_consumer_span($self);

        my $tracer = OpenTelemetry->tracer_provider->tracer(
            name    => __PACKAGE__,
            version => $VERSION,
        );

        my $span;
        my $record = $tracer->in_span(
            # Name has no destination, since this could be for mutiple topics
            poll => (
                kind       => SPAN_KIND_CONSUMER,
                attributes => {
                    'messaging.system'         => 'kafka',
                    'messaging.operation.name' => 'poll',
                    'messaging.operation.type' => 'receive',
                },
            ) => sub {
                my $record = $self->$code(@rest);

                if ( $record ) {
                    $span = create_consumer_span(\%config, $self, [$record], undef, $tracer);
                }

                $record;
            },
        );

        # TODO: This should be configurable
        $BACKGROUND = OpenTelemetry::Context->current;
        OpenTelemetry::Context->current
            = OpenTelemetry::Trace->context_with_span($span);

        return $record;
    };

    $ORIGINAL{'Kafka::Librd'}{producev} = \&Kafka::Librd::producev;
    install_modifier 'Kafka::Librd' => around => producev => sub {
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
        $attributes{'messaging.kafka.message.key'}        = $key       if defined $key;
        $attributes{'messaging.destination.partition.id'} = $partition if defined $partition;

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

    $ORIGINAL{'Kafka::Librd'}{commit_message} = \&Kafka::Librd::commit_message;
    install_modifier 'Kafka::Librd' => around => commit_message => sub {
        my ( $code, $self, $message, @rest ) = @_;

        my $topic     = $message->topic;
        my $partition = $message->partition;
        my $links = links_from_messages([$message]);

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
                links      => $links,
            ) => sub {
                $self->$code($message, @rest);
            },
        );
    };

    # FIXME: This method does not support headers, so it cannot propagate
    $ORIGINAL{'Kafka::Librd::Topic'}{produce} = \&Kafka::Librd::Topic::produce;
    install_modifier 'Kafka::Librd::Topic' => around => produce => sub {
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

        $attributes{'messaging.kafka.message.key'}        = $key       if defined $key;
        $attributes{'messaging.destination.partition.id'} = $partition if defined $partition;

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
