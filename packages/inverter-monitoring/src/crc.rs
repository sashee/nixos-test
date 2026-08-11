//! CRC-16/XMODEM with the Voltronic framing-byte substitution.
//!
//! Pure: the whole module is `&[u8] -> u16`, which is what lets every frame in
//! `spec/features/inverter-monitoring/protocol.md` be a unit test below.

/// Poly `0x1021`, init `0x0000`, no reflection, no final XOR.
pub fn xmodem(data: &[u8]) -> u16 {
    data.iter().fold(0u16, |crc, byte| {
        (0..8).fold(crc ^ ((*byte as u16) << 8), |acc, _| {
            if acc & 0x8000 != 0 { (acc << 1) ^ 0x1021 } else { acc << 1 }
        })
    })
}

/// The two CRC bytes as they appear on the wire: big-endian, then any byte that collides with a
/// framing byte incremented.
///
/// The substitution is a Voltronic quirk, not part of XMODEM: `(`, `LF` and `CR` all mean
/// something to the framer, so a CRC byte is never allowed to take those values. Both ends apply
/// it, so a verifier compares against this rather than against the raw XMODEM output.
pub fn frame_crc(data: &[u8]) -> [u8; 2] {
    let crc = xmodem(data);
    [escape((crc >> 8) as u8), escape((crc & 0xFF) as u8)]
}

fn escape(byte: u8) -> u8 {
    match byte {
        0x28 | 0x0A | 0x0D => byte + 1,
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The check value every CRC-16/XMODEM implementation agrees on. Here so a wrong answer is
    /// attributable to this function rather than to the framing around it.
    #[test]
    fn matches_the_standard_check_vector() {
        assert_eq!(xmodem(b"123456789"), 0x31C3);
    }

    /// Every request frame in protocol.md, derived rather than pasted: the table there claims
    /// these are precomputable, and this is the claim.
    #[test]
    fn reproduces_every_documented_request_crc() {
        let cases: &[(&str, [u8; 2])] = &[
            ("QID", [0xD6, 0xEA]),
            ("QVFW", [0x62, 0x99]),
            ("QVFW3", [0xD3, 0xD4]),
            ("QMN", [0xBB, 0x64]),
            ("QGMN", [0x49, 0x29]),
            ("QMOD", [0x49, 0xC1]),
            ("QPIGS", [0xB7, 0xA9]),
            ("QPIGS2", [0x68, 0x2D]),
            ("QPIWS", [0xB4, 0xDA]),
        ];
        for (command, expected) in cases {
            assert_eq!(frame_crc(command.as_bytes()), *expected, "request CRC for {command}");
        }
    }

    /// The captured responses, whose CRC covers the leading `(` as well as the payload.
    #[test]
    fn reproduces_every_documented_response_crc() {
        let cases: &[(&str, [u8; 2])] = &[
            ("(92932210103714", [0xCE, 0xAE]),
            ("(VERFW:00072.04", [0x8A, 0xB4]),
            ("(VERFW:00012.21", [0x71, 0xF6]),
            ("(MKS2-8000", [0xB2, 0x8D]),
            ("(044", [0xC8, 0xAE]),
            ("(B", [0xE7, 0xC9]),
            // The trailing space is inside the CRC. protocol.md flags this as the field a
            // 16-byte reading of the PDF gets wrong, and it is exactly the byte that would be
            // dropped by a parser that trimmed before checking.
            ("(05.4 212.5 01156 ", [0x45, 0xE4]),
        ];
        for (frame, expected) in cases {
            assert_eq!(frame_crc(frame.as_bytes()), *expected, "response CRC for {frame:?}");
        }
    }

    #[test]
    fn framing_bytes_are_never_emitted_as_crc() {
        // 0x28 '(' , 0x0A LF and 0x0D CR each step up by one; nothing else moves.
        assert_eq!(escape(0x28), 0x29);
        assert_eq!(escape(0x0A), 0x0B);
        assert_eq!(escape(0x0D), 0x0E);
        assert_eq!(escape(0x27), 0x27);
        assert_eq!(escape(0x00), 0x00);
        assert_eq!(escape(0xFF), 0xFF);
    }
}
