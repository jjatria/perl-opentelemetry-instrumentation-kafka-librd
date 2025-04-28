#!/usr/bin/env perl

use Test2::V0 -target => 'OpenTelemetry::Instrumentation::Kafka::Librd';
use Test2::Tools::Spec;

use experimental 'signatures';

use Kafka::Librd;
use OpenTelemetry;
use OpenTelemetry::Trace::Tracer;
use OpenTelemetry::Propagator::TraceContext;
# use OpenTelemetry::Baggage;
use OpenTelemetry::Constants -span;
# use OpenTelemetry::Context;
# use OpenTelemetry::Propagator::Baggage;
use Syntax::Keyword::Dynamically;

my @spans;
my $otel = mock 'OpenTelemetry::Trace::Tracer' => override => [
    create_span => sub ( $, %args ) {
        push @spans, mock { otel => \%args } => add => [
            set_attribute => sub ( $self, %args ) {
                $self->{otel}{attributes} = {
                    %{ $self->{otel}{attributes} // {} },
                    %args,
                };
            },
            set_status => sub ( $self, $status, $desc = '' ) {
                $self->{otel}{status} = {
                    code => $status,
                    $desc ? ( description => $desc ) : (),
                };
            },
            end => sub ( $self ) {
                $self->{otel}{ended} = 1;
            },
        ];

        $spans[-1];
    },
];

is [ CLASS->dependencies ], ['Kafka::Librd'], 'Reports dependencies';

before_each Cleanup => sub {
    CLASS->uninstall;
    @spans = ();
};

describe 'consumer_poll' => sub {
    tests 'Default' => sub {
        my $mock = mock 'Kafka::Librd' => override => [
            consumer_poll => sub {
                mock {} => add => [
                    topic     => 'my-topic',
                    partition => 8,
                    offset    => 4,
                    key       => 'deadbeef',
                    headers   => sub {
                        { traceparent => '00-000102030405060708090a0b0c0d0e0f-0001020304050607-00' };
                    },
                ];
            },
        ];

        ok +CLASS->install, 'Installed modifier';

        my $kfk = Kafka::Librd->new(Kafka::Librd::RD_KAFKA_CONSUMER, {});

        dynamically OpenTelemetry->propagator
            = OpenTelemetry::Propagator::TraceContext->new;

        $kfk->consumer_poll(1);

        is [ map $_->{otel}, @spans ], [
            {
                ended      => T,
                kind       => SPAN_KIND_CONSUMER,
                name       => 'poll',
                parent     => object { prop isa => 'OpenTelemetry::Context' },
                 attributes => {
                    'messaging.operation.name' => 'poll',
                    'messaging.operation.type' => 'receive',
                    'messaging.system'         => 'kafka',
                },
                status => {
                    code => SPAN_STATUS_OK,
                },
            },
            {
                kind       => SPAN_KIND_CONSUMER,
                name       => 'process my-topic',
                attributes => {
                    'messaging.destination.name'         => 'my-topic',
                    'messaging.destination.partition.id' => 8,
                    'messaging.kafka.offset'             => 4,
                    'messaging.kafka.message.key'        => 'deadbeef',
                    'messaging.operation.name'           => 'process',
                    'messaging.operation.type'           => 'process',
                    'messaging.system'                   => 'kafka',
                },
                links => [
                    {
                        context => object {
                            call hex_trace_id => '000102030405060708090a0b0c0d0e0f';
                            call hex_span_id  => '0001020304050607';
                        },
                    },
                ],
            },
        ], 'Created poll and consumer spans';

        $kfk->consumer_poll(1);

        like \@spans, [
            { otel => { name => 'poll', ended => T } },
            { otel => { name => 'process my-topic', ended => T } },
            { otel => { name => 'poll', ended => T } },
            { otel => { name => 'process my-topic', ended => DNE } },
        ], 'Previous process span is ended on next call to consumer_poll';
    };

    tests 'No poll span' => sub {
        my $mock = mock 'Kafka::Librd' => override => [
            consumer_poll => sub {
                # If key is undefined it is not added to attributes
                mock {} => add => [
                    topic     => 'my-topic',
                    partition => 8,
                    offset    => 4,
                ];
            },
        ];

        ok +CLASS->install( create_poll_span => 0 ), 'Installed modifier';

        my $kfk = Kafka::Librd->new(Kafka::Librd::RD_KAFKA_CONSUMER, {});

        $kfk->consumer_poll(1);

        is [ map $_->{otel}, @spans ], [
            {
                kind       => SPAN_KIND_CONSUMER,
                name       => 'process my-topic',
                attributes => {
                    'messaging.destination.name'         => 'my-topic',
                    'messaging.destination.partition.id' => 8,
                    'messaging.kafka.offset'             => 4,
                    'messaging.operation.name'           => 'process',
                    'messaging.operation.type'           => 'process',
                    'messaging.system'                   => 'kafka',
                },
                links => [],
            },
        ], 'Created only process span';

        $kfk->consumer_poll(1);

        like \@spans, [
            { otel => { name => 'process my-topic', ended => T } },
            { otel => { name => 'process my-topic', ended => DNE } },
        ], 'Previous process span is ended on next call to consumer_poll';
    };

    tests 'No process span' => sub {
        my $mock = mock 'Kafka::Librd' => override => [
            consumer_poll => sub {
                mock {} => add => [
                    topic     => 'my-topic',
                    partition => 8,
                    offset    => 4,
                ];
            },
        ];

        ok +CLASS->install( create_process_span => 0 ), 'Installed modifier';

        my $kfk = Kafka::Librd->new(Kafka::Librd::RD_KAFKA_CONSUMER, {});

        $kfk->consumer_poll(1);

        is [ map $_->{otel}, @spans ], [
            {
                ended      => T,
                kind       => SPAN_KIND_CONSUMER,
                name       => 'poll',
                parent     => object { prop isa => 'OpenTelemetry::Context' },
                 attributes => {
                    'messaging.operation.name' => 'poll',
                    'messaging.operation.type' => 'receive',
                    'messaging.system'         => 'kafka',
                },
                status => {
                    code => SPAN_STATUS_OK,
                },
            },
        ], 'Created only poll span';
    };
};

describe 'commit_message' => sub {
    tests 'Default' => sub {
        my $mock = mock 'Kafka::Librd' => override => [
            commit_message => sub {},
        ];

        ok +CLASS->install, 'Installed modifier';

        my $kfk = Kafka::Librd->new(Kafka::Librd::RD_KAFKA_CONSUMER, {});

        dynamically OpenTelemetry->propagator = OpenTelemetry::Propagator::TraceContext->new;

        $kfk->commit_message(
            mock {} => add => [
                topic     => 'my-topic',
                partition => 42,
                headers   => sub {
                    { traceparent => '00-000102030405060708090a0b0c0d0e0f-0001020304050607-00' };
                },
            ],
        );

        is [ map $_->{otel}, @spans ], [
            {
                ended => T,
                kind  => SPAN_KIND_CLIENT,
                name  => 'commit my-topic',
                links => [
                    {
                        context => object {
                            call hex_trace_id => '000102030405060708090a0b0c0d0e0f';
                            call hex_span_id  => '0001020304050607';
                        },
                    }
                ],
                parent => object { prop isa => 'OpenTelemetry::Context' },
                 attributes => {
                    'messaging.destination.name'         => 'my-topic',
                    'messaging.destination.partition.id' => 42,
                    'messaging.operation.name'           => 'commit',
                    'messaging.operation.type'           => 'settle',
                    'messaging.system'                   => 'kafka',
                },
                status => {
                    code => SPAN_STATUS_OK,
                },
            },
        ], 'Created poll and consumer spans';
    };
};

describe 'producev' => {
    Kafka::Librd->can('producev') ? () : ( skip => 'No producev' ),
} => sub {
    tests 'Default' => sub {
        my $mock = mock 'Kafka::Librd' => override => [
            producev => sub {},
        ];

        ok +CLASS->install, 'Installed modifier';

        my $kfk = Kafka::Librd->new(Kafka::Librd::RD_KAFKA_CONSUMER, {});

        my $span = mock {} => add => [
            context => sub {
                mock {} => add => [
                    span_id  => sub { unpack 'H*', '0001020304050607' },
                    trace_id => sub { unpack 'H*', '000102030405060708090a0b0c0d0e0f' },
                ];
            },
        ];

        dynamically OpenTelemetry::Context->current
            = OpenTelemetry::Trace->context_with_span($span);

        dynamically OpenTelemetry->propagator
            = OpenTelemetry::Propagator::TraceContext->new;

        $kfk->producev(
            {
                topic => 'my-topic',
                key   => 'deadbeef',
                partition => 42,
                headers => { foo => 123 },
            },
        );

        is [ map $_->{otel}, @spans ], [
            {
                ended => T,
                kind  => SPAN_KIND_PRODUCER,
                name  => 'send my-topic',
                parent => object { prop isa => 'OpenTelemetry::Context' },
                 attributes => {
                    'messaging.destination.name'         => 'my-topic',
                    'messaging.destination.partition.id' => 42,
                    'messaging.kafka.message.key'        => 'deadbeef',
                    'messaging.operation.name'           => 'send',
                    'messaging.operation.type'           => 'send',
                    'messaging.system'                   => 'kafka',
                },
                status => {
                    code => SPAN_STATUS_OK,
                },
            },
        ], 'Created send span';
    };
};

tests 'Configuration validation' => sub {
    like dies {
            CLASS->install(
                key_uses_schema_framing => 1,
                key_processor           => sub { },
            )
        },
        qr/^Cannot set both 'key_processor' and 'key_uses_schema_framing'/,
        'key_processor is incompatible with schema framing';
};

done_testing;
