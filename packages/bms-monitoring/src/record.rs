//! Readings -> the records the receiver stores. Pure.
//!
//! Two measurements, as `spec/features/bms-monitoring/bms-monitoring.md` lays them out:
//! `bms.status` every minute with a `cell` sub-record per present cell and an `alarm` sub-record
//! per asserted bit, and `bms.settings` once at connect and then daily with a `cell` sub-record per
//! configured cell.
//!
//! Record count is the thing to watch. The receiver has no retention, so at a one-minute cadence
//! each record per cycle is another ~525k permanent rows a year on a 29 GB SD card. Sixteen cell
//! rows a minute is the deliberate exception -- ~8.4M rows a year -- and it is the point of
//! monitoring a battery at all: the pack-level aggregates cannot tell you *which* cell is drifting,
//! and by the time a delta is visible in the average the answer matters. Alarms are free in the
//! normal case, because a healthy pack asserts nothing.

use crate::parse::{asserted_alarms, Realtime, Settings};

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

pub const STATUS: &str = "bms.status";
pub const STATUS_CELL: &str = "bms.status.cell";
pub const STATUS_ALARM: &str = "bms.status.alarm";
pub const SETTINGS: &str = "bms.settings";
pub const SETTINGS_CELL: &str = "bms.settings.cell";

/// Counters describing the serial link itself, carried on the status record.
///
/// The only place a degraded line is ever visible. A cable dropping a third of its frames looks
/// exactly like a healthy one from any single measurement, because the next frame is along in under
/// seven seconds -- so without these, noise is invisible until it is total.
#[derive(Debug, Default, Clone, Copy, PartialEq)]
pub struct Link {
    pub connected_seconds: u64,
    pub frames_ok: u64,
    pub frames_discarded: u64,
    /// How old the published frame was when it was published -- the producer drains the port
    /// continuously and reports the freshest frame it has, so this is staleness, not waiting.
    /// Expected to sit well under the ~6.7s cycle; a number creeping towards the frame timeout is
    /// the early warning that the link is failing.
    pub wait_seconds: f64,
}

fn opt(value: Option<Value>) -> Value {
    value.unwrap_or(Value::Null)
}

fn num(value: Option<f64>) -> Value {
    opt(value.map(Value::Double))
}

/// One `bms.status` record, then one per present cell, then one per asserted alarm.
///
/// Every key on the status record is always present, in this order. A key is never dropped, only
/// nulled: a consumer should see the same column set from every cycle, whether or not this unit
/// populates a given temperature channel.
pub fn status_records(realtime: &Realtime, link: &Link) -> Vec<Record> {
    let aggregates = realtime.aggregates();

    let mut records = vec![Record::new(STATUS)
        .with_field("pack_voltage_volts", Value::Double(realtime.pack_voltage))
        .with_field("pack_current_amps", Value::Double(realtime.pack_current))
        .with_field("pack_power_watts", Value::Double(realtime.pack_power))
        .with_field("soc_percent", Value::Int(realtime.soc as i64))
        .with_field("soh_percent", Value::Int(realtime.soh as i64))
        .with_field("remaining_capacity_ah", Value::Double(realtime.remaining_capacity))
        .with_field("full_charge_capacity_ah", Value::Double(realtime.full_charge_capacity))
        .with_field("cycle_capacity_ah", Value::Double(realtime.cycle_capacity))
        .with_field("cycle_count", Value::Int(realtime.cycle_count as i64))
        .with_field("cell_voltage_average_volts", num(aggregates.map(|a| a.average)))
        .with_field("cell_voltage_delta_volts", num(aggregates.map(|a| a.delta)))
        .with_field("cell_voltage_min_volts", num(aggregates.map(|a| a.minimum)))
        .with_field("cell_voltage_max_volts", num(aggregates.map(|a| a.maximum)))
        .with_field(
            "cell_min_index",
            opt(aggregates.map(|a| Value::Int(a.min_index as i64))),
        )
        .with_field(
            "cell_max_index",
            opt(aggregates.map(|a| Value::Int(a.max_index as i64))),
        )
        .with_field("cells_present", Value::Int(realtime.cells.len() as i64))
        .with_field("mos_temperature_celsius", Value::Double(realtime.mos_temperature))
        .with_field("temperature_1_celsius", num(realtime.temperatures[0]))
        .with_field("temperature_2_celsius", num(realtime.temperatures[1]))
        .with_field("temperature_3_celsius", num(realtime.temperatures[2]))
        .with_field("temperature_4_celsius", num(realtime.temperatures[3]))
        .with_field("temperature_5_celsius", num(realtime.temperatures[4]))
        .with_field("balance_current_amps", Value::Double(realtime.balance_current))
        .with_field("balancing", Value::Bool(realtime.balancing))
        .with_field("charge_mosfet_on", Value::Bool(realtime.charge_mosfet_on))
        .with_field("discharge_mosfet_on", Value::Bool(realtime.discharge_mosfet_on))
        .with_field("heating_on", Value::Bool(realtime.heating_on))
        // Kept beside the alarm sub-records, and the reason they can be emitted only when
        // asserted: these three make "all clear" provable in the sub-records' absence.
        .with_field("alarms_raw", Value::Int(realtime.sys_alarm as i64))
        .with_field(
            "alarms_asserted_count",
            Value::Int(
                (realtime.sys_alarm.count_ones() + realtime.user_alarm.count_ones()) as i64,
            ),
        )
        .with_field("alarms2_raw", Value::Int(realtime.user_alarm as i64))
        .with_field("bms_uptime_seconds", Value::Int(realtime.uptime_seconds as i64))
        .with_field(
            "protection_release_discharge_oc_seconds",
            Value::Int(realtime.protection_release.discharge_overcurrent as i64),
        )
        .with_field(
            "protection_release_discharge_sc_seconds",
            Value::Int(realtime.protection_release.discharge_short_circuit as i64),
        )
        .with_field(
            "protection_release_charge_oc_seconds",
            Value::Int(realtime.protection_release.charge_overcurrent as i64),
        )
        .with_field(
            "protection_release_charge_sc_seconds",
            Value::Int(realtime.protection_release.charge_short_circuit as i64),
        )
        .with_field(
            "protection_release_uv_seconds",
            Value::Int(realtime.protection_release.undervoltage as i64),
        )
        .with_field(
            "protection_release_ov_seconds",
            Value::Int(realtime.protection_release.overvoltage as i64),
        )
        .with_field("link_connected_seconds", Value::Int(link.connected_seconds as i64))
        .with_field("link_frames_ok", Value::Int(link.frames_ok as i64))
        .with_field("link_frames_discarded", Value::Int(link.frames_discarded as i64))
        .with_field("link_frame_wait_seconds", Value::Double(link.wait_seconds))];

    records.extend(realtime.cells.iter().map(|cell| {
        Record::new(STATUS_CELL)
            .with_attr("cell", Value::Int(cell.index as i64))
            .with_field("voltage_volts", Value::Double(cell.voltage))
            .with_field("wire_resistance_ohms", Value::Double(cell.resistance))
    }));

    // One per asserted bit, and none at all in the normal case. The names cannot live on the
    // status record: a record has one attribute set, so a queryable name per bit needs a record
    // per bit.
    records.extend(asserted_alarms(realtime.sys_alarm, realtime.user_alarm).into_iter().map(
        |(bit, flag)| {
            Record::new(STATUS_ALARM)
                .with_attr("bit", Value::Str(bit))
                .with_attr("flag", Value::Str(flag))
                .with_field("asserted", Value::Bool(true))
        },
    ));

    records
}

/// One `bms.settings` record, then one per configured cell.
///
/// Nearly static, so consecutive records are a configuration-change audit trail: the value is not
/// any single row but the diff between two of them.
pub fn settings_records(settings: &Settings) -> Vec<Record> {
    let mut records = vec![Record::new(SETTINGS)
        .with_field("cell_count", Value::Int(settings.cell_count as i64))
        .with_field("cell_capacity_ah", Value::Double(settings.cell_capacity))
        .with_field("cell_undervoltage_volts", Value::Double(settings.cell_undervoltage))
        .with_field(
            "cell_undervoltage_recovery_volts",
            Value::Double(settings.cell_undervoltage_recovery),
        )
        .with_field("cell_overvoltage_volts", Value::Double(settings.cell_overvoltage))
        .with_field(
            "cell_overvoltage_recovery_volts",
            Value::Double(settings.cell_overvoltage_recovery),
        )
        .with_field("cell_request_charge_volts", Value::Double(settings.cell_request_charge))
        .with_field("cell_request_float_volts", Value::Double(settings.cell_request_float))
        .with_field("soc_100_percent_volts", Value::Double(settings.soc_100_percent))
        .with_field("soc_0_percent_volts", Value::Double(settings.soc_0_percent))
        .with_field("system_power_off_volts", Value::Double(settings.system_power_off))
        .with_field("balance_trigger_delta_volts", Value::Double(settings.balance_trigger_delta))
        .with_field("balance_start_voltage_volts", Value::Double(settings.balance_start_voltage))
        .with_field("balance_current_max_amps", Value::Double(settings.balance_current_max))
        .with_field("balancing_enabled", Value::Bool(settings.balancing_enabled))
        .with_field("charge_enabled", Value::Bool(settings.charge_enabled))
        .with_field("discharge_enabled", Value::Bool(settings.discharge_enabled))
        .with_field("charge_overcurrent_amps", Value::Double(settings.charge_overcurrent))
        .with_field(
            "charge_overcurrent_delay_seconds",
            Value::Int(settings.charge_overcurrent_delay as i64),
        )
        .with_field(
            "charge_overcurrent_release_seconds",
            Value::Int(settings.charge_overcurrent_release as i64),
        )
        .with_field("discharge_overcurrent_amps", Value::Double(settings.discharge_overcurrent))
        .with_field(
            "discharge_overcurrent_delay_seconds",
            Value::Int(settings.discharge_overcurrent_delay as i64),
        )
        .with_field(
            "discharge_overcurrent_release_seconds",
            Value::Int(settings.discharge_overcurrent_release as i64),
        )
        .with_field(
            "short_circuit_delay_micros",
            Value::Int(settings.short_circuit_delay_micros as i64),
        )
        .with_field(
            "short_circuit_release_delay_seconds",
            Value::Int(settings.short_circuit_release_delay as i64),
        )
        .with_field("charge_over_temp_celsius", Value::Double(settings.charge_over_temp))
        .with_field(
            "charge_over_temp_recovery_celsius",
            Value::Double(settings.charge_over_temp_recovery),
        )
        .with_field("discharge_over_temp_celsius", Value::Double(settings.discharge_over_temp))
        .with_field(
            "discharge_over_temp_recovery_celsius",
            Value::Double(settings.discharge_over_temp_recovery),
        )
        .with_field("charge_under_temp_celsius", Value::Double(settings.charge_under_temp))
        .with_field(
            "charge_under_temp_recovery_celsius",
            Value::Double(settings.charge_under_temp_recovery),
        )
        .with_field("mos_over_temp_celsius", Value::Double(settings.mos_over_temp))
        .with_field("mos_over_temp_recovery_celsius", Value::Double(settings.mos_over_temp_recovery))
        .with_field("smart_sleep_volts", Value::Double(settings.smart_sleep_voltage))
        .with_field("smart_sleep_hours", Value::Int(settings.smart_sleep_hours as i64))
        .with_field("precharge_seconds", Value::Int(settings.precharge_seconds as i64))
        .with_field("current_range_amps", Value::Double(settings.current_range))
        .with_field("device_address", Value::Int(settings.device_address as i64))
        .with_field("switch_status_raw", Value::Int(settings.switch_status as i64))];

    records.extend(settings.cell_resistances.iter().enumerate().map(|(slot, resistance)| {
        Record::new(SETTINGS_CELL)
            .with_attr("cell", Value::Int(slot as i64 + 1))
            .with_field("connection_resistance_ohms", Value::Double(*resistance))
    }));

    records
}

/// Resource attributes describing the port the pack is behind.
///
/// There is no device identity to put here, and that is a property of the protocol rather than an
/// omission: the `0x03` device-info frame is never pushed, and this producer never sends a request,
/// so there is no serial number, model or firmware version to be had. `bms.device` -- the by-path
/// key -- is the only identity available, with udev's by-id name beside it because that is the one
/// a human reading a query recognises.
pub fn device_attributes(device: &str, device_name: Option<&str>) -> Vec<(String, Value)> {
    let mut attributes = vec![("bms.device".to_owned(), Value::str(device))];
    if let Some(name) = device_name {
        attributes.push(("bms.device_name".to_owned(), Value::str(name)));
    }
    attributes
}

/// Human-readable rendering for `--dry-run`, same shape as the sibling producers'.
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
    use crate::fixtures::{realtime_frame, settings_frame};
    use crate::parse::{parse_realtime, parse_settings};

    fn link() -> Link {
        Link { connected_seconds: 90, frames_ok: 13, frames_discarded: 1, wait_seconds: 6.7 }
    }

    fn realtime() -> Realtime {
        parse_realtime(&realtime_frame()).unwrap()
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

    fn of_type<'a>(records: &'a [Record], event: &str) -> Vec<&'a Record> {
        records.iter().filter(|record| record.event_name == event).collect()
    }

    #[test]
    fn one_frame_is_one_status_record_plus_one_row_per_cell() {
        let records = status_records(&realtime(), &link());
        assert_eq!(of_type(&records, STATUS).len(), 1);
        assert_eq!(of_type(&records, STATUS_CELL).len(), 16);
        // A healthy pack: no alarm records at all.
        assert!(of_type(&records, STATUS_ALARM).is_empty());
    }

    #[test]
    fn the_status_record_carries_the_scaled_pack_values() {
        let records = status_records(&realtime(), &link());
        let status = of_type(&records, STATUS)[0];
        assert_eq!(body(status, "pack_voltage_volts"), Value::Double(52.036));
        assert_eq!(body(status, "pack_current_amps"), Value::Double(-7.98));
        assert_eq!(body(status, "soc_percent"), Value::Int(63));
        assert_eq!(body(status, "soh_percent"), Value::Int(100));
        assert_eq!(body(status, "remaining_capacity_ah"), Value::Double(145.969));
        assert_eq!(body(status, "cycle_count"), Value::Int(191));
        assert_eq!(body(status, "cells_present"), Value::Int(16));
        assert_eq!(body(status, "bms_uptime_seconds"), Value::Int(38_910_499));
    }

    /// The dashboard-facing correction: a discharging pack reports negative power.
    #[test]
    fn power_is_negative_while_discharging() {
        let records = status_records(&realtime(), &link());
        assert_eq!(body(of_type(&records, STATUS)[0], "pack_power_watts"), Value::Double(-415.243));
    }

    #[test]
    fn cell_rows_are_numbered_from_one_and_carry_both_values() {
        let records = status_records(&realtime(), &link());
        let cells = of_type(&records, STATUS_CELL);
        assert_eq!(cells[0].attributes, vec![("cell".to_owned(), Value::Int(1))]);
        assert_eq!(body(cells[0], "voltage_volts"), Value::Double(3.254));
        assert_eq!(body(cells[0], "wire_resistance_ohms"), Value::Double(0.068));
        assert_eq!(cells[15].attributes, vec![("cell".to_owned(), Value::Int(16))]);
    }

    /// The index on the status record must be usable to look up a cell row -- which is only true
    /// if both are 1-based, and the frame's own indices are not.
    #[test]
    fn the_reported_indices_address_the_cell_rows() {
        let records = status_records(&realtime(), &link());
        let status = of_type(&records, STATUS)[0];
        let cells = of_type(&records, STATUS_CELL);

        let Value::Int(min_index) = body(status, "cell_min_index") else {
            panic!("cell_min_index must be an integer");
        };
        let lowest = cells
            .iter()
            .find(|cell| cell.attributes[0].1 == Value::Int(min_index))
            .expect("cell_min_index must name a cell row");
        assert_eq!(body(lowest, "voltage_volts"), body(status, "cell_voltage_min_volts"));
        assert_eq!(body(lowest, "voltage_volts"), Value::Double(3.249));
    }

    #[test]
    fn an_unpopulated_temperature_channel_is_null_not_zero() {
        let records = status_records(&realtime(), &link());
        let status = of_type(&records, STATUS)[0];
        assert_eq!(body(status, "mos_temperature_celsius"), Value::Double(36.7));
        assert_eq!(body(status, "temperature_1_celsius"), Value::Double(36.1));
        assert_eq!(body(status, "temperature_2_celsius"), Value::Double(35.8));
        assert_eq!(
            body(status, "temperature_3_celsius"),
            Value::Null,
            "channel 3 is not fitted and must not read as a freezing pack"
        );
        assert_eq!(body(status, "temperature_5_celsius"), Value::Double(37.0));
    }

    /// The key set must not depend on what this frame happened to contain.
    #[test]
    fn the_status_key_set_is_the_same_whatever_the_frame_holds() {
        let full = realtime();
        let mut sparse = full.clone();
        sparse.temperatures = [None; 5];
        sparse.cells.clear();

        let keys = |realtime: &Realtime| -> Vec<String> {
            let records = status_records(realtime, &link());
            of_type(&records, STATUS)[0].body.iter().map(|(key, _)| key.clone()).collect()
        };
        assert_eq!(keys(&full), keys(&sparse));

        let records = status_records(&sparse, &link());
        let status = of_type(&records, STATUS)[0];
        // With no cells there are no aggregates, and they null rather than vanish.
        assert_eq!(body(status, "cell_voltage_average_volts"), Value::Null);
        assert_eq!(body(status, "cell_min_index"), Value::Null);
        assert_eq!(body(status, "cells_present"), Value::Int(0));
        assert!(of_type(&records, STATUS_CELL).is_empty());
    }

    #[test]
    fn the_link_counters_are_always_known() {
        let records = status_records(&realtime(), &link());
        let status = of_type(&records, STATUS)[0];
        assert_eq!(body(status, "link_connected_seconds"), Value::Int(90));
        assert_eq!(body(status, "link_frames_ok"), Value::Int(13));
        assert_eq!(body(status, "link_frames_discarded"), Value::Int(1));
        assert_eq!(body(status, "link_frame_wait_seconds"), Value::Double(6.7));
    }

    #[test]
    fn an_asserted_alarm_becomes_a_named_sub_record() {
        let mut realtime = realtime();
        realtime.sys_alarm = 1 << 11; // cell_undervoltage
        realtime.user_alarm = 1 << 2;

        let records = status_records(&realtime, &link());
        let status = of_type(&records, STATUS)[0];
        assert_eq!(body(status, "alarms_asserted_count"), Value::Int(2));
        assert_eq!(body(status, "alarms_raw"), Value::Int(2048));
        assert_eq!(body(status, "alarms2_raw"), Value::Int(4));

        let alarms = of_type(&records, STATUS_ALARM);
        assert_eq!(alarms.len(), 2, "the count and the rows must agree");
        assert_eq!(
            alarms[0].attributes,
            vec![
                ("bit".to_owned(), Value::str("b11")),
                ("flag".to_owned(), Value::str("cell_undervoltage")),
            ]
        );
        assert_eq!(body(alarms[0], "asserted"), Value::Bool(true));
        assert_eq!(alarms[1].attributes[0].1, Value::str("u2b2"));
    }

    /// `alarms_asserted_count` is what makes "all clear" provable from the status record alone,
    /// so it must equal the number of sub-records for any combination of bits.
    #[test]
    fn the_asserted_count_always_matches_the_number_of_alarm_rows() {
        for (sys, user) in [(0u32, 0u16), (1, 0), (0, 1), (0xffff_ffff, 0xffff), (1 << 31, 1 << 15)]
        {
            let mut realtime = realtime();
            realtime.sys_alarm = sys;
            realtime.user_alarm = user;
            let records = status_records(&realtime, &link());
            let rows = of_type(&records, STATUS_ALARM).len();
            assert_eq!(
                body(of_type(&records, STATUS)[0], "alarms_asserted_count"),
                Value::Int(rows as i64),
                "sys={sys:#x} user={user:#x}"
            );
        }
    }

    #[test]
    fn the_settings_record_carries_the_configured_limits() {
        let settings = parse_settings(&settings_frame()).unwrap();
        let records = settings_records(&settings);
        let record = of_type(&records, SETTINGS)[0];

        assert_eq!(body(record, "cell_count"), Value::Int(16));
        assert_eq!(body(record, "cell_capacity_ah"), Value::Double(230.0));
        assert_eq!(body(record, "cell_overvoltage_volts"), Value::Double(3.6));
        assert_eq!(body(record, "cell_undervoltage_volts"), Value::Double(2.6));
        assert_eq!(body(record, "charge_overcurrent_amps"), Value::Double(100.0));
        assert_eq!(body(record, "discharge_overcurrent_amps"), Value::Double(150.0));
        assert_eq!(body(record, "current_range_amps"), Value::Double(150.0));
        assert_eq!(body(record, "charge_under_temp_celsius"), Value::Double(2.0));
        assert_eq!(body(record, "balancing_enabled"), Value::Bool(true));
        assert_eq!(body(record, "smart_sleep_hours"), Value::Int(60));
        // Raw seconds, not milliseconds: §4's divisor does not apply to these two.
        assert_eq!(body(record, "charge_overcurrent_delay_seconds"), Value::Int(3));
        assert_eq!(body(record, "discharge_overcurrent_delay_seconds"), Value::Int(300));
    }

    #[test]
    fn settings_emits_one_cell_row_per_configured_cell() {
        let settings = parse_settings(&settings_frame()).unwrap();
        let records = settings_records(&settings);
        let cells = of_type(&records, SETTINGS_CELL);
        assert_eq!(cells.len(), 16);
        assert_eq!(cells[0].attributes, vec![("cell".to_owned(), Value::Int(1))]);
        assert_eq!(cells[15].attributes, vec![("cell".to_owned(), Value::Int(16))]);
        assert_eq!(body(cells[0], "connection_resistance_ohms"), Value::Double(0.0));
    }

    /// The protocol offers no device identity at all, so the port is the whole of it.
    #[test]
    fn device_attributes_name_the_port_and_skip_a_missing_by_id() {
        assert_eq!(
            device_attributes("platform-xhci-hcd.0-usb-0:1:1.0-port0", Some("usb-FTDI-if00-port0")),
            vec![
                (
                    "bms.device".to_owned(),
                    Value::str("platform-xhci-hcd.0-usb-0:1:1.0-port0")
                ),
                ("bms.device_name".to_owned(), Value::str("usb-FTDI-if00-port0")),
            ]
        );
        assert_eq!(
            device_attributes("port0", None),
            vec![("bms.device".to_owned(), Value::str("port0"))]
        );
    }

    /// Sixteen cell rows a minute is the cost decision this module's header explains; assert the
    /// count so a change to it is deliberate rather than incidental.
    #[test]
    fn a_healthy_cycle_costs_seventeen_records() {
        assert_eq!(status_records(&realtime(), &link()).len(), 1 + 16);
    }
}
