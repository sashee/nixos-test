//! `/sys/bus/usb/devices` name and value parsing.
//!
//! Two things make USB sysfs awkward enough to deserve its own parser module, and both are about
//! names rather than values.
//!
//! The first is that one flat directory holds three different kinds of thing: root hubs (`usb1`),
//! devices (`3-1`, `3-1.2`) and interfaces (`3-1:1.0`). Only the `:` tells an interface from a
//! device, so a collector that globbed the directory would emit `1-0:1.0` as a device.
//!
//! The second is that a port's directory name does not contain the path of the device that
//! attaches to it: `usb3-port1` hosts `3-1`, and `3-1-port2` hosts `3-1.2`. The two forms need
//! different rules, which is why the record carries the resolved device path instead of leaving
//! every consumer to rediscover the mapping.
//!
//! Values need converting too -- `bMaxPower` reads `"0mA"`, `version` has a leading space, and the
//! booleans disagree with each other (`early_stop` is `yes`/`no`, `authorized` is `1`/`0`). Each
//! gets a named parser here so the quirk is documented once rather than inlined at a call site.
//!
//! Everything is a pure `&str -> T`; walking `/sys` lives in `main.rs`.

/// What an entry in `/sys/bus/usb/devices` is.
#[derive(Debug, Clone, PartialEq)]
pub enum Entry {
    /// A device: a root hub (`usb1`) or anything downstream of one (`3-1`, `3-1.2`).
    Device,
    /// An interface of a device (`3-1:1.0`). Reported as the `interface` sub measurement, and the
    /// carried string is the owning device's path so the sub measurement can repeat it.
    Interface { device_path: String },
}

/// Classifies a `/sys/bus/usb/devices` entry by name alone.
///
/// The `:` is the only marker the kernel gives: interface directories are `<device>:<config>.<num>`
/// and nothing else contains a colon. Root hubs are `usbN` and are deliberately *not* a separate
/// variant -- they are real USB devices with descriptors, a `devnum` and a `maxchild`, and treating
/// them as ordinary devices is what makes the port records join up to something.
pub fn classify(name: &str) -> Option<Entry> {
    if name.is_empty() {
        return None;
    }
    match name.split_once(':') {
        Some((device, _)) if !device.is_empty() => {
            Some(Entry::Interface { device_path: device.to_owned() })
        }
        Some(_) => None,
        None => Some(Entry::Device),
    }
}

/// The directory name a device path actually has under `/sys/bus/usb/devices`.
///
/// A root hub is reachable by two names: its interface is `1-0:1.0`, implying a device at `1-0`,
/// but the directory is `usb1`. Nothing is symlinked at `1-0`, so a record that carried the implied
/// name would join to no device and any read from it would return null. Everything below a root hub
/// is already canonical.
pub fn canonical_device_path(raw: &str) -> String {
    match raw.split_once('-') {
        Some((bus, "0")) if !bus.is_empty() && bus.bytes().all(|b| b.is_ascii_digit()) => {
            format!("usb{bus}")
        }
        _ => raw.to_owned(),
    }
}

/// The device path a port hosts, from the port's directory name.
///
/// Two forms exist and they are not the same rule:
///
/// * a root hub's port is `usb<bus>-port<n>` and hosts `<bus>-<n>` -- `usb3-port1` -> `3-1`
/// * a downstream hub's port is `<hub path>-port<n>` and hosts `<hub path>.<n>` -- `3-1-port2` ->
///   `3-1.2`
///
/// The separator differs (`-` at the root, `.` below it) because that is how the kernel builds
/// device paths, and getting it wrong would produce a `path` that joins to no device at all.
pub fn port_device_path(port_name: &str) -> Option<String> {
    let (prefix, index) = port_name.rsplit_once("-port")?;
    if index.is_empty() || !index.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    match prefix.strip_prefix("usb") {
        // Root hub: the prefix is the bus number, joined with `-`.
        Some(bus) if !bus.is_empty() && bus.bytes().all(|b| b.is_ascii_digit()) => {
            Some(format!("{bus}-{index}"))
        }
        // Anything else is a downstream hub's own path, joined with `.`.
        _ if !prefix.is_empty() => Some(format!("{prefix}.{index}")),
        _ => None,
    }
}

/// `bMaxPower` is the declared draw with its unit glued on: `"0mA"`, `"100mA"`. The number alone is
/// what belongs in a `_ma` field.
pub fn parse_max_power_ma(raw: &str) -> Option<i64> {
    raw.trim().strip_suffix("mA")?.trim().parse().ok()
}

/// `version` reads `" 2.00"` -- the kernel pads it to a fixed width, so the leading space is always
/// there and would otherwise be stored as part of the value.
pub fn parse_usb_version(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

/// `speed` is in Mbit/s but is not always an integer: low-speed devices report `1.5`. Parsed as a
/// float so a mouse is not silently rejected or truncated to 1.
pub fn parse_speed_mbps(raw: &str) -> Option<f64> {
    raw.trim().parse().ok()
}

/// `early_stop` is the `yes`/`no` spelling.
pub fn parse_yes_no(raw: &str) -> Option<bool> {
    match raw.trim() {
        "yes" => Some(true),
        "no" => Some(false),
        _ => None,
    }
}

/// `authorized` and `disable` are the `1`/`0` spelling. Anything else is a kernel this producer does
/// not understand, and a null says so rather than guessing.
pub fn parse_zero_one(raw: &str) -> Option<bool> {
    match raw.trim() {
        "1" => Some(true),
        "0" => Some(false),
        _ => None,
    }
}

/// A hex descriptor byte as sysfs writes it: `"ff"`, `"09"`, `"03"`. Kept as the string the kernel
/// gave rather than parsed to an integer -- the values are looked up against USB class tables where
/// `03` and `3` are the same class but only one of them greps.
pub fn parse_hex_byte(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    (!trimmed.is_empty() && trimmed.bytes().all(|b| b.is_ascii_hexdigit())).then(|| trimmed.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn devices_and_interfaces_are_told_apart_by_the_colon() {
        assert_eq!(classify("usb1"), Some(Entry::Device));
        assert_eq!(classify("3-1"), Some(Entry::Device));
        assert_eq!(classify("3-1.2"), Some(Entry::Device));
        assert_eq!(
            classify("3-1:1.0"),
            Some(Entry::Interface { device_path: "3-1".to_owned() })
        );
        assert_eq!(
            classify("1-0:1.0"),
            Some(Entry::Interface { device_path: "1-0".to_owned() })
        );
        assert_eq!(
            classify("3-1.2:1.0"),
            Some(Entry::Interface { device_path: "3-1.2".to_owned() })
        );
    }

    #[test]
    fn a_nameless_or_malformed_entry_is_not_classified() {
        assert_eq!(classify(""), None);
        assert_eq!(classify(":1.0"), None);
    }

    #[test]
    fn a_root_hubs_implied_path_is_mapped_to_its_real_directory() {
        assert_eq!(canonical_device_path("1-0"), "usb1");
        assert_eq!(canonical_device_path("12-0"), "usb12");
        // Everything below a root hub is already the directory name.
        assert_eq!(canonical_device_path("3-1"), "3-1");
        assert_eq!(canonical_device_path("3-1.2"), "3-1.2");
        assert_eq!(canonical_device_path("usb1"), "usb1");
        // `-0` only means "root hub" after a bus number.
        assert_eq!(canonical_device_path("3-1.0"), "3-1.0");
    }

    #[test]
    fn a_root_hub_port_joins_with_a_dash() {
        assert_eq!(port_device_path("usb3-port1"), Some("3-1".to_owned()));
        assert_eq!(port_device_path("usb1-port2"), Some("1-2".to_owned()));
        assert_eq!(port_device_path("usb12-port10"), Some("12-10".to_owned()));
    }

    #[test]
    fn a_downstream_hub_port_joins_with_a_dot() {
        assert_eq!(port_device_path("3-1-port2"), Some("3-1.2".to_owned()));
        assert_eq!(port_device_path("3-1.4-port1"), Some("3-1.4.1".to_owned()));
    }

    #[test]
    fn a_name_that_is_not_a_port_is_rejected() {
        assert_eq!(port_device_path("usb3"), None);
        assert_eq!(port_device_path("3-1"), None);
        assert_eq!(port_device_path("usb3-portX"), None);
        assert_eq!(port_device_path("usb3-port"), None);
        assert_eq!(port_device_path("-port1"), None);
    }

    #[test]
    fn max_power_loses_its_unit() {
        assert_eq!(parse_max_power_ma("0mA"), Some(0));
        assert_eq!(parse_max_power_ma("100mA"), Some(100));
        assert_eq!(parse_max_power_ma(" 500mA\n"), Some(500));
        // Without the suffix it is not the field this parser is for.
        assert_eq!(parse_max_power_ma("100"), None);
    }

    #[test]
    fn usb_version_loses_the_kernels_padding() {
        assert_eq!(parse_usb_version(" 2.00"), Some("2.00".to_owned()));
        assert_eq!(parse_usb_version(" 3.20\n"), Some("3.20".to_owned()));
        assert_eq!(parse_usb_version("   "), None);
    }

    #[test]
    fn low_speed_keeps_its_fraction() {
        assert_eq!(parse_speed_mbps("480"), Some(480.0));
        assert_eq!(parse_speed_mbps("12"), Some(12.0));
        assert_eq!(parse_speed_mbps("1.5"), Some(1.5));
        assert_eq!(parse_speed_mbps("5000"), Some(5000.0));
        assert_eq!(parse_speed_mbps("unknown"), None);
    }

    #[test]
    fn the_two_boolean_spellings_do_not_accept_each_other() {
        assert_eq!(parse_yes_no("yes"), Some(true));
        assert_eq!(parse_yes_no("no"), Some(false));
        assert_eq!(parse_yes_no("1"), None);

        assert_eq!(parse_zero_one("1"), Some(true));
        assert_eq!(parse_zero_one("0"), Some(false));
        assert_eq!(parse_zero_one("yes"), None);
    }

    #[test]
    fn descriptor_bytes_keep_their_leading_zero() {
        assert_eq!(parse_hex_byte("ff"), Some("ff".to_owned()));
        assert_eq!(parse_hex_byte("09"), Some("09".to_owned()));
        assert_eq!(parse_hex_byte("00\n"), Some("00".to_owned()));
        assert_eq!(parse_hex_byte(""), None);
        assert_eq!(parse_hex_byte("zz"), None);
    }
}
