//! `Record` -> OTLP `ExportLogsServiceRequest`, and the receiver's response back.
//!
//! The message types come from the same `opentelemetry-proto` crate the receiver decodes with,
//! so a field this producer sets cannot mean something else on the other side.

use opentelemetry_proto::tonic::collector::logs::v1::{
    ExportLogsServiceRequest, ExportLogsServiceResponse,
};
use opentelemetry_proto::tonic::common::v1::{
    AnyValue, InstrumentationScope, KeyValue, KeyValueList, any_value,
};
use opentelemetry_proto::tonic::logs::v1::{LogRecord, ResourceLogs, ScopeLogs};
use opentelemetry_proto::tonic::resource::v1::Resource;
use prost::Message;

use crate::collect::{Record, Value};

pub const SCOPE_NAME: &str = "detected-devices";
pub const SCOPE_VERSION: &str = env!("CARGO_PKG_VERSION");

/// `Value::Null` becomes an `AnyValue` with no variant set, which is OTLP's own spelling of an
/// empty value -- the key stays in the kvlist, so a measurement type keeps one stable key set
/// whether or not this host could read the field.
fn any_value(value: &Value) -> AnyValue {
    let inner = match value {
        Value::Str(s) => any_value::Value::StringValue(s.clone()),
        Value::Int(i) => any_value::Value::IntValue(*i),
        Value::Double(d) => any_value::Value::DoubleValue(*d),
        Value::Bool(b) => any_value::Value::BoolValue(*b),
        Value::Null => return AnyValue { value: None },
    };
    AnyValue { value: Some(inner) }
}

fn key_values(pairs: &[(String, Value)]) -> Vec<KeyValue> {
    pairs
        .iter()
        .map(|(key, value)| KeyValue {
            key: key.clone(),
            value: Some(any_value(value)),
            ..Default::default()
        })
        .collect()
}

/// One request per run. `observed_time_unix_nano` is left at zero on purpose: the receiver only
/// falls back to it, and setting both would suggest the two clocks are independent when they are
/// the same reading.
///
/// All records share `time_unix_nano`, captured once at the start of collection -- the same
/// batch-identity property the receiver gives `processed_time` on its own side.
pub fn build_request(
    resource_attributes: &[(String, Value)],
    records: &[Record],
    time_unix_nano: u64,
) -> ExportLogsServiceRequest {
    let log_records = records
        .iter()
        .map(|record| LogRecord {
            time_unix_nano,
            // Non-empty event_name is what makes a log record an Event; the receiver rejects
            // records without one, and it becomes the measurement's `type`.
            event_name: record.event_name.clone(),
            attributes: key_values(&record.attributes),
            body: Some(AnyValue {
                value: Some(any_value::Value::KvlistValue(KeyValueList {
                    values: key_values(&record.body),
                })),
            }),
            ..Default::default()
        })
        .collect();

    ExportLogsServiceRequest {
        resource_logs: vec![ResourceLogs {
            resource: Some(Resource {
                attributes: key_values(resource_attributes),
                ..Default::default()
            }),
            scope_logs: vec![ScopeLogs {
                scope: Some(InstrumentationScope {
                    name: SCOPE_NAME.to_owned(),
                    version: SCOPE_VERSION.to_owned(),
                    ..Default::default()
                }),
                log_records,
                ..Default::default()
            }],
            ..Default::default()
        }],
    }
}

pub fn encode(request: &ExportLogsServiceRequest) -> Vec<u8> {
    request.encode_to_vec()
}

/// What the receiver said about a batch it answered 200 to.
///
/// Rejections arrive on a 200 with a `partial_success`, which is what OTLP prescribes so clients
/// stop retrying data that will never be accepted. A caller that only looks at the status code
/// therefore drops records silently -- hence this is surfaced rather than ignored.
#[derive(Debug, Default, PartialEq)]
pub struct Rejections {
    pub count: i64,
    pub message: String,
}

pub fn decode_rejections(body: &[u8]) -> Result<Rejections, prost::DecodeError> {
    let response = ExportLogsServiceResponse::decode(body)?;
    Ok(match response.partial_success {
        Some(partial) => Rejections {
            count: partial.rejected_log_records,
            message: partial.error_message,
        },
        None => Rejections::default(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> ExportLogsServiceRequest {
        let records = vec![
            Record::new("system.memory").with_field("total_bytes", Value::Int(2048)),
            Record::new("system.filesystem")
                .with_attr("mountpoint", Value::str("/"))
                .with_field("used_percent", Value::Double(12.5)),
        ];
        let resource = vec![
            ("service.name".to_owned(), Value::str("detected-devices")),
            ("host.name".to_owned(), Value::str("rpi5")),
        ];
        build_request(&resource, &records, 1_785_489_242_123_456_789)
    }

    /// The three properties the receiver actually enforces per record.
    #[test]
    fn every_record_is_an_event_with_a_timestamp() {
        let decoded = ExportLogsServiceRequest::decode(encode(&sample()).as_slice()).unwrap();
        let records = &decoded.resource_logs[0].scope_logs[0].log_records;
        assert_eq!(records.len(), 2);
        for record in records {
            assert!(!record.event_name.is_empty(), "empty event_name would be rejected");
            assert_ne!(record.time_unix_nano, 0, "a zero timestamp would be rejected");
        }
        assert_eq!(records[0].event_name, "system.memory");
        assert_eq!(records[1].event_name, "system.filesystem");
    }

    /// The receiver flattens attributes by their protobuf path, so where a key is placed decides
    /// what it is called in a query (`resource.attributes.host.name` vs `record.attributes.*`).
    #[test]
    fn attributes_sit_at_the_level_that_gives_them_the_right_prefix() {
        let decoded = ExportLogsServiceRequest::decode(encode(&sample()).as_slice()).unwrap();
        let resource_logs = &decoded.resource_logs[0];

        let resource_keys: Vec<&str> = resource_logs
            .resource
            .as_ref()
            .unwrap()
            .attributes
            .iter()
            .map(|kv| kv.key.as_str())
            .collect();
        assert_eq!(resource_keys, vec!["service.name", "host.name"]);

        let scope = resource_logs.scope_logs[0].scope.as_ref().unwrap();
        assert_eq!(scope.name, SCOPE_NAME);
        assert_eq!(scope.version, SCOPE_VERSION);

        let record_keys: Vec<&str> = resource_logs.scope_logs[0].log_records[1]
            .attributes
            .iter()
            .map(|kv| kv.key.as_str())
            .collect();
        assert_eq!(record_keys, vec!["mountpoint"]);
    }

    #[test]
    fn the_body_round_trips_as_a_typed_key_value_list() {
        let decoded = ExportLogsServiceRequest::decode(encode(&sample()).as_slice()).unwrap();
        let body = decoded.resource_logs[0].scope_logs[0].log_records[0].body.as_ref().unwrap();
        let Some(any_value::Value::KvlistValue(list)) = &body.value else {
            panic!("body should be a kvlist, got {body:?}");
        };
        assert_eq!(list.values[0].key, "total_bytes");
        assert_eq!(
            list.values[0].value.as_ref().unwrap().value,
            Some(any_value::Value::IntValue(2048))
        );
    }

    #[test]
    fn an_empty_response_means_nothing_was_rejected() {
        let body = ExportLogsServiceResponse::default().encode_to_vec();
        assert_eq!(decode_rejections(&body).unwrap(), Rejections::default());
    }

    #[test]
    fn a_partial_success_surfaces_the_count_and_reason() {
        use opentelemetry_proto::tonic::collector::logs::v1::ExportLogsPartialSuccess;
        let body = ExportLogsServiceResponse {
            partial_success: Some(ExportLogsPartialSuccess {
                rejected_log_records: 2,
                error_message: "2 record(s) had no event_name".to_owned(),
            }),
        }
        .encode_to_vec();
        let rejections = decode_rejections(&body).unwrap();
        assert_eq!(rejections.count, 2);
        assert!(rejections.message.contains("event_name"));
    }
}
