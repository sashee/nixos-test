//! Payload -> typed readings. Pure, and deliberately strict.
//!
//! Every field is read at a fixed offset with a fixed width, and the payload length is checked
//! first. protocol.md asks for exactly this: the widths are the firmware's ABI, so a field that
//! is one character wider than documented means the unit changed, and the honest response is to
//! reject the frame rather than to `parseFloat` whatever landed at the old offset. A rejected
//! frame costs one cycle of nulls; a silently misread one poisons the history.

/// Operating mode, `QMOD`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    PowerOn,
    Standby,
    Line,
    Battery,
    Fault,
    Shutdown,
    Charge,
    Bypass,
    Eco,
}

impl Mode {
    pub fn from_code(code: u8) -> Option<Mode> {
        Some(match code {
            b'P' => Mode::PowerOn,
            b'S' => Mode::Standby,
            b'L' => Mode::Line,
            b'B' => Mode::Battery,
            b'F' => Mode::Fault,
            b'D' => Mode::Shutdown,
            b'C' => Mode::Charge,
            b'Y' => Mode::Bypass,
            b'E' => Mode::Eco,
            _ => return None,
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            Mode::PowerOn => "power_on",
            Mode::Standby => "standby",
            Mode::Line => "line",
            Mode::Battery => "battery",
            Mode::Fault => "fault",
            Mode::Shutdown => "shutdown",
            Mode::Charge => "charge",
            Mode::Bypass => "bypass",
            Mode::Eco => "eco",
        }
    }
}

/// `QMOD` is one ASCII letter. An unknown letter still yields its code, because "the unit told
/// us something we do not have a name for" is worth recording verbatim.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ModeReading {
    pub code: char,
    pub mode: Option<Mode>,
}

pub fn parse_qmod(payload: &[u8]) -> Result<ModeReading, String> {
    let [code] = payload else {
        return Err(format!("QMOD payload is {} byte(s), expected 1", payload.len()));
    };
    if !code.is_ascii_graphic() {
        return Err(format!("QMOD payload {code:#04x} is not a printable letter"));
    }
    Ok(ModeReading { code: *code as char, mode: Mode::from_code(*code) })
}

/// `QPIGS`, general status. 21 fields in exactly 106 bytes.
#[derive(Debug, PartialEq)]
pub struct Qpigs {
    pub grid_voltage: f64,
    pub grid_frequency: f64,
    pub output_voltage: f64,
    pub output_frequency: f64,
    pub output_apparent_power: i64,
    pub output_active_power: i64,
    pub output_load_percent: i64,
    pub bus_voltage: i64,
    pub battery_voltage: f64,
    pub battery_charging_current: i64,
    pub battery_capacity: i64,
    pub heat_sink_temperature: i64,
    pub pv1_current: f64,
    pub pv1_voltage: f64,
    pub battery_voltage_from_scc1: f64,
    pub battery_discharge_current: i64,
    /// Field 18, documented in 10 mV steps and scaled to volts here.
    pub battery_voltage_offset_fans_on: f64,
    pub eeprom_version: i64,
    pub pv1_charging_power: i64,
    // Field 17, b7..b0 left to right.
    pub add_sbu_priority_version: bool,
    pub configuration_changed: bool,
    pub scc_firmware_updated: bool,
    pub load_on: bool,
    pub battery_voltage_to_steady_while_charging: bool,
    pub charging: bool,
    pub charging_scc: bool,
    pub charging_ac: bool,
    // Field 21, b10..b8 left to right. b8 is not carried: protocol.md assigns it to the Axpert
    // V's "dustproof installed" flag, which this model has no equivalent of, so recording it
    // would be inventing a fact about hardware that does not exist.
    pub float_charge: bool,
    pub switch_on: bool,
}

pub const QPIGS_LEN: usize = 106;

pub fn parse_qpigs(payload: &[u8]) -> Result<Qpigs, String> {
    expect_len("QPIGS", payload, QPIGS_LEN)?;
    // Separators checked as well as offsets. A width change shifts both, but only the separator
    // check catches the case where the shifted field still happens to look like a number.
    for offset in [5, 10, 16, 21, 26, 31, 35, 39, 45, 49, 53, 58, 63, 69, 75, 81, 90, 93, 96, 102]
    {
        if payload[offset] != b' ' {
            return Err(format!(
                "QPIGS separator at offset {offset} is {:?}, not a space -- field widths have \
                 changed",
                payload[offset] as char
            ));
        }
    }

    Ok(Qpigs {
        grid_voltage: decimal(payload, 0, 5)?,
        grid_frequency: decimal(payload, 6, 4)?,
        output_voltage: decimal(payload, 11, 5)?,
        output_frequency: decimal(payload, 17, 4)?,
        output_apparent_power: integer(payload, 22, 4)?,
        output_active_power: integer(payload, 27, 4)?,
        output_load_percent: integer(payload, 32, 3)?,
        bus_voltage: integer(payload, 36, 3)?,
        battery_voltage: decimal(payload, 40, 5)?,
        battery_charging_current: integer(payload, 46, 3)?,
        battery_capacity: integer(payload, 50, 3)?,
        heat_sink_temperature: integer(payload, 54, 4)?,
        pv1_current: decimal(payload, 59, 4)?,
        pv1_voltage: decimal(payload, 64, 5)?,
        battery_voltage_from_scc1: decimal(payload, 70, 5)?,
        battery_discharge_current: integer(payload, 76, 5)?,
        add_sbu_priority_version: bit(payload, 82)?,
        configuration_changed: bit(payload, 83)?,
        scc_firmware_updated: bit(payload, 84)?,
        load_on: bit(payload, 85)?,
        battery_voltage_to_steady_while_charging: bit(payload, 86)?,
        charging: bit(payload, 87)?,
        charging_scc: bit(payload, 88)?,
        charging_ac: bit(payload, 89)?,
        // Divided rather than multiplied by 0.01: 0.01 is not representable, so `57 * 0.01`
        // double-rounds to 0.5700000000000001 and that is what would land in the store.
        battery_voltage_offset_fans_on: integer(payload, 91, 2)? as f64 / 100.0,
        eeprom_version: integer(payload, 94, 2)?,
        pv1_charging_power: integer(payload, 97, 5)?,
        float_charge: bit(payload, 103)?,
        switch_on: bit(payload, 104)?,
    })
}

/// `QPIGS2`, PV2 status. Three fields and a trailing space, 17 bytes.
#[derive(Debug, PartialEq)]
pub struct Qpigs2 {
    pub pv2_current: f64,
    pub pv2_voltage: f64,
    pub pv2_charging_power: i64,
}

pub const QPIGS2_LEN: usize = 17;

pub fn parse_qpigs2(payload: &[u8]) -> Result<Qpigs2, String> {
    expect_len("QPIGS2", payload, QPIGS2_LEN)?;
    // Offset 16 included: the device sends a trailing space the PDF does not document, it is
    // covered by the CRC, and a reader that treated the payload as 16 bytes would be rejecting
    // good frames.
    for offset in [4, 10, 16] {
        if payload[offset] != b' ' {
            return Err(format!(
                "QPIGS2 separator at offset {offset} is {:?}, not a space",
                payload[offset] as char
            ));
        }
    }
    Ok(Qpigs2 {
        pv2_current: decimal(payload, 0, 4)?,
        pv2_voltage: decimal(payload, 5, 5)?,
        pv2_charging_power: integer(payload, 11, 5)?,
    })
}

/// `QPIWS`, warning and fault bits. `aN` is at offset N.
///
/// Normative names, in bit order. Two are `reserved` and two `unknown` in the PDF; they are kept
/// so an index into this table is the bit number, and so a bit that starts asserting on a
/// firmware update is still reportable under a stable name.
pub const WARNING_FLAGS: [&str; 36] = [
    "reserved1",
    "inverter_fault",
    "bus_over",
    "bus_under",
    "bus_soft_fail",
    "line_fail",
    "opvshort",
    "inverter_voltage_too_low",
    "inverter_voltage_too_high",
    "over_temperature",
    "fan_locked",
    "battery_voltage_high",
    "battery_low_alarm",
    "reserved_overcharge",
    "battery_under_shutdown",
    "reserved_battery_derating",
    "over_load",
    "eeprom_fault",
    "inverter_over_current",
    "inverter_soft_fail",
    "self_test_fail",
    "op_dv_voltage_over",
    "bat_open",
    "current_sensor_fail",
    "battery_short",
    "power_limit",
    "pv_voltage_high_1",
    "mppt_overload_fault_1",
    "mppt_overload_warning_1",
    "battery_too_low_to_charge_1",
    "pv_voltage_high_2",
    "mppt_overload_fault_2",
    "mppt_overload_warning_2",
    "battery_too_low_to_charge_2",
    "unknown1",
    "unknown2",
];

/// Index of `inverter_fault` in [`WARNING_FLAGS`], the one bit promoted into the status record.
pub const INVERTER_FAULT_BIT: usize = 1;

#[derive(Debug, PartialEq)]
pub struct Qpiws {
    /// The payload verbatim, so a bit this table has no name for is still recoverable.
    pub raw: String,
    pub bits: [bool; 36],
}

impl Qpiws {
    pub fn asserted_count(&self) -> i64 {
        self.bits.iter().filter(|bit| **bit).count() as i64
    }

    /// `(bit index, flag name)` for every asserted bit.
    pub fn asserted(&self) -> impl Iterator<Item = (usize, &'static str)> + '_ {
        self.bits
            .iter()
            .enumerate()
            .filter(|(_, set)| **set)
            .map(|(index, _)| (index, WARNING_FLAGS[index]))
    }
}

pub fn parse_qpiws(payload: &[u8]) -> Result<Qpiws, String> {
    expect_len("QPIWS", payload, WARNING_FLAGS.len())?;
    let mut bits = [false; 36];
    for (index, slot) in bits.iter_mut().enumerate() {
        *slot = bit(payload, index)?;
    }
    Ok(Qpiws {
        raw: String::from_utf8(payload.to_vec())
            .map_err(|e| format!("QPIWS payload is not ASCII: {e}"))?,
        bits,
    })
}

/// An identity payload: printable ASCII, kept verbatim.
///
/// `QVFW`'s `00072.04` is a version string and not a number -- the PDF says its digits are hex,
/// so `0A` is legal and would sort wrongly as a float. Nothing here parses it.
pub fn parse_identity(command: &str, payload: &[u8]) -> Result<String, String> {
    if payload.is_empty() {
        return Err(format!("{command} payload is empty"));
    }
    if !payload.iter().all(|byte| byte.is_ascii_graphic() || *byte == b' ') {
        return Err(format!("{command} payload is not printable ASCII"));
    }
    Ok(String::from_utf8_lossy(payload).trim().to_owned())
}

// ---------------------------------------------------------------------------------------------

fn expect_len(command: &str, payload: &[u8], want: usize) -> Result<(), String> {
    if payload.len() != want {
        return Err(format!(
            "{command} payload is {} byte(s), expected exactly {want}",
            payload.len()
        ));
    }
    Ok(())
}

fn field<'a>(payload: &'a [u8], offset: usize, width: usize) -> Result<&'a str, String> {
    let slice = payload
        .get(offset..offset + width)
        .ok_or_else(|| format!("field at offset {offset} runs past the payload"))?;
    std::str::from_utf8(slice).map_err(|_| format!("field at offset {offset} is not ASCII"))
}

/// A fixed-width zero-padded integer. Rejects anything that is not exactly `width` digits, so a
/// widened field is an error rather than a truncated value.
fn integer(payload: &[u8], offset: usize, width: usize) -> Result<i64, String> {
    let text = field(payload, offset, width)?;
    if text.len() != width || !text.bytes().all(|b| b.is_ascii_digit()) {
        return Err(format!("expected {width} digits at offset {offset}, got {text:?}"));
    }
    text.parse().map_err(|_| format!("unparsable integer {text:?} at offset {offset}"))
}

/// A fixed-width `NNN.N`-style decimal. The decimal point must be where the format says.
fn decimal(payload: &[u8], offset: usize, width: usize) -> Result<f64, String> {
    let text = field(payload, offset, width)?;
    let digits = text.bytes().filter(u8::is_ascii_digit).count();
    if text.len() != width || text.matches('.').count() != 1 || digits != width - 1 {
        return Err(format!(
            "expected a {width}-character decimal at offset {offset}, got {text:?}"
        ));
    }
    text.parse().map_err(|_| format!("unparsable decimal {text:?} at offset {offset}"))
}

fn bit(payload: &[u8], offset: usize) -> Result<bool, String> {
    match payload.get(offset) {
        Some(b'0') => Ok(false),
        Some(b'1') => Ok(true),
        Some(other) => {
            Err(format!("expected '0' or '1' at offset {offset}, got {:?}", *other as char))
        }
        None => Err(format!("bit at offset {offset} runs past the payload")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The capture from protocol.md.
    const SAMPLE: &[u8] = b"000.0 00.0 226.7 50.0 0997 0825 012 429 54.20 041 080 0062 09.2 196.4 00.00 00000 00010110 00 00 01819 010";

    #[test]
    fn the_documented_sample_is_exactly_the_documented_length() {
        assert_eq!(SAMPLE.len(), QPIGS_LEN);
    }

    #[test]
    fn parses_every_field_of_the_documented_sample() {
        let reading = parse_qpigs(SAMPLE).expect("the captured frame must parse");
        assert_eq!(reading.grid_voltage, 0.0);
        assert_eq!(reading.grid_frequency, 0.0);
        assert_eq!(reading.output_voltage, 226.7);
        assert_eq!(reading.output_frequency, 50.0);
        assert_eq!(reading.output_apparent_power, 997);
        assert_eq!(reading.output_active_power, 825);
        assert_eq!(reading.output_load_percent, 12);
        assert_eq!(reading.bus_voltage, 429);
        assert_eq!(reading.battery_voltage, 54.20);
        assert_eq!(reading.battery_charging_current, 41);
        assert_eq!(reading.battery_capacity, 80);
        assert_eq!(reading.heat_sink_temperature, 62);
        assert_eq!(reading.pv1_current, 9.2);
        assert_eq!(reading.pv1_voltage, 196.4);
        assert_eq!(reading.battery_voltage_from_scc1, 0.0);
        assert_eq!(reading.battery_discharge_current, 0);
        assert_eq!(reading.eeprom_version, 0);
        assert_eq!(reading.pv1_charging_power, 1819);
    }

    /// `00010110`: b4 (load on), b2 (charging) and b1 (SCC charging) set, and per protocol.md's
    /// combination table `110` means charging from solar with no AC charge.
    #[test]
    fn device_status_1_maps_bits_left_to_right() {
        let reading = parse_qpigs(SAMPLE).unwrap();
        assert!(!reading.add_sbu_priority_version);
        assert!(!reading.configuration_changed);
        assert!(!reading.scc_firmware_updated);
        assert!(reading.load_on);
        assert!(!reading.battery_voltage_to_steady_while_charging);
        assert!(reading.charging);
        assert!(reading.charging_scc);
        assert!(!reading.charging_ac);
    }

    /// `010` -- not floating, switch on. b8 is read but not carried; see the struct comment.
    #[test]
    fn device_status_2_maps_the_two_fields_this_model_has() {
        let reading = parse_qpigs(SAMPLE).unwrap();
        assert!(!reading.float_charge);
        assert!(reading.switch_on);
    }

    /// Field 18 is documented in 10 mV steps, so the record must not carry the raw count.
    #[test]
    fn the_fan_on_offset_is_scaled_to_volts() {
        let mut payload = SAMPLE.to_vec();
        payload[91..93].copy_from_slice(b"57");
        assert_eq!(parse_qpigs(&payload).unwrap().battery_voltage_offset_fans_on, 0.57);
    }

    /// protocol.md's stated behaviour for a >9999 VA unit: fields 5 and 6 widen, every later
    /// offset shifts, and this parser must refuse rather than mis-read.
    #[test]
    fn a_widened_power_field_is_rejected_not_misparsed() {
        let mut widened = SAMPLE.to_vec();
        widened.insert(22, b'1');
        // Trimmed back to 106 on purpose: this must be caught by the offsets, not by the length
        // check that would already have rejected a 107-byte payload.
        widened.pop();
        assert_eq!(widened.len(), QPIGS_LEN);
        assert!(parse_qpigs(&widened).is_err());
    }

    #[test]
    fn a_payload_of_the_wrong_length_is_rejected() {
        assert!(parse_qpigs(&SAMPLE[..105]).is_err());
        assert!(parse_qpigs(&[SAMPLE, b" 1"].concat()).is_err());
    }

    /// The 122-byte payload protocol.md says a later firmware may send. Rejected loudly, which
    /// is the documented intent -- silently reading the first 106 bytes would be worse.
    #[test]
    fn the_longer_firmware_payload_is_rejected_until_someone_looks_at_it() {
        let extended = [SAMPLE, b" 0 01 0000 00.0"].concat();
        assert!(parse_qpigs(&extended).is_err());
    }

    #[test]
    fn parses_the_documented_qpigs2_sample() {
        let reading = parse_qpigs2(b"05.4 212.5 01156 ").unwrap();
        assert_eq!(
            reading,
            Qpigs2 { pv2_current: 5.4, pv2_voltage: 212.5, pv2_charging_power: 1156 }
        );
    }

    /// The 16-byte reading of the PDF. The device sends 17.
    #[test]
    fn qpigs2_without_its_trailing_space_is_rejected() {
        assert!(parse_qpigs2(b"05.4 212.5 01156").is_err());
    }

    #[test]
    fn parses_the_documented_qpiws_sample() {
        let payload = b"000001000000000001000000000000000000";
        let reading = parse_qpiws(payload).unwrap();
        assert_eq!(reading.asserted_count(), 2);
        assert_eq!(
            reading.asserted().collect::<Vec<_>>(),
            vec![(5, "line_fail"), (17, "eeprom_fault")]
        );
        assert_eq!(reading.raw, String::from_utf8_lossy(payload));
    }

    #[test]
    fn the_warning_table_is_the_documented_length_and_order() {
        assert_eq!(WARNING_FLAGS.len(), 36);
        assert_eq!(WARNING_FLAGS[INVERTER_FAULT_BIT], "inverter_fault");
        assert_eq!(WARNING_FLAGS[35], "unknown2");
    }

    #[test]
    fn qpiws_rejects_anything_that_is_not_a_bit() {
        assert!(parse_qpiws(b"00000200000000000000000000000000000").is_err());
        assert!(parse_qpiws(b"0000").is_err());
    }

    #[test]
    fn parses_every_documented_mode_letter() {
        let expected = [
            (b'P', "power_on"),
            (b'S', "standby"),
            (b'L', "line"),
            (b'B', "battery"),
            (b'F', "fault"),
            (b'D', "shutdown"),
            (b'C', "charge"),
            (b'Y', "bypass"),
            (b'E', "eco"),
        ];
        for (code, name) in expected {
            let reading = parse_qmod(&[code]).unwrap();
            assert_eq!(reading.mode.map(Mode::name), Some(name));
        }
    }

    /// A letter the table has no name for is still a fact about the unit.
    #[test]
    fn an_unknown_mode_letter_keeps_its_code() {
        let reading = parse_qmod(b"Z").unwrap();
        assert_eq!(reading.code, 'Z');
        assert!(reading.mode.is_none());
    }

    #[test]
    fn identity_payloads_are_kept_verbatim() {
        assert_eq!(parse_identity("QMN", b"MKS2-8000").unwrap(), "MKS2-8000");
        // The leading zero is significant, so nothing may normalise this to 44.
        assert_eq!(parse_identity("QGMN", b"044").unwrap(), "044");
        assert_eq!(parse_identity("QVFW", b"VERFW:00072.04").unwrap(), "VERFW:00072.04");
    }
}
