//! `Record` -> OTLP `ExportLogsServiceRequest`, and the receiver's response back.
//!
//! The same encoding as `packages/inverter-monitoring/src/otlp.rs` and
//! `packages/system-metrics/src/otlp.rs`, against the same receiver, built on the same
//! `opentelemetry-proto` crate the receiver decodes with. Duplicated rather than shared because
//! these are standalone crates with no workspace between them -- the convention in this repo --
//! but the three properties the receiver enforces (non-empty `event_name`, non-zero timestamp,
//! kvlist body) are re-asserted in the tests below so the copies cannot drift silently.

use opentelemetry_proto::tonic::collector::logs::v1::{
    ExportLogsServiceRequest, ExportLogsServiceResponse,
};
use opentelemetry_proto::tonic::common::v1::{
    any_value, AnyValue, InstrumentationScope, KeyValue, KeyValueList,
};
use opentelemetry_proto::tonic::logs::v1::{LogRecord, ResourceLogs, ScopeLogs};
use opentelemetry_proto::tonic::resource::v1::Resource;
use prost::Message;

use crate::record::{Record, Value};

pub const SCOPE_NAME: &str = "bms-monitoring";
pub const SCOPE_VERSION: &str = env!("CARGO_PKG_VERSION");

/// `Value::Null` becomes an `AnyValue` with no variant set, OTLP's own spelling of an empty
/// value. The key stays in the kvlist, which is what keeps one stable column set across cycles
/// that read different amounts.
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

/// One request per poll cycle. All records share the `time_unix_nano` captured when the cycle
/// started, so a status record and the flag records explaining it cannot land microseconds apart
/// and sort separately.
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
/// therefore drops records silently.
#[derive(Debug, Default, PartialEq)]
pub struct Rejections {
    pub count: i64,
    pub message: String,
}

pub fn decode_rejections(body: &[u8]) -> Result<Rejections, prost::DecodeError> {
    let response = ExportLogsServiceResponse::decode(body)?;
    Ok(match response.partial_success {
        Some(partial) => {
            Rejections { count: partial.rejected_log_records, message: partial.error_message }
        }
        None => Rejections::default(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> ExportLogsServiceRequest {
        let records = vec![
            Record::new("bms.status")
                .with_field("pack_voltage_volts", Value::Double(52.036))
                .with_field("temperature_3_celsius", Value::Null),
            Record::new("bms.status.cell")
                .with_attr("cell", Value::Int(5))
                .with_field("voltage_volts", Value::Double(3.249)),
        ];
        let resource = vec![
            ("service.name".to_owned(), Value::str("bms-monitoring")),
            (
                "bms.device".to_owned(),
                Value::str("platform-xhci-hcd.0-usb-0:1:1.0-port0"),
            ),
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
        assert_eq!(records[0].event_name, "bms.status");
        assert_eq!(records[1].event_name, "bms.status.cell");
    }

    /// Where a key sits decides what it is called in a query: the port has to be a resource
    /// attribute to come back as `resource.attributes.bms.device`, while a cell number has to be a
    /// record attribute so the sixteen rows of one cycle are distinguishable.
    #[test]
    fn identity_is_a_resource_attribute_not_a_record_one() {
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
        assert_eq!(resource_keys, vec!["service.name", "bms.device"]);

        let scope = resource_logs.scope_logs[0].scope.as_ref().unwrap();
        assert_eq!(scope.name, SCOPE_NAME);
        assert_eq!(scope.version, SCOPE_VERSION);

        let record_keys: Vec<&str> = resource_logs.scope_logs[0].log_records[1]
            .attributes
            .iter()
            .map(|kv| kv.key.as_str())
            .collect();
        assert_eq!(record_keys, vec!["cell"]);
    }

    /// A null keeps its key. Dropping it would make an unpopulated temperature channel look like a
    /// schema change rather than a missing sensor.
    #[test]
    fn a_null_field_is_an_empty_value_not_an_absent_key() {
        let decoded = ExportLogsServiceRequest::decode(encode(&sample()).as_slice()).unwrap();
        let body = decoded.resource_logs[0].scope_logs[0].log_records[0].body.as_ref().unwrap();
        let Some(any_value::Value::KvlistValue(list)) = &body.value else {
            panic!("body should be a kvlist, got {body:?}");
        };
        assert_eq!(list.values[0].key, "pack_voltage_volts");
        assert_eq!(
            list.values[0].value.as_ref().unwrap().value,
            Some(any_value::Value::DoubleValue(52.036))
        );
        assert_eq!(list.values[1].key, "temperature_3_celsius");
        assert_eq!(list.values[1].value.as_ref().unwrap().value, None);
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
                rejected_log_records: 1,
                error_message: "1 record(s) had no event_name".to_owned(),
            }),
        }
        .encode_to_vec();
        let rejections = decode_rejections(&body).unwrap();
        assert_eq!(rejections.count, 1);
        assert!(rejections.message.contains("event_name"));
    }
}
