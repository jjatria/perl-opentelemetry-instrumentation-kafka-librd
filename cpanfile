requires 'Kafka::Librd';
requires 'OpenTelemetry';

on test => sub {
    requires 'Test2::V0';
    requires 'Syntax::Keyword::Dynamically';
};
