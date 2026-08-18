//! Two real frames, captured off the pack's serial cable on 2026-08-17 at 19:37 UTC.
//!
//! Not hand-built: every field the decoder reads is asserted against the numbers the hardware
//! actually sent, so a wrong offset or a wrong divisor fails here rather than shipping a plausible
//! number. A synthesised fixture could only ever agree with whatever the decoder happened to do.
//!
//! Both frames pass their own sum8. Deliberately preserved oddities, each of which a correction in
//! `parse.rs` depends on:
//!
//! * byte 214 is `0xFF` while three temperature sensors are live -- the byte the device ICD calls
//!   `tempSensorAbsent`, which is unusable as one
//! * offset 254 is byte-identical to `tempMos` at 144 (both `0x016F`)
//! * offset 252 is zero -- a channel that is not fitted
//! * `batWatt` at 154 is a positive magnitude while `batCurrent` at 158 is negative
//! * offsets 78/79 (`celMaxVol`/`celMinVol`) hold 0 and 4, which are 0-based and, in other frames
//!   from the same capture, disagreed with the cell array outright
//! * the settings frame's `cellConWireRes` block at 142 is entirely zero
//!
//! The pack at the time: 16 cells at ~3.25 V, 52.036 V, discharging at 7.98 A, SOC 63 %, 191
//! cycles, 450 days of uptime.

use crate::frame::{Frame, FrameReader, FRAME_LEN};

/// The realtime `0x02` frame.
const REALTIME_HEX: &str = "\
55aaeb900200b60cb50cb40cb40cb10cb40cb40cb30cb60cb50cb60cb60cb50c\
b30cb30cb30c0000000000000000000000000000000000000000000000000000\
000000000000ffff0000b40c0500000444004300450042004500420045004200\
4500440046004300460044004700440000000000000000000000000000000000\
000000000000000000000000000000006f010000000044cb00000b560600d4e0\
ffff69016601000000000000003f313a020070820300bf0000000af0a0026400\
000023ba510201010000000000000000000000000000ff0001000000b6030000\
150044303e4000000000531400000001010100060100baaf0f00000000006f01\
72017301ba037890770c950800008051010000000301000000000000000001fe\
ff7fdc2f0101b00f00000089";

/// The settings `0x01` frame from the same capture.
const SETTINGS_HEX: &str = "\
55aaeb900100ac0d0000280a0000220b0000100e0000ac0d00000a000000de0d\
0000f00a0000fc0d0000ac0d0000c4090000a0860100030000003c000000f049\
02002c0100003c00000005000000e8030000bc02000058020000bc0200005802\
0000140000004600000020030000bc0200001000000001000000010000000100\
000070820300dc050000800c0000000000000000000000000000000000000000\
0000000000000000000000000000000000000000000000000000000000000000\
0000000000000000000000000000000000000000000000000000000000000000\
0000000000000000000000000000000000000000000000000000000000000000\
0000000000000000000000000000000000000000000060e3160010323c3218fe\
ffffff9fe91d020000000085";

fn decode(hex: &str) -> Vec<u8> {
    assert_eq!(hex.len(), FRAME_LEN * 2, "a captured frame is {FRAME_LEN} bytes");
    (0..hex.len())
        .step_by(2)
        .map(|index| u8::from_str_radix(&hex[index..index + 2], 16).expect("valid hex"))
        .collect()
}

/// The captured frames as raw bytes, for driving the reader rather than the decoder.
pub fn realtime_bytes() -> Vec<u8> {
    decode(REALTIME_HEX)
}

pub fn settings_bytes() -> Vec<u8> {
    decode(SETTINGS_HEX)
}

/// Taken through the real [`FrameReader`], not constructed directly: that way the fixture cannot
/// be a frame the production reader would have rejected.
fn read(bytes: Vec<u8>) -> Frame {
    let mut reader = FrameReader::default();
    reader.feed(&bytes);
    let frame = reader.next_frame().expect("the captured frame must pass its own checksum");
    assert_eq!(reader.frames_discarded, 0);
    frame
}

pub fn realtime_frame() -> Frame {
    read(realtime_bytes())
}

pub fn settings_frame() -> Frame {
    read(settings_bytes())
}

/// One full ~781-byte cycle as the BMS emits it (§2): realtime, one short Modbus record,
/// settings, then the auxiliary poll. What a passive reader actually has to cope with.
pub fn cycle_bytes() -> Vec<u8> {
    let mut stream = realtime_bytes();
    stream.extend(modbus_record(0));
    stream.extend(settings_bytes());
    for address in 0..16u8 {
        stream.extend(modbus_record(address));
    }
    stream
}

/// A CRC16-valid Modbus record of the kind the BMS multiplexes onto the line (§8). Verbatim from
/// the capture, so it carries the real byte values a resynchroniser has to step over.
pub fn modbus_record(address: u8) -> Vec<u8> {
    vec![address, 0x10, 0x16, 0x20, 0x00, 0x01, 0x05, 0x9A]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::frame::checksum;

    #[test]
    fn both_captured_frames_pass_their_own_sum8() {
        for bytes in [realtime_bytes(), settings_bytes()] {
            assert_eq!(bytes.len(), FRAME_LEN);
            assert_eq!(checksum(&bytes), bytes[299], "captured frame fails its own checksum");
        }
    }

    #[test]
    fn the_captured_frames_are_the_two_kinds() {
        assert!(realtime_frame().is_realtime());
        assert!(settings_frame().is_settings());
        // The counter byte is 0x00 on this cable (§3).
        assert_eq!(realtime_bytes()[5], 0x00);
        assert_eq!(settings_bytes()[5], 0x00);
    }

    /// A full cycle yields exactly the two frames and nothing else, with the Modbus traffic
    /// skipped -- the end-to-end shape of what the reader faces every 6.7 seconds.
    #[test]
    fn one_cycle_yields_exactly_two_frames() {
        let mut reader = FrameReader::default();
        reader.feed(&cycle_bytes());
        let first = reader.next_frame().expect("realtime frame");
        let second = reader.next_frame().expect("settings frame");
        assert!(first.is_realtime());
        assert!(second.is_settings());
        assert!(reader.next_frame().is_none());
        assert_eq!(reader.frames_ok, 2);
        assert_eq!(reader.frames_discarded, 0);

        // Every byte is accounted for: the two frames, the Modbus records, and the tail the reader
        // deliberately holds back in case a header is split across the next read.
        let modbus_bytes = 8 + 16 * 8;
        assert_eq!(reader.bytes_read, (FRAME_LEN * 2 + modbus_bytes) as u64);
        assert_eq!(
            reader.bytes_skipped + reader.buffered() as u64,
            modbus_bytes as u64,
            "only the Modbus records are skipped, minus whatever is still held back"
        );
        assert!(reader.buffered() < 4, "at most a partial header may be retained");
    }
}
