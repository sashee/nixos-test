//! Verified frames -> numbers in natural units. Pure.
//!
//! Offsets, types and divisors are `spec/features/bms-monitoring/protocol.md` §4-§7. Everything
//! here applies the divisor, so nothing downstream ever sees a raw fixed-point integer -- the
//! divisor depends on the *quantity*, not the width, and a value that escaped this module
//! unscaled would be indistinguishable from a scaled one three digits out.
//!
//! Four of the field table's entries are hardware corrections rather than transcriptions, and each
//! is called out where it is read. They matter because every one of them would otherwise ship as a
//! plausible number: an unsigned power that silently loses the discharge sign, a "temperature 4"
//! that is the MOS sensor counted twice, a pack voltage read one byte off, and a current range
//! ten times too large.

use crate::frame::{Frame, REALTIME, SETTINGS};

// -- primitives -------------------------------------------------------------------------------
// Little-endian throughout (§1). The frame is always 300 bytes by the time it reaches here, so
// these index rather than returning Option: a panic would mean the reader let a short frame past,
// which is a bug in this crate and not a wire condition to degrade over.

fn u16_at(frame: &[u8], offset: usize) -> u16 {
    u16::from_le_bytes([frame[offset], frame[offset + 1]])
}

fn i16_at(frame: &[u8], offset: usize) -> i16 {
    i16::from_le_bytes([frame[offset], frame[offset + 1]])
}

fn u32_at(frame: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes([
        frame[offset],
        frame[offset + 1],
        frame[offset + 2],
        frame[offset + 3],
    ])
}

fn i32_at(frame: &[u8], offset: usize) -> i32 {
    i32::from_le_bytes([
        frame[offset],
        frame[offset + 1],
        frame[offset + 2],
        frame[offset + 3],
    ])
}

/// Volts, amps, watts and amp-hours are all ÷1000 (§4).
fn milli(raw: i64) -> f64 {
    raw as f64 / 1000.0
}

/// Temperatures are ÷10 (§4).
fn deci(raw: i64) -> f64 {
    raw as f64 / 10.0
}

// -- realtime, frame 0x02 ---------------------------------------------------------------------

/// One cell, as the frame reports it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Cell {
    /// 1-based, matching the JK app's own numbering and the `cell` record attribute.
    pub index: u32,
    pub voltage: f64,
    /// Measured balance-wire resistance. The settings frame has a *configured* counterpart that
    /// reads all-zero on this unit, so this is the only one with values in it.
    pub resistance: f64,
}

/// Aggregates over the cell array.
///
/// Computed here rather than read from the frame's own `cellVolAve`/`maxVoltDelta`/`celMaxVol`/
/// `celMinVol`, and that is a decision the hardware forced: those come from a different BMS
/// sample than the cell array in the same frame, and disagreed with it in **12 of 18** frames over
/// a two-minute capture (a frame reporting index 3 while the array's own maximum was index 12).
/// Deriving them keeps one record internally consistent, so a query can compare the delta against
/// the per-cell rows beside it and get the same answer.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CellAggregates {
    pub average: f64,
    pub minimum: f64,
    pub maximum: f64,
    pub delta: f64,
    /// 1-based, like [`Cell::index`]. The frame's own indices are 0-based; converting here is what
    /// lets `cell_min_index` be used directly to look up a `cell` sub-record.
    pub min_index: u32,
    pub max_index: u32,
}

pub fn aggregate(cells: &[Cell]) -> Option<CellAggregates> {
    let first = cells.first()?;
    let mut minimum = first;
    let mut maximum = first;
    let mut total = 0.0;
    for cell in cells {
        if cell.voltage < minimum.voltage {
            minimum = cell;
        }
        if cell.voltage > maximum.voltage {
            maximum = cell;
        }
        total += cell.voltage;
    }
    Some(CellAggregates {
        average: total / cells.len() as f64,
        minimum: minimum.voltage,
        maximum: maximum.voltage,
        delta: maximum.voltage - minimum.voltage,
        min_index: minimum.index,
        max_index: maximum.index,
    })
}

/// The six protection-release countdowns at §6's offsets 202-212. Normally all zero; non-zero
/// means a protection tripped recently and is timing out its recovery.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct ProtectionRelease {
    pub discharge_overcurrent: u16,
    pub discharge_short_circuit: u16,
    pub charge_overcurrent: u16,
    pub charge_short_circuit: u16,
    pub undervoltage: u16,
    pub overvoltage: u16,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Realtime {
    pub cells: Vec<Cell>,
    pub cell_status: u32,
    pub pack_voltage: f64,
    /// Signed: negative while discharging. See [`parse_realtime`] for why this is not simply the
    /// frame's `batWatt`.
    pub pack_power: f64,
    pub pack_current: f64,
    pub mos_temperature: f64,
    /// Sensors 1-5. `None` where the channel is not populated -- see [`parse_realtime`].
    pub temperatures: [Option<f64>; 5],
    pub soc: u8,
    pub soh: u8,
    pub remaining_capacity: f64,
    pub full_charge_capacity: f64,
    pub cycle_count: u32,
    pub cycle_capacity: f64,
    pub balance_current: f64,
    pub balancing: bool,
    pub charge_mosfet_on: bool,
    pub discharge_mosfet_on: bool,
    pub heating_on: bool,
    pub sys_alarm: u32,
    pub user_alarm: u16,
    pub uptime_seconds: u32,
    pub protection_release: ProtectionRelease,
}

impl Realtime {
    pub fn aggregates(&self) -> Option<CellAggregates> {
        aggregate(&self.cells)
    }
}

/// A temperature channel that is not fitted reads exactly 0 on this unit (§6: `batTemp3` "reads
/// 0"). Applied only to channels 3-5, the unconfirmed ones: 0.0 °C is a legitimate reading, so
/// suppressing it is a trade, and it is not worth making for `tempMos`/`batTemp1`/`batTemp2`,
/// which are confirmed live and where a genuine freezing pack must be reportable.
fn optional_temperature(raw: i16) -> Option<f64> {
    (raw != 0).then(|| deci(raw as i64))
}

pub fn parse_realtime(frame: &Frame) -> Result<Realtime, String> {
    if frame.code != REALTIME {
        return Err(format!("expected a 0x02 realtime frame, got 0x{:02x}", frame.code));
    }
    let data = &frame.data;

    // Presence comes from the cellStatus bitmap rather than from "voltage is non-zero": a cell
    // that has collapsed to 0 V is the single most important thing this service can report, and
    // inferring presence from the value would hide exactly that.
    let cell_status = u32_at(data, 70);
    let cells: Vec<Cell> = (0..32)
        .filter(|slot| cell_status & (1 << slot) != 0)
        .map(|slot| Cell {
            index: slot + 1,
            voltage: milli(u16_at(data, 6 + 2 * slot as usize) as i64),
            resistance: milli(u16_at(data, 80 + 2 * slot as usize) as i64),
        })
        .collect();

    let pack_current = milli(i32_at(data, 158) as i64);
    // `batWatt` is an UNSIGNED MAGNITUDE, not a signed power: measured |V*I| = batWatt in 18 of 18
    // frames while the current was negative throughout, and reading the field as i32 yields the
    // same positive number. So the direction lives only in batCurrent, and a consumer handed the
    // raw field would show a discharging pack as generation. (§6. The charge-direction sign is
    // still unverified -- the pack was discharging for every capture.)
    let magnitude = milli(u32_at(data, 154) as i64);
    let pack_power = if pack_current < 0.0 { -magnitude } else { magnitude };

    Ok(Realtime {
        cells,
        cell_status,
        pack_voltage: milli(i32_at(data, 150) as i64),
        pack_power,
        pack_current,
        mos_temperature: deci(i16_at(data, 144) as i64),
        temperatures: [
            Some(deci(i16_at(data, 162) as i64)),
            Some(deci(i16_at(data, 164) as i64)),
            optional_temperature(i16_at(data, 252)),
            // Offset 254 is byte-identical to tempMos@144 in every frame captured, including the
            // frames where both dipped together -- a mirror of the MOS sensor, not a fourth
            // channel (§6). Reported because the key set is fixed and a consumer asking for
            // temperature_4 should get what the frame holds, not a silent null.
            optional_temperature(i16_at(data, 254)),
            optional_temperature(i16_at(data, 256)),
        ],
        soc: data[173],
        soh: data[190],
        remaining_capacity: milli(u32_at(data, 174) as i64),
        full_charge_capacity: milli(u32_at(data, 178) as i64),
        cycle_count: u32_at(data, 182),
        cycle_capacity: milli(u32_at(data, 186) as i64),
        balance_current: milli(i16_at(data, 170) as i64),
        balancing: data[172] != 0,
        charge_mosfet_on: data[198] != 0,
        discharge_mosfet_on: data[199] != 0,
        heating_on: data[215] != 0,
        sys_alarm: u32_at(data, 166),
        user_alarm: u16_at(data, 200),
        uptime_seconds: u32_at(data, 194),
        protection_release: ProtectionRelease {
            discharge_overcurrent: u16_at(data, 202),
            discharge_short_circuit: u16_at(data, 204),
            charge_overcurrent: u16_at(data, 206),
            charge_short_circuit: u16_at(data, 208),
            undervoltage: u16_at(data, 210),
            overvoltage: u16_at(data, 212),
        },
    })
    // Deliberately not read: offset 214, which the device ICD calls `tempSensorAbsent`. It is
    // 0xFF in every frame captured while three sensors were plainly live, so neither polarity is
    // usable -- gating the temperatures on it, as an earlier draft of the feature spec did, would
    // have dropped every temperature this service reports. §6 records the measurement.
    //
    // Also not read: `totalBatVol` at offset 234 (÷100), a lower-precision second reading of the
    // pack voltage already carried by batVol@150. Verified to agree with it, and left out rather
    // than emitted as a near-duplicate column.
}

/// The §6.1 `sysAlarm` bit names, LSB first. Positions 24-31 are undocumented; they are named
/// rather than dropped so an unexpected alarm still produces a queryable record instead of
/// vanishing.
pub const SYS_ALARM_FLAGS: [&str; 32] = [
    "balancing_wire_resistance_high",
    "mos_over_temp",
    "cell_count_mismatch",
    "current_sensor_abnormal",
    "cell_overvoltage",
    "pack_overvoltage",
    "charge_overcurrent",
    "charge_short_circuit",
    "charge_over_temp",
    "charge_low_temp",
    "internal_comms_abnormal",
    "cell_undervoltage",
    "pack_undervoltage",
    "discharge_overcurrent",
    "discharge_short_circuit",
    "discharge_over_temp",
    "charge_anomaly",
    "discharge_anomaly",
    "gps_disconnected",
    "change_authorization_password",
    "discharge_on_failure",
    "battery_over_temp",
    "temp_sensor_anomaly",
    "parallel_module_failure",
    "reserved_24",
    "reserved_25",
    "reserved_26",
    "reserved_27",
    "reserved_28",
    "reserved_29",
    "reserved_30",
    "reserved_31",
];

/// Every asserted alarm bit as (label, name), across both bitmaps.
///
/// The label distinguishes the two words -- `b12` is `sysAlarm` bit 12, `u2b3` is `userAlarm2`
/// bit 3 -- because they are different registers that both start counting at zero. `userAlarm2`
/// has no documented names at all, so its bits get positional ones; naming them after a guess
/// would be worse than leaving the number visible.
pub fn asserted_alarms(sys_alarm: u32, user_alarm: u16) -> Vec<(String, String)> {
    let system = (0..32)
        .filter(move |bit| sys_alarm & (1u32 << bit) != 0)
        .map(|bit| (format!("b{bit}"), SYS_ALARM_FLAGS[bit as usize].to_owned()));
    let user = (0..16)
        .filter(move |bit| user_alarm & (1u16 << bit) != 0)
        .map(|bit| (format!("u2b{bit}"), format!("user_alarm2_{bit}")));
    system.chain(user).collect()
}

// -- settings, frame 0x01 ---------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub struct Settings {
    pub cell_count: u32,
    pub cell_capacity: f64,
    pub cell_undervoltage: f64,
    pub cell_undervoltage_recovery: f64,
    pub cell_overvoltage: f64,
    pub cell_overvoltage_recovery: f64,
    pub cell_request_charge: f64,
    pub cell_request_float: f64,
    pub soc_100_percent: f64,
    pub soc_0_percent: f64,
    pub system_power_off: f64,
    pub balance_trigger_delta: f64,
    pub balance_start_voltage: f64,
    pub balance_current_max: f64,
    pub balancing_enabled: bool,
    pub charge_enabled: bool,
    pub discharge_enabled: bool,
    pub charge_overcurrent: f64,
    pub charge_overcurrent_delay: u32,
    pub charge_overcurrent_release: u32,
    pub discharge_overcurrent: f64,
    pub discharge_overcurrent_delay: u32,
    pub discharge_overcurrent_release: u32,
    pub short_circuit_delay_micros: u32,
    pub short_circuit_release_delay: u32,
    pub charge_over_temp: f64,
    pub charge_over_temp_recovery: f64,
    pub discharge_over_temp: f64,
    pub discharge_over_temp_recovery: f64,
    pub charge_under_temp: f64,
    pub charge_under_temp_recovery: f64,
    pub mos_over_temp: f64,
    pub mos_over_temp_recovery: f64,
    pub smart_sleep_voltage: f64,
    pub smart_sleep_hours: u8,
    pub precharge_seconds: u32,
    pub current_range: f64,
    pub device_address: u32,
    pub switch_status: u16,
    /// Configured per-cell connection resistance. All-zero on this unit; see [`parse_settings`].
    pub cell_resistances: Vec<f64>,
}

pub fn parse_settings(frame: &Frame) -> Result<Settings, String> {
    if frame.code != SETTINGS {
        return Err(format!("expected a 0x01 settings frame, got 0x{:02x}", frame.code));
    }
    let data = &frame.data;

    let cell_count = u32_at(data, 114);
    // A count the frame layout cannot hold is a decode that has gone wrong, not a battery with 900
    // cells: refuse it rather than emit hundreds of sub-records from whatever the bytes said.
    if cell_count > 32 {
        return Err(format!("settings frame claims {cell_count} cells, which exceeds the 32 slots"));
    }

    Ok(Settings {
        cell_count,
        cell_capacity: milli(u32_at(data, 130) as i64),
        cell_undervoltage: milli(u32_at(data, 10) as i64),
        cell_undervoltage_recovery: milli(u32_at(data, 14) as i64),
        cell_overvoltage: milli(u32_at(data, 18) as i64),
        cell_overvoltage_recovery: milli(u32_at(data, 22) as i64),
        cell_request_charge: milli(u32_at(data, 38) as i64),
        cell_request_float: milli(u32_at(data, 42) as i64),
        soc_100_percent: milli(u32_at(data, 30) as i64),
        soc_0_percent: milli(u32_at(data, 34) as i64),
        system_power_off: milli(u32_at(data, 46) as i64),
        balance_trigger_delta: milli(u32_at(data, 26) as i64),
        balance_start_voltage: milli(u32_at(data, 138) as i64),
        balance_current_max: milli(u32_at(data, 78) as i64),
        balancing_enabled: u32_at(data, 126) != 0,
        charge_enabled: u32_at(data, 118) != 0,
        discharge_enabled: u32_at(data, 122) != 0,
        charge_overcurrent: milli(u32_at(data, 50) as i64),
        // The delay and release sub-fields are RAW SECONDS, not ÷1000 like the current beside
        // them (§7's note). Measured: 3 / 60 for charge, 300 / 60 for discharge, where ÷1000
        // would claim a 3-millisecond overcurrent delay. Whether the *delay* values are as-is or
        // ÷10 is unconfirmed without the JK app, so they are passed through as integers -- the
        // honest option, since scaling by a guess cannot be undone downstream.
        charge_overcurrent_delay: u32_at(data, 54),
        charge_overcurrent_release: u32_at(data, 58),
        discharge_overcurrent: milli(u32_at(data, 62) as i64),
        discharge_overcurrent_delay: u32_at(data, 66),
        discharge_overcurrent_release: u32_at(data, 70),
        short_circuit_delay_micros: u32_at(data, 134),
        short_circuit_release_delay: u32_at(data, 74),
        // The eight i32 temperatures at 82..113, in the ICD's order (§7).
        charge_over_temp: deci(i32_at(data, 82) as i64),
        charge_over_temp_recovery: deci(i32_at(data, 86) as i64),
        discharge_over_temp: deci(i32_at(data, 90) as i64),
        discharge_over_temp_recovery: deci(i32_at(data, 94) as i64),
        charge_under_temp: deci(i32_at(data, 98) as i64),
        charge_under_temp_recovery: deci(i32_at(data, 102) as i64),
        mos_over_temp: deci(i32_at(data, 106) as i64),
        mos_over_temp_recovery: deci(i32_at(data, 110) as i64),
        smart_sleep_voltage: milli(u32_at(data, 6) as i64),
        smart_sleep_hours: data[284],
        precharge_seconds: u32_at(data, 274),
        // ÷10000, NOT §4's ÷1000: raw 1500000 is the 150 A this BMS is rated for, and matches
        // the 150 A discharge overcurrent limit in the same frame. ÷1000 would claim 1500 A.
        current_range: u32_at(data, 278) as f64 / 10_000.0,
        device_address: u32_at(data, 270),
        switch_status: u16_at(data, 282),
        // Configured, and all-zero on this unit -- the values a consumer wants are the *measured*
        // ones in the realtime frame's cellWireRes. Emitted anyway because the feature spec asks
        // for the sub-measurement and 16 rows a day is nothing; a future unit that populates it
        // then has somewhere to appear.
        cell_resistances: (0..cell_count)
            .map(|slot| milli(u32_at(data, 142 + 4 * slot as usize) as i64))
            .collect(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures::{realtime_frame, settings_frame};

    // -- realtime, against the frame captured from the live pack ------------------------------

    #[test]
    fn decodes_the_captured_realtime_frame() {
        let realtime = parse_realtime(&realtime_frame()).unwrap();

        // Pack-level values, as read off the hardware at 19:37 UTC on 2026-08-17.
        assert_eq!(realtime.pack_voltage, 52.036);
        assert_eq!(realtime.pack_current, -7.98);
        assert_eq!(realtime.soc, 63);
        assert_eq!(realtime.soh, 100);
        assert_eq!(realtime.remaining_capacity, 145.969);
        assert_eq!(realtime.full_charge_capacity, 230.0);
        assert_eq!(realtime.cycle_count, 191);
        assert_eq!(realtime.cycle_capacity, 44101.642);
        assert_eq!(realtime.uptime_seconds, 38_910_499);
        assert!(realtime.charge_mosfet_on);
        assert!(realtime.discharge_mosfet_on);
        assert!(!realtime.heating_on);
        assert!(!realtime.balancing);
        assert_eq!(realtime.balance_current, 0.0);
    }

    /// The correction that matters most in a dashboard: a discharging pack must not read as
    /// generation. `batWatt` is a magnitude and the sign comes from the current.
    #[test]
    fn power_takes_its_sign_from_the_current() {
        let realtime = parse_realtime(&realtime_frame()).unwrap();
        assert!(realtime.pack_current < 0.0, "the captured pack was discharging");
        assert_eq!(realtime.pack_power, -415.243);
        // And it is the frame's own magnitude, not a re-derived V*I.
        assert!((realtime.pack_power.abs() - 415.243).abs() < 1e-9);
    }

    /// The same field read as a signed integer would have looked fine, which is why this is a
    /// test and not a comment: the magnitude is positive, so nothing about the raw bytes reveals
    /// the missing sign.
    #[test]
    fn a_charging_pack_reports_positive_power() {
        let mut frame = realtime_frame();
        // +7.98 A, magnitude untouched.
        frame.data[158..162].copy_from_slice(&7980i32.to_le_bytes());
        let realtime = parse_realtime(&frame).unwrap();
        assert!(realtime.pack_current > 0.0);
        assert_eq!(realtime.pack_power, 415.243);
    }

    #[test]
    fn decodes_sixteen_cells_from_the_status_bitmap() {
        let realtime = parse_realtime(&realtime_frame()).unwrap();
        assert_eq!(realtime.cell_status, 0x0000_ffff);
        assert_eq!(realtime.cells.len(), 16);
        // 1-based, contiguous.
        assert_eq!(realtime.cells[0].index, 1);
        assert_eq!(realtime.cells[15].index, 16);
        assert_eq!(realtime.cells[0].voltage, 3.254);
        assert_eq!(realtime.cells[4].voltage, 3.249);
        // Measured balance-wire resistance, ÷1000 into ohms.
        assert_eq!(realtime.cells[0].resistance, 0.068);
    }

    /// A collapsed cell is the headline failure this service exists to catch, so presence must
    /// come from the bitmap rather than from the voltage being non-zero.
    #[test]
    fn a_cell_at_zero_volts_is_still_a_present_cell() {
        let mut frame = realtime_frame();
        frame.data[6..8].copy_from_slice(&0u16.to_le_bytes());
        let realtime = parse_realtime(&frame).unwrap();
        assert_eq!(realtime.cells.len(), 16, "the cell must not disappear from the record");
        assert_eq!(realtime.cells[0].voltage, 0.0);
    }

    #[test]
    fn aggregates_are_derived_from_the_cell_array() {
        let realtime = parse_realtime(&realtime_frame()).unwrap();
        let aggregates = realtime.aggregates().unwrap();
        assert_eq!(aggregates.maximum, 3.254);
        assert_eq!(aggregates.minimum, 3.249);
        assert!((aggregates.delta - 0.005).abs() < 1e-9);
        // 1-based: cell 5 holds the 3.249 the frame's own 0-based celMinVol calls index 4.
        assert_eq!(aggregates.min_index, 5);
        assert_eq!(aggregates.max_index, 1);
        // The 16 cells sum to exactly the reported pack voltage, which is a pleasant check on
        // both: 52.036 V over 16 cells.
        assert!((aggregates.average - 3.25225).abs() < 1e-9);
    }

    /// The frame's own aggregates disagreed with its cell array in 12 of 18 captured frames, so
    /// this asserts we ignore them: a planted celMaxVol must not move what we report.
    #[test]
    fn the_frames_own_indices_are_not_what_gets_reported() {
        let mut frame = realtime_frame();
        frame.data[78] = 9; // celMaxVol, 0-based, deliberately wrong
        frame.data[79] = 9; // celMinVol
        frame.data[76..78].copy_from_slice(&999u16.to_le_bytes()); // maxVoltDelta
        let aggregates = parse_realtime(&frame).unwrap().aggregates().unwrap();
        assert_eq!(aggregates.max_index, 1, "must come from cellVol[], not celMaxVol");
        assert_eq!(aggregates.min_index, 5);
        assert!((aggregates.delta - 0.005).abs() < 1e-9);
    }

    #[test]
    fn reports_the_three_confirmed_temperature_sensors() {
        let realtime = parse_realtime(&realtime_frame()).unwrap();
        assert_eq!(realtime.mos_temperature, 36.7);
        assert_eq!(realtime.temperatures[0], Some(36.1));
        assert_eq!(realtime.temperatures[1], Some(35.8));
        // Channel 3 is not populated on this unit and reads exactly 0.
        assert_eq!(realtime.temperatures[2], None);
        // Channel 4 mirrors tempMos byte for byte.
        assert_eq!(realtime.temperatures[3], Some(36.7));
        assert_eq!(realtime.temperatures[4], Some(37.0));
    }

    /// Byte 214 is 0xFF with the sensors plainly live, so it must not gate anything. If someone
    /// re-reads it as a present/absent map, every temperature goes null and this fails.
    #[test]
    fn the_bogus_sensor_absent_byte_does_not_suppress_temperatures() {
        let frame = realtime_frame();
        assert_eq!(frame.data[214], 0xFF, "the captured frame must keep the byte that misleads");
        let realtime = parse_realtime(&frame).unwrap();
        assert!(realtime.temperatures[0].is_some());
        assert!(realtime.temperatures[1].is_some());
        assert_eq!(realtime.mos_temperature, 36.7);
    }

    /// A confirmed sensor at exactly 0 °C is a reading, not an absence -- the case the
    /// zero-means-absent rule must not extend to.
    #[test]
    fn a_freezing_pack_still_reports_its_confirmed_sensors() {
        let mut frame = realtime_frame();
        frame.data[162..164].copy_from_slice(&0i16.to_le_bytes());
        frame.data[164..166].copy_from_slice(&(-15i16).to_le_bytes());
        let realtime = parse_realtime(&frame).unwrap();
        assert_eq!(realtime.temperatures[0], Some(0.0));
        assert_eq!(realtime.temperatures[1], Some(-1.5), "temperatures are signed");
    }

    #[test]
    fn a_healthy_pack_has_no_alarms() {
        let realtime = parse_realtime(&realtime_frame()).unwrap();
        assert_eq!(realtime.sys_alarm, 0);
        assert_eq!(realtime.user_alarm, 0);
        assert!(asserted_alarms(realtime.sys_alarm, realtime.user_alarm).is_empty());
        assert_eq!(realtime.protection_release, ProtectionRelease::default());
    }

    #[test]
    fn alarm_bits_are_labelled_by_register_and_named() {
        let alarms = asserted_alarms(1 << 11 | 1 << 4, 1 << 3);
        assert_eq!(
            alarms,
            vec![
                ("b4".to_owned(), "cell_overvoltage".to_owned()),
                ("b11".to_owned(), "cell_undervoltage".to_owned()),
                ("u2b3".to_owned(), "user_alarm2_3".to_owned()),
            ]
        );
    }

    /// An undocumented bit still produces a record. Silence would be the one unacceptable
    /// outcome for an alarm nobody has seen before.
    #[test]
    fn an_undocumented_alarm_bit_is_still_reported() {
        let alarms = asserted_alarms(1 << 31, 0);
        assert_eq!(alarms, vec![("b31".to_owned(), "reserved_31".to_owned())]);
    }

    #[test]
    fn the_alarm_table_covers_every_bit_of_the_word() {
        assert_eq!(SYS_ALARM_FLAGS.len(), 32);
        assert_eq!(SYS_ALARM_FLAGS[1], "mos_over_temp");
        assert_eq!(SYS_ALARM_FLAGS[15], "discharge_over_temp");
        assert_eq!(SYS_ALARM_FLAGS[23], "parallel_module_failure");
    }

    #[test]
    fn protection_release_timers_are_read_in_order() {
        let mut frame = realtime_frame();
        for (index, offset) in [202usize, 204, 206, 208, 210, 212].iter().enumerate() {
            frame.data[*offset..*offset + 2]
                .copy_from_slice(&((index as u16 + 1) * 10).to_le_bytes());
        }
        let timers = parse_realtime(&frame).unwrap().protection_release;
        assert_eq!(
            timers,
            ProtectionRelease {
                discharge_overcurrent: 10,
                discharge_short_circuit: 20,
                charge_overcurrent: 30,
                charge_short_circuit: 40,
                undervoltage: 50,
                overvoltage: 60,
            }
        );
    }

    #[test]
    fn a_settings_frame_is_refused_by_the_realtime_decoder() {
        assert!(parse_realtime(&settings_frame()).is_err());
        assert!(parse_settings(&realtime_frame()).is_err());
    }

    // -- settings ----------------------------------------------------------------------------

    #[test]
    fn decodes_the_captured_settings_frame() {
        let settings = parse_settings(&settings_frame()).unwrap();

        assert_eq!(settings.cell_count, 16);
        assert_eq!(settings.cell_capacity, 230.0);
        assert_eq!(settings.cell_undervoltage, 2.6);
        assert_eq!(settings.cell_undervoltage_recovery, 2.85);
        assert_eq!(settings.cell_overvoltage, 3.6);
        assert_eq!(settings.cell_overvoltage_recovery, 3.5);
        assert_eq!(settings.cell_request_charge, 3.58);
        assert_eq!(settings.cell_request_float, 3.5);
        assert_eq!(settings.soc_100_percent, 3.55);
        assert_eq!(settings.soc_0_percent, 2.8);
        assert_eq!(settings.system_power_off, 2.5);
        assert_eq!(settings.balance_trigger_delta, 0.01);
        assert_eq!(settings.balance_start_voltage, 3.2);
        assert_eq!(settings.balance_current_max, 1.0);
        assert_eq!(settings.smart_sleep_voltage, 3.5);
        assert_eq!(settings.smart_sleep_hours, 60);
        assert!(settings.balancing_enabled);
        assert!(settings.charge_enabled);
        assert!(settings.discharge_enabled);
        assert_eq!(settings.device_address, 0);
        assert_eq!(settings.precharge_seconds, 0);
        assert_eq!(settings.switch_status, 0x3210);
        assert_eq!(settings.short_circuit_delay_micros, 1500);
    }

    /// The current in these rows is ÷1000, the two times beside it are not. §4 applied uniformly
    /// would report a 3-millisecond overcurrent delay.
    #[test]
    fn overcurrent_currents_are_scaled_and_their_delays_are_not() {
        let settings = parse_settings(&settings_frame()).unwrap();
        assert_eq!(settings.charge_overcurrent, 100.0);
        assert_eq!(settings.charge_overcurrent_delay, 3);
        assert_eq!(settings.charge_overcurrent_release, 60);
        assert_eq!(settings.discharge_overcurrent, 150.0);
        assert_eq!(settings.discharge_overcurrent_delay, 300);
        assert_eq!(settings.discharge_overcurrent_release, 60);
        assert_eq!(settings.short_circuit_release_delay, 5);
    }

    /// ÷10000, and the cross-check that says so: the range must match the pack's own discharge
    /// overcurrent limit, which is scaled independently.
    #[test]
    fn the_current_range_divisor_agrees_with_the_overcurrent_limit() {
        let settings = parse_settings(&settings_frame()).unwrap();
        assert_eq!(settings.current_range, 150.0);
        assert_eq!(settings.current_range, settings.discharge_overcurrent);
    }

    #[test]
    fn the_eight_protection_temperatures_are_in_the_icd_order() {
        let settings = parse_settings(&settings_frame()).unwrap();
        assert_eq!(settings.charge_over_temp, 70.0);
        assert_eq!(settings.charge_over_temp_recovery, 60.0);
        assert_eq!(settings.discharge_over_temp, 70.0);
        assert_eq!(settings.discharge_over_temp_recovery, 60.0);
        assert_eq!(settings.charge_under_temp, 2.0);
        assert_eq!(settings.charge_under_temp_recovery, 7.0);
        assert_eq!(settings.mos_over_temp, 80.0);
        assert_eq!(settings.mos_over_temp_recovery, 70.0);
    }

    #[test]
    fn the_configured_cell_resistances_are_one_per_cell_and_zero_here() {
        let settings = parse_settings(&settings_frame()).unwrap();
        assert_eq!(settings.cell_resistances.len(), 16);
        assert!(settings.cell_resistances.iter().all(|value| *value == 0.0));
    }

    /// A decode that has gone wrong must not turn into hundreds of sub-records.
    #[test]
    fn an_impossible_cell_count_is_refused() {
        let mut frame = settings_frame();
        frame.data[114..118].copy_from_slice(&900u32.to_le_bytes());
        let error = parse_settings(&frame).unwrap_err();
        assert!(error.contains("900"), "{error}");
    }
}
