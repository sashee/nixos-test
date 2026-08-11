//! Commands and response framing. Pure: bytes in, bytes or an error out.

use crate::crc::frame_crc;

/// The nine commands this producer sends, per protocol.md.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Command {
    Qid,
    Qvfw,
    Qvfw3,
    Qmn,
    Qgmn,
    Qmod,
    Qpigs,
    Qpigs2,
    Qpiws,
}

/// The five identity commands, read once on connect and re-read on the static refresh.
pub const STATIC_COMMANDS: [Command; 5] =
    [Command::Qid, Command::Qvfw, Command::Qvfw3, Command::Qmn, Command::Qgmn];

/// The four polled commands.
pub const LIVE_COMMANDS: [Command; 4] =
    [Command::Qmod, Command::Qpigs, Command::Qpigs2, Command::Qpiws];

impl Command {
    pub fn text(self) -> &'static str {
        match self {
            Command::Qid => "QID",
            Command::Qvfw => "QVFW",
            Command::Qvfw3 => "QVFW3",
            Command::Qmn => "QMN",
            Command::Qgmn => "QGMN",
            Command::Qmod => "QMOD",
            Command::Qpigs => "QPIGS",
            Command::Qpigs2 => "QPIGS2",
            Command::Qpiws => "QPIWS",
        }
    }

    /// `<ASCII command><CRC hi><CRC lo><CR>`.
    ///
    /// Derived rather than table-driven. protocol.md precomputes the same nine frames and
    /// `crc::tests` checks this against that table, so the constant and the derivation cannot
    /// disagree without a test failing.
    pub fn request(self) -> Vec<u8> {
        let text = self.text().as_bytes();
        let crc = frame_crc(text);
        [text, &crc, &[CR]].concat()
    }
}

pub const CR: u8 = 0x0D;
const LEADING: u8 = b'(';

/// What came back for one command.
#[derive(Debug, PartialEq, Eq)]
pub enum Response {
    Payload(Vec<u8>),
    /// `(NAK<CRC><CR>` -- a well-formed frame saying the unit does not implement the command.
    ///
    /// Not an error: `QPIGS2` and `QVFW3` are absent on plenty of models in this family, and a
    /// producer that treated a NAK as a fault would restart-loop forever on hardware that is
    /// working exactly as designed.
    Nak,
}

#[derive(Debug, PartialEq, Eq)]
pub enum FrameError {
    /// Shorter than `(` + CRC + CR, so there is nothing to check a CRC over.
    TooShort(usize),
    NotAResponse(u8),
    Unterminated,
    Crc { computed: [u8; 2], received: [u8; 2] },
}

impl std::fmt::Display for FrameError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FrameError::TooShort(len) => write!(f, "frame of {len} byte(s) is too short"),
            FrameError::NotAResponse(byte) => {
                write!(f, "frame starts with {byte:#04x}, not '('")
            }
            FrameError::Unterminated => write!(f, "frame does not end with <CR>"),
            FrameError::Crc { computed, received } => write!(
                f,
                "CRC mismatch: computed {:02X} {:02X}, received {:02X} {:02X}",
                computed[0], computed[1], received[0], received[1]
            ),
        }
    }
}

/// Verify one whole frame, `(` through `<CR>` inclusive, and return its payload.
///
/// The CRC covers `frame[0 .. -3]` -- the leading `(` included, the `<CR>` excluded.
pub fn parse_response(frame: &[u8]) -> Result<Response, FrameError> {
    if frame.len() < 4 {
        return Err(FrameError::TooShort(frame.len()));
    }
    if frame[0] != LEADING {
        return Err(FrameError::NotAResponse(frame[0]));
    }
    if *frame.last().expect("length checked above") != CR {
        return Err(FrameError::Unterminated);
    }

    let covered = &frame[..frame.len() - 3];
    let received = [frame[frame.len() - 3], frame[frame.len() - 2]];
    let computed = frame_crc(covered);
    if computed != received {
        return Err(FrameError::Crc { computed, received });
    }

    let payload = &frame[1..frame.len() - 3];
    if payload == b"NAK" {
        return Ok(Response::Nak);
    }
    Ok(Response::Payload(payload.to_vec()))
}

/// Build a well-formed response frame. Only used by tests here, but it is the same function the
/// VM test's simulator implements in Python, so keeping it next to the parser keeps the two
/// readings of the framing rule side by side.
#[cfg(test)]
pub fn build_response(payload: &[u8]) -> Vec<u8> {
    let body = [&[LEADING][..], payload].concat();
    let crc = frame_crc(&body);
    [body.as_slice(), &crc, &[CR]].concat()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_frames_match_the_documented_hex() {
        assert_eq!(Command::Qid.request(), vec![0x51, 0x49, 0x44, 0xD6, 0xEA, 0x0D]);
        assert_eq!(Command::Qmn.request(), vec![0x51, 0x4D, 0x4E, 0xBB, 0x64, 0x0D]);
        assert_eq!(
            Command::Qpigs2.request(),
            vec![0x51, 0x50, 0x49, 0x47, 0x53, 0x32, 0x68, 0x2D, 0x0D]
        );
    }

    /// The literal capture from protocol.md, byte for byte.
    #[test]
    fn accepts_a_captured_qid_response() {
        let frame = b"(92932210103714\xCE\xAE\x0D";
        assert_eq!(parse_response(frame), Ok(Response::Payload(b"92932210103714".to_vec())));
    }

    /// The QPIGS2 capture, whose trailing space is inside the CRC. A parser that trimmed the
    /// payload before checking would reject a frame the device sent correctly.
    #[test]
    fn the_qpigs2_trailing_space_is_part_of_the_frame() {
        let frame = b"(05.4 212.5 01156 \x45\xE4\x0D";
        let Ok(Response::Payload(payload)) = parse_response(frame) else {
            panic!("captured frame should verify");
        };
        assert_eq!(payload.len(), 17);
        assert_eq!(payload.last(), Some(&b' '));
    }

    #[test]
    fn a_single_flipped_bit_is_rejected() {
        let mut frame = build_response(b"92932210103714");
        frame[5] ^= 0x01;
        assert!(matches!(parse_response(&frame), Err(FrameError::Crc { .. })));
    }

    /// A truncated read must not be mistaken for a short payload that happens to verify.
    #[test]
    fn malformed_frames_are_named_not_guessed() {
        assert_eq!(parse_response(b""), Err(FrameError::TooShort(0)));
        assert_eq!(parse_response(b"(\x0D"), Err(FrameError::TooShort(2)));
        assert_eq!(parse_response(b"X92\xCE\xAE\x0D"), Err(FrameError::NotAResponse(b'X')));
        assert_eq!(parse_response(b"(92\xCE\xAE"), Err(FrameError::Unterminated));
    }

    #[test]
    fn nak_is_a_valid_frame_not_a_fault() {
        assert_eq!(parse_response(&build_response(b"NAK")), Ok(Response::Nak));
    }

    #[test]
    fn round_trips_every_payload_length_the_protocol_uses() {
        for length in [1usize, 3, 9, 14, 17, 36, 106] {
            let payload = vec![b'7'; length];
            let frame = build_response(&payload);
            assert_eq!(frame.len(), length + 4, "frame length for payload of {length}");
            assert_eq!(parse_response(&frame), Ok(Response::Payload(payload)));
        }
    }
}
