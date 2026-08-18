//! The `55 AA EB 90` framing: find frames in a byte stream, check their sum8, resynchronise.
//!
//! Everything here is pure, driven by bytes handed in from outside, so the awkward part of a
//! passive reader -- the stream is a mixture of the frames we want and RS485 traffic we do not,
//! with no request/response boundary to align on -- is testable without a serial port.
//!
//! See `spec/features/bms-monitoring/protocol.md` §2-§3. The shape that matters: the BMS emits one
//! 300-byte `0x02` realtime frame and one 300-byte `0x01` settings frame per ~6.7s cycle, with
//! ~181 bytes of Modbus-RTU records interleaved between them. Those records are *not* checked or
//! decoded -- they are skipped, because the only thing we need from them is to not mistake one for
//! a frame.

/// Frame prefix. The counter byte at offset 5 is always `0x00` on this cable, but it is
/// deliberately not part of the match: a firmware that started counting would then desynchronise
/// this reader rather than merely changing one reported byte.
pub const HEADER: [u8; 4] = [0x55, 0xAA, 0xEB, 0x90];

/// Every frame is exactly this long, both kinds. §3.
pub const FRAME_LEN: usize = 300;

/// Where the checksum sits, and therefore how many bytes it covers.
const CHECKSUM_OFFSET: usize = 299;

pub const REALTIME: u8 = 0x02;
pub const SETTINGS: u8 = 0x01;

/// The 8-bit sum of bytes 0..299. Not a CRC, despite what the feature spec calls it -- the
/// Modbus records on the same line use CRC16, the frames use this.
pub fn checksum(frame: &[u8]) -> u8 {
    frame[..CHECKSUM_OFFSET].iter().fold(0u8, |sum, byte| sum.wrapping_add(*byte))
}

/// A 300-byte frame whose checksum has been verified.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub code: u8,
    pub data: Vec<u8>,
}

impl Frame {
    pub fn is_realtime(&self) -> bool {
        self.code == REALTIME
    }

    pub fn is_settings(&self) -> bool {
        self.code == SETTINGS
    }
}

/// What one attempt to take a frame off the front of the buffer found.
#[derive(Debug, PartialEq, Eq)]
enum Step {
    /// A whole frame with a good checksum, and how many bytes of it to consume.
    Found(Frame, usize),
    /// Nothing frame-shaped at the front: consume this many bytes and try again. Ordinarily the
    /// interleaved Modbus traffic.
    Skip(usize),
    /// A whole frame at the front, and its checksum did not match. Distinct from `Skip` because it
    /// is the one worth alarming on, and the byte count alone could not tell it apart from the
    /// Modbus records -- both are "bytes that were not a frame".
    BadChecksum,
    /// Not enough bytes yet to decide. Wait for more.
    Incomplete,
}

/// Reassembles frames from arbitrary chunk boundaries, and counts what it threw away.
///
/// The counters are the only place a degraded line is ever visible: a cable dropping a third of
/// its frames to noise looks exactly like a healthy one from any single measurement, because the
/// next frame is along in under seven seconds.
#[derive(Debug, Default)]
pub struct FrameReader {
    buffer: Vec<u8>,
    pub frames_ok: u64,
    /// Frames that were whole, and whose checksum did not match. The feature spec's "check the
    /// CRC and discard the message on failure", counted rather than merely obeyed.
    pub frames_discarded: u64,
    /// Bytes stepped over while resynchronising. Mostly the Modbus records, which are expected and
    /// arrive at ~181 bytes per cycle; the number is here so "expected" stays checkable.
    pub bytes_skipped: u64,
    /// Every byte ever fed in. The only number that distinguishes a line with nothing on it from a
    /// line whose traffic all happened to be consumed -- which is what tells the inverter's silent
    /// port apart from a device that is pushing frames of the wrong kind.
    pub bytes_read: u64,
}

impl FrameReader {
    /// Add bytes as they arrive off the wire.
    pub fn feed(&mut self, chunk: &[u8]) {
        self.bytes_read += chunk.len() as u64;
        self.buffer.extend_from_slice(chunk);
    }

    /// How much is buffered. Only the tests need this -- a reader that grows without bound is the
    /// bug they exist to catch, and the running service has no decision to make about it.
    #[cfg(test)]
    pub fn buffered(&self) -> usize {
        self.buffer.len()
    }

    /// Take the next verified frame, if the buffer holds one.
    ///
    /// Drives [`Self::step`] until it either produces a frame or runs out of bytes to decide with,
    /// so a single call crosses however many Modbus records and bad frames lie in the way.
    pub fn next_frame(&mut self) -> Option<Frame> {
        loop {
            match Self::step(&self.buffer) {
                Step::Found(frame, consumed) => {
                    self.buffer.drain(..consumed);
                    self.frames_ok += 1;
                    return Some(frame);
                }
                Step::Skip(count) => {
                    self.bytes_skipped += count as u64;
                    self.buffer.drain(..count.min(self.buffer.len()));
                }
                Step::BadChecksum => {
                    self.frames_discarded += 1;
                    // One byte, not 300 -- see `step`.
                    self.bytes_skipped += 1;
                    self.buffer.drain(..1);
                }
                Step::Incomplete => return None,
            }
        }
    }

    /// One decision about the front of `buffer`. Pure, which is what makes the resynchronisation
    /// rules testable one case at a time.
    fn step(buffer: &[u8]) -> Step {
        let Some(start) = find_header(buffer) else {
            // No header anywhere. Keep the last few bytes: a header split across two reads would
            // otherwise be thrown away half at a time and never match.
            let keep = HEADER.len() - 1;
            return if buffer.len() > keep { Step::Skip(buffer.len() - keep) } else { Step::Incomplete };
        };
        if start > 0 {
            // Junk in front of a header: the interleaved Modbus records, or the tail of a frame
            // we gave up on.
            return Step::Skip(start);
        }
        if buffer.len() < FRAME_LEN {
            return Step::Incomplete;
        }

        let candidate = &buffer[..FRAME_LEN];
        if checksum(candidate) != candidate[CHECKSUM_OFFSET] {
            // Resynchronise past this header only, NOT past 300 bytes. The header bytes can occur
            // inside Modbus data, and a false positive that consumed a frame's worth of stream
            // would eat the real frame that followed it.
            return Step::BadChecksum;
        }

        Step::Found(
            Frame { code: candidate[4], data: candidate.to_vec() },
            FRAME_LEN,
        )
    }
}

fn find_header(buffer: &[u8]) -> Option<usize> {
    if buffer.len() < HEADER.len() {
        return None;
    }
    buffer.windows(HEADER.len()).position(|window| window == HEADER)
}

#[cfg(test)]
pub mod fixture {
    use super::*;

    /// A frame with a correct checksum, `data` padded or truncated to the wire length.
    pub fn frame(code: u8, data: &[u8]) -> Vec<u8> {
        let mut out = vec![0u8; FRAME_LEN];
        out[..HEADER.len()].copy_from_slice(&HEADER);
        out[4] = code;
        out[5] = 0;
        let body = data.len().min(FRAME_LEN - 7);
        out[6..6 + body].copy_from_slice(&data[..body]);
        out[CHECKSUM_OFFSET] = checksum(&out);
        out
    }

    /// The ~181 bytes of Modbus-RTU records the BMS interleaves, near enough for framing tests:
    /// what matters is that they are not frames and contain no header.
    pub fn modbus(address: u8) -> Vec<u8> {
        vec![address, 0x10, 0x16, 0x20, 0x00, 0x01, 0x05, 0x9A]
    }
}

#[cfg(test)]
mod tests {
    use super::fixture::{frame, modbus};
    use super::*;

    fn read_all(chunks: &[Vec<u8>]) -> (Vec<Frame>, FrameReader) {
        let mut reader = FrameReader::default();
        let mut frames = Vec::new();
        for chunk in chunks {
            reader.feed(chunk);
            while let Some(found) = reader.next_frame() {
                frames.push(found);
            }
        }
        (frames, reader)
    }

    #[test]
    fn the_checksum_is_the_8_bit_sum_of_everything_before_it() {
        let built = frame(REALTIME, &[1, 2, 3]);
        assert_eq!(built.len(), FRAME_LEN);
        assert_eq!(checksum(&built), built[CHECKSUM_OFFSET]);
        // Byte 299 is excluded from its own sum.
        let sum: u8 = built[..299].iter().fold(0u8, |a, b| a.wrapping_add(*b));
        assert_eq!(sum, built[299]);
    }

    #[test]
    fn reads_one_frame_of_each_kind() {
        let (frames, reader) =
            read_all(&[frame(REALTIME, &[0xAA]), frame(SETTINGS, &[0xBB])]);
        assert_eq!(frames.len(), 2);
        assert!(frames[0].is_realtime());
        assert!(frames[1].is_settings());
        assert_eq!(reader.frames_ok, 2);
        assert_eq!(reader.frames_discarded, 0);
    }

    /// The real cycle: a realtime frame, one short Modbus record, a settings frame, then the
    /// ~16-record auxiliary poll. Nothing but the two frames may come out.
    #[test]
    fn skips_the_interleaved_modbus_records() {
        let mut stream = Vec::new();
        stream.extend(frame(REALTIME, &[1]));
        stream.extend(modbus(0));
        stream.extend(frame(SETTINGS, &[2]));
        for address in 0..16u8 {
            stream.extend(modbus(address));
        }
        let (frames, reader) = read_all(&[stream]);
        assert_eq!(frames.len(), 2);
        assert_eq!(reader.frames_discarded, 0, "Modbus records are not failed frames");
        assert!(reader.bytes_skipped > 0, "the records must be counted as skipped bytes");
    }

    /// A frame arriving in arbitrarily small pieces is still one frame. QEMU and a real FTDI both
    /// hand over whatever is in the buffer, so byte-at-a-time is not a synthetic case.
    #[test]
    fn reassembles_a_frame_split_across_chunks() {
        let built = frame(REALTIME, &[0x42]);
        let chunks: Vec<Vec<u8>> = built.chunks(7).map(<[u8]>::to_vec).collect();
        assert!(chunks.len() > 1);
        let (frames, reader) = read_all(&chunks);
        assert_eq!(frames.len(), 1);
        assert_eq!(reader.frames_ok, 1);
    }

    /// Including the pathological split: the header itself cut in half. The reader must not
    /// discard the first two bytes while waiting for the rest.
    #[test]
    fn reassembles_a_frame_whose_header_is_split() {
        let built = frame(REALTIME, &[0x42]);
        let (head, tail) = built.split_at(2);
        let (frames, _) = read_all(&[head.to_vec(), tail.to_vec()]);
        assert_eq!(frames.len(), 1);
    }

    #[test]
    fn a_bad_checksum_is_discarded_and_counted() {
        let mut bad = frame(REALTIME, &[1]);
        bad[299] ^= 0xFF;
        let good = frame(SETTINGS, &[2]);
        let (frames, reader) = read_all(&[bad, good]);

        // The good frame after it still arrives: a bad checksum costs one frame, not the stream.
        assert_eq!(frames.len(), 1);
        assert!(frames[0].is_settings());
        assert_eq!(reader.frames_discarded, 1);
    }

    /// A flipped *payload* byte fails the sum just as a flipped checksum does -- the case that
    /// actually happens, since payload is 293 of the 300 bytes.
    #[test]
    fn a_flipped_payload_byte_fails_the_sum() {
        let mut bad = frame(REALTIME, &[1]);
        bad[100] ^= 0xFF;
        let (frames, reader) = read_all(&[bad]);
        assert!(frames.is_empty());
        assert_eq!(reader.frames_discarded, 1);
    }

    /// The resynchronisation rule that a 300-byte skip would break: a header sequence appearing
    /// inside other traffic must not swallow the genuine frame behind it.
    #[test]
    fn a_false_header_does_not_consume_the_frame_behind_it() {
        let mut stream = Vec::new();
        // A header, then nonsense -- not 300 valid bytes, so it cannot check out.
        stream.extend(HEADER);
        stream.extend([0x02, 0x00, 0xFF, 0xFF]);
        stream.extend(frame(REALTIME, &[0x99]));

        let (frames, _) = read_all(&[stream]);
        assert_eq!(frames.len(), 1, "the real frame behind the false header must be found");
        assert_eq!(frames[0].data[6], 0x99);
    }

    /// Two frames back to back with a false header planted inside the first one's payload.
    #[test]
    fn recovers_when_a_header_appears_inside_a_payload() {
        let mut payload = vec![0u8; 40];
        payload[10..14].copy_from_slice(&HEADER);
        let (frames, reader) = read_all(&[frame(REALTIME, &payload), frame(SETTINGS, &[7])]);
        assert_eq!(frames.len(), 2, "the embedded header must not desynchronise the reader");
        assert_eq!(reader.frames_discarded, 0);
    }

    /// The buffer must not grow without bound on a line that never produces a frame -- this
    /// process runs for weeks.
    #[test]
    fn a_stream_with_no_frames_does_not_accumulate() {
        let mut reader = FrameReader::default();
        for _ in 0..500 {
            reader.feed(&modbus(1));
            assert!(reader.next_frame().is_none());
        }
        assert!(reader.buffered() < FRAME_LEN, "buffered {} bytes", reader.buffered());
    }

    #[test]
    fn nothing_comes_out_of_a_partial_frame() {
        let built = frame(REALTIME, &[1]);
        let (frames, reader) = read_all(&[built[..FRAME_LEN - 1].to_vec()]);
        assert!(frames.is_empty());
        assert_eq!(reader.frames_discarded, 0, "an incomplete frame is not a failed one");
    }
}
