//! The record types the receiver stores, and nothing else.
//!
//! Kept as its own module for the same reason `system-metrics` does it: `otlp.rs` needs `Record`
//! and `Value` but must not know how any of them are collected, and the collectors need them
//! without depending on the encoder.
//!
//! Duplicated from `packages/system-metrics/src/collect.rs` rather than shared through a library.
//! That is the pattern the fleet's producers already follow -- `inverter-monitoring` carries its
//! own copy of `otlp.rs` and `uds.rs` too -- and it keeps each producer a self-contained crate that
//! can be built, tested and deployed without a workspace.

/// A value as it goes into a measurement body or attribute set. Mirrors the subset of OTLP's
/// `AnyValue` this producer emits (see `otlp.rs`).
///
/// `Null` is the "could not be collected" case. Every field in a record is emitted on every run, so
/// a measurement type has one stable key set and a consumer never has to distinguish "the key is
/// gone" from "the schema changed"; see the `From<Option<Value>>` impl below, which is how every
/// fallible read reaches this enum.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Str(String),
    Int(i64),
    Double(f64),
    Bool(bool),
    Null,
}

impl Value {
    pub fn str(s: impl Into<String>) -> Self {
        Value::Str(s.into())
    }
}

/// The single conversion every fallible collector goes through: `None` becomes `Null` rather than
/// dropping the key.
impl From<Option<Value>> for Value {
    fn from(value: Option<Value>) -> Self {
        value.unwrap_or(Value::Null)
    }
}

/// One measurement. `event_name` becomes the receiver's `type` column and must be non-empty: the
/// receiver rejects records without it (they are not OTLP Events).
#[derive(Debug, Clone, PartialEq)]
pub struct Record {
    pub event_name: String,
    pub attributes: Vec<(String, Value)>,
    pub body: Vec<(String, Value)>,
}

impl Record {
    pub fn new(event_name: &str) -> Self {
        Record { event_name: event_name.to_owned(), attributes: Vec::new(), body: Vec::new() }
    }

    pub fn with_attr(mut self, key: &str, value: impl Into<Value>) -> Self {
        self.attributes.push((key.to_owned(), value.into()));
        self
    }

    pub fn with_field(mut self, key: &str, value: impl Into<Value>) -> Self {
        self.body.push((key.to_owned(), value.into()));
        self
    }
}
