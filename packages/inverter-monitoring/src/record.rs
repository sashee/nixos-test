//! Readings -> the records the receiver stores. Pure.
//!
//! One `inverter.status` record per poll cycle, plus one `inverter.status.flag` per asserted
//! warning bit. That shape is a storage decision as much as a modelling one: at a one-minute
//! cadence and a receiver with no retention, every extra record per cycle is another half a
//! million permanent rows a year on an SD card. Fields are cheap, records are not.

use crate::parse::{ModeReading, Qpigs, Qpigs2, Qpiws, INVERTER_FAULT_BIT};

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

    pub fn with_attr(mut self, key: &str, value: Value) -> Self {
        self.attributes.push((key.to_owned(), value));
        self
    }

    pub fn with_field(mut self, key: &str, value: Value) -> Self {
        self.body.push((key.to_owned(), value));
        self
    }
}

pub const STATUS: &str = "inverter.status";
pub const FLAG: &str = "inverter.status.flag";

/// Counters describing the serial link itself, carried on the status record.
///
/// Only place a discarded frame is ever visible. Without them a port dropping a third of its
/// frames to line noise looks exactly like a healthy one, because each individual cycle
/// recovers.
#[derive(Debug, Default, Clone, Copy, PartialEq)]
pub struct Link {
    pub connected_seconds: u64,
    pub discarded_frames: u64,
    pub unsupported_commands: u64,
}

/// Everything one poll cycle managed to read. Each part is independently optional: a command
/// that timed out, NAKed or failed its CRC contributes nulls and does not stop the others.
#[derive(Debug, Default)]
pub struct Cycle {
    pub mode: Option<ModeReading>,
    pub qpigs: Option<Qpigs>,
    pub qpigs2: Option<Qpigs2>,
    pub qpiws: Option<Qpiws>,
    pub link: Link,
}

impl Cycle {
    /// Whether anything at all came back. A cycle that read nothing is the signal the caller
    /// counts towards giving up on the port.
    pub fn is_empty(&self) -> bool {
        self.mode.is_none()
            && self.qpigs.is_none()
            && self.qpigs2.is_none()
            && self.qpiws.is_none()
    }
}

/// Every key the status record can carry, always in this order and always present.
///
/// A key is never dropped, only nulled. The receiver keeps whatever it is sent and a consumer
/// should see the same column set from every cycle, whether or not this unit answers `QPIGS2`.
pub fn status_record(cycle: &Cycle) -> Record {
    let qpigs = cycle.qpigs.as_ref();
    let qpigs2 = cycle.qpigs2.as_ref();
    let qpiws = cycle.qpiws.as_ref();

    Record::new(STATUS)
        .with_field("mode_code", opt(cycle.mode.as_ref().map(|m| Value::str(m.code.to_string()))))
        .with_field(
            "mode",
            opt(cycle.mode.as_ref().and_then(|m| m.mode).map(|m| Value::str(m.name()))),
        )
        .with_field("grid_voltage_volts", num(qpigs.map(|q| q.grid_voltage)))
        .with_field("grid_frequency_hz", num(qpigs.map(|q| q.grid_frequency)))
        .with_field("output_voltage_volts", num(qpigs.map(|q| q.output_voltage)))
        .with_field("output_frequency_hz", num(qpigs.map(|q| q.output_frequency)))
        .with_field("output_apparent_power_va", int(qpigs.map(|q| q.output_apparent_power)))
        .with_field("output_active_power_watts", int(qpigs.map(|q| q.output_active_power)))
        .with_field("output_load_percent", int(qpigs.map(|q| q.output_load_percent)))
        .with_field("battery_voltage_volts", num(qpigs.map(|q| q.battery_voltage)))
        .with_field("battery_capacity_percent", int(qpigs.map(|q| q.battery_capacity)))
        .with_field(
            "battery_charging_current_amps",
            int(qpigs.map(|q| q.battery_charging_current)),
        )
        .with_field(
            "battery_discharge_current_amps",
            int(qpigs.map(|q| q.battery_discharge_current)),
        )
        .with_field(
            "battery_voltage_from_scc1_volts",
            num(qpigs.map(|q| q.battery_voltage_from_scc1)),
        )
        .with_field(
            "battery_voltage_offset_fans_on_volts",
            num(qpigs.map(|q| q.battery_voltage_offset_fans_on)),
        )
        .with_field("pv1_current_amps", num(qpigs.map(|q| q.pv1_current)))
        .with_field("pv1_voltage_volts", num(qpigs.map(|q| q.pv1_voltage)))
        .with_field("pv1_charging_power_watts", int(qpigs.map(|q| q.pv1_charging_power)))
        .with_field("pv2_current_amps", num(qpigs2.map(|q| q.pv2_current)))
        .with_field("pv2_voltage_volts", num(qpigs2.map(|q| q.pv2_voltage)))
        .with_field("pv2_charging_power_watts", int(qpigs2.map(|q| q.pv2_charging_power)))
        .with_field("bus_voltage_volts", int(qpigs.map(|q| q.bus_voltage)))
        .with_field("heat_sink_temperature_celsius", int(qpigs.map(|q| q.heat_sink_temperature)))
        .with_field("eeprom_version", int(qpigs.map(|q| q.eeprom_version)))
        .with_field("load_on", flag(qpigs.map(|q| q.load_on)))
        .with_field("charging", flag(qpigs.map(|q| q.charging)))
        .with_field("charging_scc", flag(qpigs.map(|q| q.charging_scc)))
        .with_field("charging_ac", flag(qpigs.map(|q| q.charging_ac)))
        .with_field("float_charge", flag(qpigs.map(|q| q.float_charge)))
        .with_field("switch_on", flag(qpigs.map(|q| q.switch_on)))
        .with_field("configuration_changed", flag(qpigs.map(|q| q.configuration_changed)))
        .with_field("scc_firmware_updated", flag(qpigs.map(|q| q.scc_firmware_updated)))
        .with_field("add_sbu_priority_version", flag(qpigs.map(|q| q.add_sbu_priority_version)))
        .with_field(
            "battery_voltage_to_steady_while_charging",
            flag(qpigs.map(|q| q.battery_voltage_to_steady_while_charging)),
        )
        .with_field("warnings_raw", opt(qpiws.map(|q| Value::str(&q.raw))))
        .with_field("warnings_asserted_count", int(qpiws.map(|q| q.asserted_count())))
        .with_field("inverter_fault", flag(qpiws.map(|q| q.bits[INVERTER_FAULT_BIT])))
        .with_field("link_connected_seconds", Value::Int(cycle.link.connected_seconds as i64))
        .with_field("link_discarded_frames", Value::Int(cycle.link.discarded_frames as i64))
        .with_field(
            "link_unsupported_commands",
            Value::Int(cycle.link.unsupported_commands as i64),
        )
}

/// One record per asserted warning bit, and none at all in the normal case.
///
/// The bit names cannot live in the status record: a record has one attribute set, so a
/// queryable name per bit needs a record per bit. Emitting them only when asserted is what makes
/// that affordable -- `warnings_raw` and `warnings_asserted_count` on the status record are what
/// keep "all clear" provable in their absence.
pub fn flag_records(cycle: &Cycle) -> Vec<Record> {
    let Some(qpiws) = cycle.qpiws.as_ref() else {
        return Vec::new();
    };
    qpiws
        .asserted()
        .map(|(index, name)| {
            Record::new(FLAG)
                .with_attr("bit", Value::str(format!("a{index}")))
                .with_attr("flag", Value::str(name))
                .with_field("asserted", Value::Bool(true))
        })
        .collect()
}

fn opt(value: Option<Value>) -> Value {
    value.unwrap_or(Value::Null)
}

fn num(value: Option<f64>) -> Value {
    opt(value.map(Value::Double))
}

fn int(value: Option<i64>) -> Value {
    opt(value.map(Value::Int))
}

fn flag(value: Option<bool>) -> Value {
    opt(value.map(Value::Bool))
}

/// Resource attributes describing the unit itself, refreshed with the static data.
///
/// Two names for the port, because neither one alone does the job. `inverter.device` is the
/// by-path key: unique per physical socket, and what the producer matches on. `device_name` is
/// udev's descriptor-derived by-id name, which is what a human reading a query recognises -- but
/// which is not unique when the adapter reports no serial number, as this fleet's CH340 does.
pub fn identity_attributes(
    device: &str,
    device_name: Option<&str>,
    identity: &[(&'static str, Option<String>)],
) -> Vec<(String, Value)> {
    let mut attributes = vec![("inverter.device".to_owned(), Value::str(device))];
    if let Some(name) = device_name {
        attributes.push(("inverter.device_name".to_owned(), Value::str(name)));
    }
    for (key, value) in identity {
        if let Some(value) = value {
            attributes.push((format!("inverter.{key}"), Value::str(value)));
        }
    }
    attributes
}

/// Human-readable rendering for `--dry-run`, same shape as the sibling producer's.
pub fn format_pairs(pairs: &[(String, Value)]) -> String {
    pairs
        .iter()
        .map(|(key, value)| match value {
            Value::Str(s) => format!("{key}={s}"),
            Value::Int(i) => format!("{key}={i}"),
            Value::Double(d) => format!("{key}={d}"),
            Value::Bool(b) => format!("{key}={b}"),
            Value::Null => format!("{key}=null"),
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parse::{parse_qmod, parse_qpigs, parse_qpigs2, parse_qpiws};

    const SAMPLE: &[u8] = b"000.0 00.0 226.7 50.0 0997 0825 012 429 54.20 041 080 0062 09.2 196.4 00.00 00000 00010110 00 00 01819 010";

    fn full_cycle() -> Cycle {
        Cycle {
            mode: Some(parse_qmod(b"B").unwrap()),
            qpigs: Some(parse_qpigs(SAMPLE).unwrap()),
            qpigs2: Some(parse_qpigs2(b"05.4 212.5 01156 ").unwrap()),
            qpiws: Some(parse_qpiws(b"000001000000000001000000000000000000").unwrap()),
            link: Link { connected_seconds: 90, discarded_frames: 2, unsupported_commands: 0 },
        }
    }

    fn body(record: &Record, key: &str) -> Value {
        record
            .body
            .iter()
            .find(|(name, _)| name == key)
            .unwrap_or_else(|| panic!("no {key} in the record"))
            .1
            .clone()
    }

    #[test]
    fn one_cycle_is_one_record() {
        let cycle = full_cycle();
        assert_eq!(status_record(&cycle).event_name, STATUS);
        // Two asserted bits in the sample, so two flag records and nothing else.
        assert_eq!(flag_records(&cycle).len(), 2);
    }

    #[test]
    fn carries_the_scaled_values_not_the_wire_text() {
        let record = status_record(&full_cycle());
        assert_eq!(body(&record, "battery_voltage_volts"), Value::Double(54.2));
        assert_eq!(body(&record, "output_apparent_power_va"), Value::Int(997));
        assert_eq!(body(&record, "mode"), Value::str("battery"));
        assert_eq!(body(&record, "mode_code"), Value::str("B"));
        assert_eq!(body(&record, "pv2_voltage_volts"), Value::Double(212.5));
    }

    /// The property that makes a query stable across hosts and firmwares: the key set does not
    /// depend on what this cycle managed to read.
    #[test]
    fn a_failed_command_nulls_its_keys_rather_than_removing_them() {
        let full = status_record(&full_cycle());
        let empty = status_record(&Cycle::default());

        let keys = |record: &Record| -> Vec<String> {
            record.body.iter().map(|(key, _)| key.clone()).collect()
        };
        assert_eq!(keys(&full), keys(&empty));

        // The link counters are the exception: they are this process's own state, always known.
        assert_eq!(body(&empty, "pv2_voltage_volts"), Value::Null);
        assert_eq!(body(&empty, "warnings_raw"), Value::Null);
        assert_eq!(body(&empty, "link_discarded_frames"), Value::Int(0));
    }

    /// The QPIGS2-unsupported case specifically: pv1 keeps its values while pv2 goes null.
    #[test]
    fn an_unsupported_qpigs2_nulls_only_the_second_string() {
        let cycle = Cycle { qpigs2: None, ..full_cycle() };
        let record = status_record(&cycle);
        assert_eq!(body(&record, "pv1_voltage_volts"), Value::Double(196.4));
        assert_eq!(body(&record, "pv2_voltage_volts"), Value::Null);
        assert_eq!(body(&record, "pv2_charging_power_watts"), Value::Null);
    }

    #[test]
    fn flags_are_named_and_numbered_by_bit() {
        let records = flag_records(&full_cycle());
        let described: Vec<(Value, Value)> = records
            .iter()
            .map(|r| (r.attributes[0].1.clone(), r.attributes[1].1.clone()))
            .collect();
        assert_eq!(
            described,
            vec![
                (Value::str("a5"), Value::str("line_fail")),
                (Value::str("a17"), Value::str("eeprom_fault")),
            ]
        );
        assert!(records.iter().all(|r| r.event_name == FLAG));
    }

    #[test]
    fn a_healthy_unit_emits_no_flag_records_at_all() {
        let cycle = Cycle {
            qpiws: Some(parse_qpiws(&[b'0'; 36]).unwrap()),
            ..Default::default()
        };
        assert!(flag_records(&cycle).is_empty());
        assert_eq!(body(&status_record(&cycle), "warnings_asserted_count"), Value::Int(0));
    }

    #[test]
    fn the_inverter_fault_bit_is_promoted_onto_the_status_record() {
        let mut bits = [b'0'; 36];
        bits[1] = b'1';
        let cycle =
            Cycle { qpiws: Some(parse_qpiws(&bits).unwrap()), ..Default::default() };
        assert_eq!(body(&status_record(&cycle), "inverter_fault"), Value::Bool(true));
    }

    #[test]
    fn identity_attributes_are_prefixed_and_skip_what_was_not_read() {
        let attributes = identity_attributes(
            "platform-xhci-hcd.0-usb-0:1:1.0-port0",
            Some("usb-1a86_USB2.0-Ser_-if00-port0"),
            &[
                ("serial_number", Some("92932210103714".to_owned())),
                ("model", Some("MKS2-8000".to_owned())),
                ("firmware_panel", None),
            ],
        );
        assert_eq!(
            attributes,
            vec![
                (
                    "inverter.device".to_owned(),
                    Value::str("platform-xhci-hcd.0-usb-0:1:1.0-port0")
                ),
                (
                    "inverter.device_name".to_owned(),
                    Value::str("usb-1a86_USB2.0-Ser_-if00-port0")
                ),
                ("inverter.serial_number".to_owned(), Value::str("92932210103714")),
                ("inverter.model".to_owned(), Value::str("MKS2-8000")),
            ]
        );
    }

    /// An adapter udev made no by-id link for still reports a device, just without the friendly
    /// name -- the key set stays sane rather than gaining an empty string.
    #[test]
    fn a_device_with_no_by_id_name_omits_the_attribute() {
        let attributes = identity_attributes("port0", None, &[]);
        assert_eq!(attributes, vec![("inverter.device".to_owned(), Value::str("port0"))]);
    }
}
