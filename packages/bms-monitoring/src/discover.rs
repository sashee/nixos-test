//! Finding the BMS among whatever USB serial adapters this host has.
//!
//! Split three ways on purpose: enumeration touches the filesystem, ordering is a pure function of
//! the enumeration, and probing is generic over [`Transport`] so both outcomes that matter -- "this
//! one is the BMS" and "this one is something else" -- are unit-testable.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::frame::{Frame, FrameReader};
use crate::port::{read_until, Transport};

/// One USB serial device: what to open, and two ways of naming it.
///
/// `/dev/ttyUSB<N>` is not an identity -- the numbers are handed out in enumeration order, so the
/// BMS is `ttyUSB0` on one boot and `ttyUSB1` on the next. Neither is `by-id`: it is built from the
/// USB descriptors, and a chip with no serial number descriptor yields a name derived from vendor
/// and product alone, so two adapters of the same serial-less model collide onto one symlink. This
/// fleet has exactly that adapter on the *inverter* (a CH340, `1a86:7523`, empty serial
/// descriptor), which is enough reason not to key on the directory at all.
///
/// So: enumerate the ttys, which exist per device by construction, and key on `by-path`, which
/// names the physical port and is unique whatever the chip says about itself. `by_id` is kept
/// because it is the name a human recognises in a log line -- it is reported, never matched on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub tty: PathBuf,
    /// The stable key: by-path link name, or the device's own name if udev made no link.
    pub path_id: String,
    pub by_id: Option<String>,
}

impl Candidate {
    /// How this device is described in a log line: both names when they differ.
    pub fn describe(&self) -> String {
        match &self.by_id {
            Some(by_id) => format!("{} ({})", self.path_id, by_id),
            None => self.path_id.clone(),
        }
    }
}

/// Every USB serial adapter present, in a deterministic order.
///
/// The three directories are arguments rather than constants so a test can point them at a fixture
/// tree.
pub fn enumerate(dev_dir: &Path, by_path_dir: &Path, by_id_dir: &Path) -> Vec<Candidate> {
    let Ok(entries) = std::fs::read_dir(dev_dir) else {
        return Vec::new();
    };
    let by_path = links_by_target(by_path_dir);
    let by_id = links_by_target(by_id_dir);

    let mut found: Vec<Candidate> = entries
        .filter_map(Result::ok)
        .filter(|entry| entry.file_name().to_str().is_some_and(|name| name.starts_with("ttyUSB")))
        .map(|entry| {
            let tty = entry.path();
            let key = target_key(&tty);
            Candidate {
                path_id: by_path
                    .get(&key)
                    .cloned()
                    .unwrap_or_else(|| tty.to_string_lossy().into_owned()),
                by_id: by_id.get(&key).cloned(),
                tty,
            }
        })
        .collect();
    // read_dir order is whatever the filesystem says; sorting first makes `order` below the only
    // thing that decides sequence, and makes its tests mean something.
    found.sort_by(|a, b| a.tty.cmp(&b.tty));
    found
}

/// Map of "device this link points at" -> link name, for one of the `/dev/serial` directories.
///
/// A device can have more than one link in the same directory: this fleet's Pi publishes both
/// `platform-xhci-hcd.0-usb-0:1:1.0-port0` and a `-usbv2-` twin for the same port. Taking the
/// lexicographically smallest collapses those to one, and is stable -- `usb` sorts before `usbv2`,
/// so the plain form wins and the key cannot flip between boots.
fn links_by_target(dir: &Path) -> std::collections::BTreeMap<PathBuf, String> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return std::collections::BTreeMap::new();
    };
    let mut links: std::collections::BTreeMap<PathBuf, String> = std::collections::BTreeMap::new();
    for entry in entries.filter_map(Result::ok) {
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        let Ok(target) = std::fs::canonicalize(entry.path()) else {
            continue;
        };
        links
            .entry(target_key(&target))
            .and_modify(|existing| {
                if name < *existing {
                    *existing = name.clone();
                }
            })
            .or_insert(name);
    }
    links
}

/// The by-id name udev currently has for `tty`, if any.
///
/// Re-read on every use rather than remembered from discovery: where two adapters collide on one
/// name, udev re-picks the owner on any event touching either of them -- the coldplug backlog at
/// boot, or a `udevadm trigger` from a rebuild -- and a name captured once can end up naming the
/// OTHER device, which is worse than reporting no name at all.
pub fn by_id_of(by_id_dir: &Path, tty: &Path) -> Option<String> {
    links_by_target(by_id_dir).remove(&target_key(tty))
}

/// What identifies a device across the three directories: the final path component.
fn target_key(path: &Path) -> PathBuf {
    PathBuf::from(path.file_name().unwrap_or(path.as_os_str()))
}

/// The order to try candidates in: shuffled.
///
/// The feature spec asks for random order, and unlike the inverter there is no remembered-device
/// hint to put first. There is no need for one: probing a port costs a listen with no write, so a
/// wrong guess is cheap and harmless, where the inverter's probe has to send `QID` at a device
/// whose command set is unknown.
///
/// Pure, with the seed passed in, so the shuffle is reproducible in a test and still varies in
/// production.
pub fn order(candidates: Vec<Candidate>, seed: u64) -> Vec<Candidate> {
    shuffle(candidates, seed)
}

/// Fisher-Yates over a xorshift64* stream. A whole rand crate for one shuffle of a list that is
/// almost always two elements long would be a dependency this producer has to keep in step.
fn shuffle(mut items: Vec<Candidate>, seed: u64) -> Vec<Candidate> {
    let mut state = seed | 1;
    let mut next = move || {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        state
    };
    for index in (1..items.len()).rev() {
        items.swap(index, (next() % (index as u64 + 1)) as usize);
    }
    items
}

#[derive(Debug, PartialEq, Eq)]
pub enum Probe {
    /// A `0x02` realtime frame arrived and passed its checksum. This is the BMS, and the frame is
    /// kept: it is a measurement, and throwing it away would mean waiting another cycle.
    Bms(Box<Frame>),
    /// Nothing at all on the line for the whole window. The inverter's port looks like this: it is
    /// half-duplex and never speaks unsolicited, so it says nothing until asked.
    Silent,
    /// Bytes arrived, but no valid realtime frame among them.
    NotABms(String),
}

/// Decide what one open port is, by listening only.
///
/// The feature spec's rule is "listens to it for 10 seconds => if there is no data => skip". This
/// requires more than that -- a valid, checksummed `0x02` frame -- which is strictly stronger and
/// still satisfies it. The difference matters on a bus with a third device: "any data at all"
/// would accept anything that chatters, and the whole point of probing is to not attach to the
/// wrong thing. Ten seconds is comfortably longer than the ~6.7s cycle, so a healthy BMS cannot
/// miss the window.
pub fn probe<T: Transport>(port: &mut T, window: Duration) -> std::io::Result<Probe> {
    let mut reader = FrameReader::default();
    let found = read_until(port, &mut reader, Instant::now() + window, Frame::is_realtime)?;

    Ok(match found {
        Some(frame) => Probe::Bms(Box::new(frame)),
        // Bytes read, not bytes skipped: a device pushing perfectly good frames of the wrong kind
        // skips nothing at all, and calling that "silent" would misreport it in the one log line
        // anybody reads when discovery fails.
        None if reader.bytes_read == 0 => Probe::Silent,
        None => Probe::NotABms(format!(
            "{} byte(s) seen, {} valid frame(s) of the wrong kind, {} failed the checksum, \
             no valid realtime frame",
            reader.bytes_read, reader.frames_ok, reader.frames_discarded
        )),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures::{cycle_bytes, modbus_record, realtime_bytes, settings_bytes};
    use crate::port::fake::FakePort;

    const WINDOW: Duration = Duration::from_millis(50);

    fn candidate(path_id: &str) -> Candidate {
        Candidate { tty: PathBuf::from("/dev/ttyUSB0"), path_id: path_id.to_owned(), by_id: None }
    }

    #[test]
    fn a_pushing_device_is_the_bms() {
        let mut port = FakePort::streaming(vec![cycle_bytes()]);
        let Probe::Bms(frame) = probe(&mut port, WINDOW).unwrap() else {
            panic!("the captured cycle must identify as the BMS");
        };
        assert!(frame.is_realtime());
    }

    /// The frame that identified the device is handed back rather than dropped: it is a
    /// measurement, and the next one is 6.7 seconds away.
    #[test]
    fn the_identifying_frame_is_kept() {
        let mut port = FakePort::streaming(vec![realtime_bytes()]);
        let Probe::Bms(frame) = probe(&mut port, WINDOW).unwrap() else {
            panic!("expected the BMS");
        };
        assert_eq!(frame.data, realtime_bytes());
    }

    /// The inverter's port. It never speaks unsolicited, so it is silent -- and this producer
    /// never writes, so it stays silent.
    #[test]
    fn a_port_that_says_nothing_is_not_the_bms() {
        let mut port = FakePort::silent();
        assert_eq!(probe(&mut port, WINDOW).unwrap(), Probe::Silent);
    }

    /// Stronger than the spec's "if there is no data": a device that chatters without ever
    /// producing a valid frame is rejected rather than attached to.
    #[test]
    fn a_chattering_device_that_is_not_the_bms_is_rejected() {
        let noise: Vec<Vec<u8>> = (0..20).map(modbus_record).collect();
        let mut port = FakePort::streaming(noise);
        match probe(&mut port, WINDOW).unwrap() {
            Probe::NotABms(reason) => assert!(reason.contains("byte(s) seen"), "{reason}"),
            other => panic!("expected rejection, got {other:?}"),
        }
    }

    /// A device pushing only settings frames is not enough: the realtime frame is the one this
    /// service is built around, and attaching without it would produce nothing for 24 hours.
    #[test]
    fn settings_frames_alone_do_not_identify_the_bms() {
        let mut port = FakePort::streaming(vec![settings_bytes(), settings_bytes()]);
        match probe(&mut port, WINDOW).unwrap() {
            // And it must not be reported as silence: every byte was a valid frame, so nothing
            // was skipped, which is exactly the case that made an earlier version say "said
            // nothing" about a device that was talking constantly.
            Probe::NotABms(reason) => {
                assert!(reason.contains("2 valid frame(s) of the wrong kind"), "{reason}")
            }
            other => panic!("expected rejection, got {other:?}"),
        }
    }

    /// Corrupt frames are not a BMS either -- but they are distinguishable from silence, which is
    /// what the log line needs.
    #[test]
    fn a_line_of_corrupt_frames_is_reported_as_such() {
        let mut bad = realtime_bytes();
        bad[299] ^= 0xFF;
        let mut port = FakePort::streaming(vec![bad]);
        match probe(&mut port, WINDOW).unwrap() {
            Probe::NotABms(reason) => {
                assert!(reason.contains("1 failed the checksum"), "{reason}")
            }
            other => panic!("expected rejection, got {other:?}"),
        }
    }

    #[test]
    fn an_io_error_while_probing_is_not_swallowed() {
        let mut port = FakePort::failing_after(Vec::new(), 0);
        assert!(probe(&mut port, WINDOW).is_err());
    }

    #[test]
    fn ordering_is_a_permutation_whatever_the_seed() {
        let candidates = vec![candidate("a"), candidate("b"), candidate("c")];
        for seed in [1u64, 2, 3, 99, 12345] {
            let ordered = order(candidates.clone(), seed);
            let mut names: Vec<String> = ordered.iter().map(|c| c.path_id.clone()).collect();
            names.sort();
            assert_eq!(names, vec!["a", "b", "c"], "seed {seed} lost or duplicated a candidate");
        }
    }

    /// Random order is the spec's requirement, and it is what stops two producers deadlocking on
    /// each other's port: a fixed order would have them contend the same way every sweep.
    #[test]
    fn different_seeds_can_produce_different_orders() {
        let candidates = vec![candidate("a"), candidate("b"), candidate("c"), candidate("d")];
        let orders: std::collections::BTreeSet<Vec<String>> = (0..40)
            .map(|seed| order(candidates.clone(), seed).iter().map(|c| c.path_id.clone()).collect())
            .collect();
        assert!(orders.len() > 1, "the shuffle never varied");
    }

    #[test]
    fn a_single_candidate_survives_the_shuffle() {
        let ordered = order(vec![candidate("only")], 7);
        assert_eq!(ordered.len(), 1);
        assert_eq!(ordered[0].path_id, "only");
        assert!(order(Vec::new(), 7).is_empty());
    }

    #[test]
    fn describe_names_both_when_there_is_a_by_id() {
        let mut with_name = candidate("port0");
        with_name.by_id = Some("usb-FTDI_FT232R_USB_UART_BG00Q7OM-if00-port0".to_owned());
        assert!(with_name.describe().contains("port0 (usb-FTDI"));
        assert_eq!(candidate("port0").describe(), "port0");
    }
}
