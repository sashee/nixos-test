//! Finding the inverter among whatever USB serial adapters this host has.
//!
//! Split three ways on purpose: enumeration touches the filesystem, ordering is a pure function
//! of the enumeration, and probing is generic over [`Transport`] so both of the outcomes that
//! matter -- "this one is the BMS" and "this one answered QID" -- are unit-testable.

use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::parse::parse_identity;
use crate::port::Transport;
use crate::protocol::{parse_response, Command, Response};

/// One USB serial device: what to open, and two ways of naming it.
///
/// `/dev/ttyUSB<N>` is not an identity -- the numbers are handed out in enumeration order, so the
/// inverter is `ttyUSB0` on one boot and `ttyUSB1` on the next. But neither is `by-id`, which is
/// what this used to key on: it is built from the USB descriptors, and a chip with no serial
/// number descriptor yields a name derived from vendor and product alone. The inverter on this
/// fleet is a CH340 (`1a86:7523`), which reports no serial -- so a second serial-less adapter of
/// the same model would produce a byte-identical by-id name and the two would collide onto one
/// symlink. Enumerating that directory would then find one candidate for two devices.
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
/// `dev_dir` is `/dev` and the two link directories are under `/dev/serial`; all three are
/// arguments rather than constants so a test can point them at a fixture tree, the same way the
/// sibling producer takes `--hwmon-root`.
pub fn enumerate(dev_dir: &Path, by_path_dir: &Path, by_id_dir: &Path) -> Vec<Candidate> {
    let Ok(entries) = std::fs::read_dir(dev_dir) else {
        return Vec::new();
    };
    let by_path = links_by_target(by_path_dir);
    let by_id = links_by_target(by_id_dir);

    let mut found: Vec<Candidate> = entries
        .filter_map(Result::ok)
        .filter(|entry| {
            entry.file_name().to_str().is_some_and(|name| name.starts_with("ttyUSB"))
        })
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
/// lexicographically smallest is what collapses those to one, and it is stable -- `usb` sorts
/// before `usbv2`, so the plain form wins and the key does not flip between boots.
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
/// Re-read on every use rather than remembered from discovery: two adapters with the same
/// descriptors contest one by-id name, and udev re-arbitrates the winner on every event touching
/// either of them -- the coldplug backlog at boot, or a `udevadm trigger` from a rebuild, is
/// enough to move it. A name captured once at connect can therefore end up naming the OTHER
/// device, which is worse than reporting no name at all.
pub fn by_id_of(by_id_dir: &Path, tty: &Path) -> Option<String> {
    links_by_target(by_id_dir).remove(&target_key(tty))
}

/// What identifies a device across the three directories. The final path component, so a link
/// resolved to `/dev/ttyUSB0` matches the `/dev` entry of the same name.
fn target_key(path: &Path) -> PathBuf {
    PathBuf::from(path.file_name().unwrap_or(path.as_os_str()))
}

/// The order to try candidates in: the remembered one first, then the rest shuffled.
///
/// Pure, with the seed passed in, so the shuffle is reproducible in a test and still varies in
/// production. The remembered device is what makes the common case one probe instead of N, and
/// it is matched on `path_id` -- the physical port -- because that is the only name that is both
/// stable across reboots and unique per device. The cost is that moving the cable to another USB
/// socket invalidates the hint, which is one slow start, once.
pub fn order(candidates: Vec<Candidate>, remembered: Option<&str>, seed: u64) -> Vec<Candidate> {
    let (mut first, rest): (Vec<Candidate>, Vec<Candidate>) = candidates
        .into_iter()
        .partition(|candidate| Some(candidate.path_id.as_str()) == remembered);
    first.extend(shuffle(rest, seed));
    first
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
    /// Spoke without being asked. protocol.md's device never does.
    Chatty(usize),
    /// Answered `QID` with a well-formed frame: this is the inverter.
    Inverter(String),
    /// Said nothing, or said something that was not a valid response.
    NotAnInverter(String),
}

/// Decide what one open port is.
pub fn probe<T: Transport>(
    port: &mut T,
    listen_window: Duration,
    response_timeout: Duration,
) -> std::io::Result<Probe> {
    let unsolicited = port.listen(listen_window)?;
    if unsolicited > 0 {
        return Ok(Probe::Chatty(unsolicited));
    }

    port.write_request(&Command::Qid.request())?;
    let Some(frame) = port.read_frame(response_timeout)? else {
        return Ok(Probe::NotAnInverter("no response to QID".to_owned()));
    };

    match parse_response(&frame) {
        Ok(Response::Payload(payload)) => match parse_identity("QID", &payload) {
            Ok(serial) => Ok(Probe::Inverter(serial)),
            Err(reason) => Ok(Probe::NotAnInverter(reason)),
        },
        // A device that knows the framing well enough to NAK is almost certainly an inverter,
        // but not one this producer can identify -- and QID is in every model's command set.
        Ok(Response::Nak) => Ok(Probe::NotAnInverter("NAK to QID".to_owned())),
        Err(error) => Ok(Probe::NotAnInverter(error.to_string())),
    }
}

#[cfg(test)]
pub mod fake {
    use std::collections::VecDeque;
    use std::time::Duration;

    use crate::port::Transport;

    /// A scripted port: a queue of replies, plus optional unsolicited chatter.
    pub struct FakePort {
        pub chatter: usize,
        pub replies: VecDeque<Option<Vec<u8>>>,
        pub written: Vec<Vec<u8>>,
    }

    impl FakePort {
        pub fn answering(replies: Vec<Option<Vec<u8>>>) -> FakePort {
            FakePort { chatter: 0, replies: replies.into(), written: Vec::new() }
        }

        pub fn chattering(bytes: usize) -> FakePort {
            FakePort { chatter: bytes, replies: VecDeque::new(), written: Vec::new() }
        }
    }

    impl Transport for FakePort {
        fn write_request(&mut self, data: &[u8]) -> std::io::Result<()> {
            self.written.push(data.to_vec());
            Ok(())
        }

        fn read_frame(&mut self, _timeout: Duration) -> std::io::Result<Option<Vec<u8>>> {
            Ok(self.replies.pop_front().flatten())
        }

        fn listen(&mut self, _window: Duration) -> std::io::Result<usize> {
            Ok(self.chatter)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::fake::FakePort;
    use super::*;
    use crate::protocol::build_response;

    fn candidate(path_id: &str) -> Candidate {
        Candidate {
            tty: PathBuf::from("/dev/ttyUSB0"),
            path_id: path_id.to_owned(),
            by_id: None,
        }
    }

    fn names(candidates: &[Candidate]) -> Vec<String> {
        candidates.iter().map(|c| c.path_id.clone()).collect()
    }

    const WINDOW: Duration = Duration::from_millis(1);

    #[test]
    fn the_remembered_device_is_tried_first_whatever_the_seed() {
        let all = vec![candidate("port-a"), candidate("port-b"), candidate("port-c")];
        for seed in 0..32u64 {
            let ordered = order(all.clone(), Some("port-c"), seed);
            assert_eq!(ordered[0].path_id, "port-c", "seed {seed}");
            assert_eq!(ordered.len(), 3);
        }
    }

    /// A remembered device that has been unplugged must not stop the others being tried.
    #[test]
    fn a_remembered_device_that_is_gone_is_simply_absent() {
        let all = vec![candidate("port-a"), candidate("port-b")];
        let ordered = order(all, Some("port-vanished"), 7);
        assert_eq!(ordered.len(), 2);
        assert_eq!(names(&ordered).into_iter().collect::<std::collections::BTreeSet<_>>().len(), 2);
    }

    #[test]
    fn every_candidate_is_tried_exactly_once() {
        let all: Vec<Candidate> =
            (0..6).map(|n| candidate(&format!("port-{n}"))).collect();
        for seed in 0..64u64 {
            let ordered = order(all.clone(), None, seed);
            let mut got = names(&ordered);
            got.sort();
            assert_eq!(got, names(&all), "seed {seed} lost or duplicated a candidate");
        }
    }

    /// The spec asks for a random order. If the seed never changed the answer, the remembered
    /// device would be the only thing keeping this from always probing the BMS first.
    #[test]
    fn the_order_actually_varies_with_the_seed() {
        let all: Vec<Candidate> = (0..4).map(|n| candidate(&format!("port-{n}"))).collect();
        let orders: std::collections::BTreeSet<Vec<String>> =
            (0..64u64).map(|seed| names(&order(all.clone(), None, seed))).collect();
        assert!(orders.len() > 1, "the shuffle produced one order for 64 seeds");
    }

    #[test]
    fn a_device_that_talks_unprompted_is_not_probed_at_all() {
        let mut port = FakePort::chattering(12);
        assert_eq!(probe(&mut port, WINDOW, WINDOW).unwrap(), Probe::Chatty(12));
        assert!(port.written.is_empty(), "the BMS must not be written to");
    }

    #[test]
    fn a_valid_qid_response_identifies_the_inverter() {
        let mut port = FakePort::answering(vec![Some(build_response(b"92932210103714"))]);
        assert_eq!(
            probe(&mut port, WINDOW, WINDOW).unwrap(),
            Probe::Inverter("92932210103714".to_owned())
        );
        assert_eq!(port.written, vec![Command::Qid.request()]);
    }

    #[test]
    fn silence_and_noise_are_both_just_not_the_inverter() {
        let mut silent = FakePort::answering(vec![None]);
        assert!(matches!(probe(&mut silent, WINDOW, WINDOW).unwrap(), Probe::NotAnInverter(_)));

        let mut noisy = FakePort::answering(vec![Some(b"\x01\x02\x03\x0D".to_vec())]);
        assert!(matches!(probe(&mut noisy, WINDOW, WINDOW).unwrap(), Probe::NotAnInverter(_)));

        let mut corrupt = {
            let mut frame = build_response(b"92932210103714");
            frame[3] ^= 0xFF;
            FakePort::answering(vec![Some(frame)])
        };
        assert!(matches!(probe(&mut corrupt, WINDOW, WINDOW).unwrap(), Probe::NotAnInverter(_)));
    }

    // -----------------------------------------------------------------------------------------
    // Enumeration, against a fixture tree of real symlinks. The whole point of the change these
    // exercise is what udev's naming does to a directory listing, so a mocked filesystem would
    // test the mock.

    struct Tree {
        root: PathBuf,
    }

    impl Tree {
        fn new(tag: &str) -> Tree {
            let root = std::env::temp_dir()
                .join(format!("inverter-monitoring-{}-{tag}", std::process::id()));
            let _ = std::fs::remove_dir_all(&root);
            for dir in ["dev", "dev/serial/by-path", "dev/serial/by-id"] {
                std::fs::create_dir_all(root.join(dir)).expect("fixture tree");
            }
            Tree { root }
        }

        /// A tty plus whichever links udev would have made for it.
        fn device(&self, tty: &str, by_path: &[&str], by_id: Option<&str>) -> &Tree {
            std::fs::write(self.root.join("dev").join(tty), b"").expect("fixture tty");
            for name in by_path {
                std::os::unix::fs::symlink(
                    self.root.join("dev").join(tty),
                    self.root.join("dev/serial/by-path").join(name),
                )
                .expect("fixture by-path link");
            }
            if let Some(name) = by_id {
                // `symlink` fails on a name that already exists, which is exactly what udev
                // faces with two colliding by-id names -- one link survives, and that is the
                // situation these tests are about.
                let _ = std::os::unix::fs::symlink(
                    self.root.join("dev").join(tty),
                    self.root.join("dev/serial/by-id").join(name),
                );
            }
            self
        }

        fn enumerate(&self) -> Vec<Candidate> {
            enumerate(
                &self.root.join("dev"),
                &self.root.join("dev/serial/by-path"),
                &self.root.join("dev/serial/by-id"),
            )
        }
    }

    impl Drop for Tree {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    /// The bug that motivated keying on by-path. Two CH340-class adapters report no serial
    /// number, so udev derives the same by-id name for both and only one link survives.
    /// Enumerating that directory finds one device; enumerating the ttys finds two.
    #[test]
    fn two_adapters_sharing_a_by_id_name_are_still_two_candidates() {
        let tree = Tree::new("collision");
        tree.device("ttyUSB0", &["pci-usb-0:1:1.0-port0"], Some("usb-1a86_USB2.0-Ser_-if00-port0"))
            .device("ttyUSB1", &["pci-usb-0:2:1.0-port0"], Some("usb-1a86_USB2.0-Ser_-if00-port0"));

        let found = tree.enumerate();
        assert_eq!(found.len(), 2, "a colliding by-id name must not hide a device: {found:?}");
        assert_eq!(
            found.iter().map(|c| c.path_id.as_str()).collect::<Vec<_>>(),
            vec!["pci-usb-0:1:1.0-port0", "pci-usb-0:2:1.0-port0"],
            "each device keeps its own physical-port key"
        );
        // Only one of them could keep the shared by-id link, and that is fine: it is reported,
        // never matched on.
        assert_eq!(found.iter().filter(|c| c.by_id.is_some()).count(), 1);
    }

    /// The contested link moves, and the reported name has to move with it.
    ///
    /// udev re-arbitrates a symlink that two devices claim on every event touching either of
    /// them, so the winner at discovery is not the winner forever. A producer that remembered
    /// the name from discovery would keep publishing a name that now resolves to the adapter
    /// next to its own -- which is what a CI run caught, in both directions on two attempts.
    #[test]
    fn a_by_id_name_that_changes_owner_is_reported_against_the_new_one() {
        const SHARED: &str = "usb-1a86_USB2.0-Ser_-if00-port0";
        let tree = Tree::new("moving-link");
        tree.device("ttyUSB0", &["pci-usb-0:1:1.0-port0"], Some(SHARED))
            .device("ttyUSB1", &["pci-usb-0:2:1.0-port0"], Some(SHARED));

        let by_id_dir = tree.root.join("dev/serial/by-id");
        let tty = |name: &str| tree.root.join("dev").join(name);
        // ttyUSB0 was written first, so it holds the link; ttyUSB1's `symlink` lost the race.
        assert_eq!(by_id_of(&by_id_dir, &tty("ttyUSB0")), Some(SHARED.to_owned()));
        assert_eq!(by_id_of(&by_id_dir, &tty("ttyUSB1")), None);

        // What udev does when it picks the other claimant.
        std::fs::remove_file(by_id_dir.join(SHARED)).expect("fixture unlink");
        std::os::unix::fs::symlink(tty("ttyUSB1"), by_id_dir.join(SHARED)).expect("fixture relink");
        assert_eq!(by_id_of(&by_id_dir, &tty("ttyUSB0")), None);
        assert_eq!(by_id_of(&by_id_dir, &tty("ttyUSB1")), Some(SHARED.to_owned()));
    }

    /// The real Pi publishes both `...-usb-...` and `...-usbv2-...` for one port.
    #[test]
    fn the_usbv2_twin_does_not_become_a_second_candidate() {
        let tree = Tree::new("usbv2");
        tree.device(
            "ttyUSB0",
            &[
                "platform-xhci-hcd.0-usb-0:1:1.0-port0",
                "platform-xhci-hcd.0-usbv2-0:1:1.0-port0",
            ],
            Some("usb-1a86_USB2.0-Ser_-if00-port0"),
        );

        let found = tree.enumerate();
        assert_eq!(found.len(), 1);
        // The plain form, deterministically: `usb` sorts before `usbv2`, so the key cannot flip
        // between boots.
        assert_eq!(found[0].path_id, "platform-xhci-hcd.0-usb-0:1:1.0-port0");
    }

    /// An adapter udev made no by-path link for is still usable; it just gets a weaker key.
    #[test]
    fn a_device_with_no_links_falls_back_to_its_own_name() {
        let tree = Tree::new("nolinks");
        tree.device("ttyUSB3", &[], None);

        let found = tree.enumerate();
        assert_eq!(found.len(), 1);
        assert!(found[0].path_id.ends_with("/dev/ttyUSB3"), "{}", found[0].path_id);
        assert_eq!(found[0].by_id, None);
    }

    /// The FTDI half of this fleet's pair: a real serial number, so its by-id name is its own.
    #[test]
    fn both_names_are_reported_when_udev_could_make_them() {
        let tree = Tree::new("named");
        tree.device(
            "ttyUSB1",
            &["platform-xhci-hcd.1-usb-0:1:1.0-port0"],
            Some("usb-FTDI_FT232R_USB_UART_BG00Q7OM-if00-port0"),
        );

        let found = tree.enumerate();
        assert_eq!(found[0].by_id.as_deref(), Some("usb-FTDI_FT232R_USB_UART_BG00Q7OM-if00-port0"));
        assert!(found[0].describe().contains("BG00Q7OM"), "{}", found[0].describe());
        assert!(found[0].describe().contains("platform-xhci"), "{}", found[0].describe());
    }

    /// Only USB serial adapters. A guest with a virtio console has plenty of other ttys.
    #[test]
    fn other_ttys_are_not_candidates() {
        let tree = Tree::new("otherttys");
        tree.device("ttyUSB0", &["port0"], None);
        for other in ["ttyAMA0", "ttyS0", "ttyACM0", "null"] {
            std::fs::write(tree.root.join("dev").join(other), b"").expect("fixture tty");
        }

        let found = tree.enumerate();
        assert_eq!(found.len(), 1);
        assert!(found[0].tty.ends_with("ttyUSB0"));
    }

    #[test]
    fn enumerate_ignores_directories_that_do_not_exist() {
        assert!(enumerate(
            Path::new("/nonexistent/dev"),
            Path::new("/nonexistent/serial/by-path"),
            Path::new("/nonexistent/serial/by-id"),
        )
        .is_empty());
    }
}
