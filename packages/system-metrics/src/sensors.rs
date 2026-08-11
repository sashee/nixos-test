//! hwmon filename parsing.
//!
//! The sweep is generic on purpose: the Pi exposes `cpu_thermal`, `rp1_adc`, `pwmfan` and
//! `rpi_volt`, while a laptop exposes `k10temp`, `nvme`, `amdgpu` and `mt7921_phy0` -- and
//! neither set is knowable from a path. Hardcoding either would produce a collector that reports
//! nothing on the other machine, so what is hardcoded instead is the *shape* of an hwmon
//! attribute name, which the kernel's hwmon interface does define.
//!
//! Only `<prefix><num>_input` and the `_alarm` forms are read. "Every file in the directory" was
//! considered and rejected: it sweeps in `uevent` (a multi-line blob), `name` (already an
//! attribute), and driver-specific extras like the Pi's `in1_raw` ADC counts that carry no unit.
//!
//! Everything here is a pure `&str -> T`; walking `/sys` lives in `main.rs`.

/// What a matched attribute file measures, and how its value should be named in the body.
#[derive(Debug, Clone, PartialEq)]
pub enum Reading {
    /// A `<prefix><num>_input` file. `body_key` carries the unit, because hwmon's units are
    /// per-prefix (millidegrees, millivolts, RPM, microwatts...) and a bare `value` would leave
    /// every consumer to rediscover which is which.
    Input { body_key: &'static str },
    /// A `<prefix><num>_alarm` or `<prefix><num>_<threshold>_alarm` file. `threshold` is `None`
    /// for the plain form, which is what the laptop's `nvme temp1_alarm` uses while the Pi's
    /// undervoltage flag is `rpi_volt in0_lcrit_alarm`.
    Alarm { threshold: Option<String> },
}

/// One hwmon attribute file worth reporting.
#[derive(Debug, Clone, PartialEq)]
pub struct SensorFile {
    /// `temp1`, `in0`, `fan1` -- the attribute's own name, minus the suffix.
    pub sensor: String,
    /// The record's `kind` attribute: the prefix for an input, `alarm` for an alarm.
    pub kind: String,
    pub reading: Reading,
}

/// Body key per prefix. Values stay in the kernel's own units and say so in the key rather than
/// being converted: they are integers as read, so nothing is lost to a float conversion, and a
/// key that names its unit cannot be misread.
fn body_key(prefix: &str) -> Option<&'static str> {
    Some(match prefix {
        "temp" => "milli_celsius",
        "fan" => "rpm",
        "in" => "milli_volts",
        "curr" => "milli_amps",
        "power" => "micro_watts",
        "energy" => "micro_joules",
        "humidity" => "milli_percent",
        _ => return None,
    })
}

/// Splits `temp1` into `("temp", "1")`, rejecting anything that is not a known prefix followed by
/// digits. The digits are not parsed into a number: they are only ever echoed back as part of the
/// `sensor` attribute, and a chip that numbered an attribute oddly should be reported as it is.
fn split_prefix(base: &str) -> Option<&str> {
    let digits_at = base.find(|c: char| c.is_ascii_digit())?;
    let (prefix, num) = base.split_at(digits_at);
    if num.is_empty() || !num.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    body_key(prefix)?;
    Some(prefix)
}

/// Recognises the attribute files this producer reports, and returns `None` for everything else
/// in an hwmon directory.
pub fn parse_sensor_filename(name: &str) -> Option<SensorFile> {
    if let Some(base) = name.strip_suffix("_input") {
        let prefix = split_prefix(base)?;
        return Some(SensorFile {
            sensor: base.to_owned(),
            kind: prefix.to_owned(),
            reading: Reading::Input { body_key: body_key(prefix)? },
        });
    }

    let rest = name.strip_suffix("_alarm")?;
    // `in0_lcrit_alarm` -> base `in0`, threshold `lcrit`; `temp1_alarm` -> base `temp1`, none.
    // Split at the LAST underscore so a threshold is never mistaken for part of the base.
    let (base, threshold) = match rest.rsplit_once('_') {
        Some((base, threshold)) => (base, Some(threshold.to_owned())),
        None => (rest, None),
    };
    split_prefix(base)?;
    Some(SensorFile {
        sensor: base.to_owned(),
        kind: "alarm".to_owned(),
        reading: Reading::Alarm { threshold },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(name: &str) -> Option<(String, String, &'static str)> {
        match parse_sensor_filename(name)? {
            SensorFile { sensor, kind, reading: Reading::Input { body_key } } => {
                Some((sensor, kind, body_key))
            }
            _ => None,
        }
    }

    fn alarm(name: &str) -> Option<(String, Option<String>)> {
        match parse_sensor_filename(name)? {
            SensorFile { sensor, kind, reading: Reading::Alarm { threshold } } => {
                assert_eq!(kind, "alarm");
                Some((sensor, threshold))
            }
            _ => None,
        }
    }

    #[test]
    fn an_input_carries_its_unit_in_the_body_key() {
        assert_eq!(input("temp1_input"), Some(("temp1".into(), "temp".into(), "milli_celsius")));
        assert_eq!(input("fan1_input"), Some(("fan1".into(), "fan".into(), "rpm")));
        assert_eq!(input("in0_input"), Some(("in0".into(), "in".into(), "milli_volts")));
        assert_eq!(input("power1_input"), Some(("power1".into(), "power".into(), "micro_watts")));
    }

    /// The Pi's undervoltage flag and the laptop's NVMe over-temperature flag are both alarms,
    /// but only one of them names a threshold.
    #[test]
    fn both_alarm_spellings_resolve_to_the_same_sensor_shape() {
        assert_eq!(alarm("in0_lcrit_alarm"), Some(("in0".into(), Some("lcrit".into()))));
        assert_eq!(alarm("temp1_alarm"), Some(("temp1".into(), None)));
        assert_eq!(alarm("temp1_crit_alarm"), Some(("temp1".into(), Some("crit".into()))));
        assert_eq!(alarm("temp1_max_alarm"), Some(("temp1".into(), Some("max".into()))));
    }

    /// The files that share a directory with the ones above and must not be swept in: the Pi's
    /// `rp1_adc` alone contributes five `_raw` counts plus `uevent` and `name`.
    #[test]
    fn everything_else_in_an_hwmon_directory_is_ignored() {
        for name in [
            "name",
            "uevent",
            "in1_raw",
            "temp1_raw",
            "temp1_label",
            "pwm1",
            "pwm1_enable",
            "mem_used_max",
            "temp1_max",
            "device",
        ] {
            assert_eq!(parse_sensor_filename(name), None, "{name} should not be reported");
        }
    }

    /// hwmon defines the prefixes; anything else has no unit this producer could name, so it is
    /// skipped rather than reported as a bare number.
    #[test]
    fn an_unknown_prefix_is_not_reported() {
        assert_eq!(parse_sensor_filename("intrusion0_alarm"), None);
        assert_eq!(parse_sensor_filename("freq1_input"), None);
        assert_eq!(parse_sensor_filename("_input"), None);
        assert_eq!(parse_sensor_filename("temp_input"), None);
    }
}
