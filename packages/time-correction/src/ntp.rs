//! NTPv4 with the NTS extension fields (RFC 8915 §5), client side, one exchange.
//!
//! Pure: randomness and sockets are the caller's. `build_request` takes the nonce and unique
//! identifier as arguments rather than generating them, so the whole authenticated exchange can
//! be exercised from fixtures — which for a hand-rolled AEAD framing is the difference between
//! "it worked once against a real server" and knowing which byte is wrong when it does not.
//!
//! Only the server's transmit timestamp is used. A real NTP client corrects for round-trip
//! delay using its own send and receive times, but this program runs precisely when the local
//! clock is worthless, so there is nothing to measure the round trip against. The error is
//! therefore one network delay — single-digit milliseconds — against a tolerance of a minute.
//! chrony does the accurate work afterwards.

// `siv::Aes128Siv`, not the `Aes128SivAead` wrapper: NTS authenticates over a *vector* of
// associated data (the packet prefix and the nonce, separately), which is SIV's native
// interface. The AEAD wrapper takes a single nonce and cannot express it.
//
// And the name is a trap worth stating: Aes128Siv IS AEAD_AES_SIV_CMAC_256. The 256 in the
// algorithm name is the key size, which SIV splits into two AES-128 keys.
use aes_siv::siv::Aes128Siv;
use aes_siv::KeyInit;

/// Seconds between the NTP epoch (1900-01-01) and the Unix epoch.
const NTP_TO_UNIX: i64 = 2_208_988_800;

const EF_UNIQUE_IDENTIFIER: u16 = 0x0104;
const EF_COOKIE: u16 = 0x0204;
const EF_AUTHENTICATOR: u16 = 0x0404;

const HEADER_LENGTH: usize = 48;
pub const UNIQUE_ID_LENGTH: usize = 32;
pub const NONCE_LENGTH: usize = 16;

/// An extension field, padded to a four-byte boundary as the RFC requires.
fn extension_field(kind: u16, body: &[u8]) -> Vec<u8> {
    let padded = body.len().div_ceil(4) * 4;
    let mut out = Vec::with_capacity(4 + padded);
    out.extend_from_slice(&kind.to_be_bytes());
    out.extend_from_slice(&((4 + padded) as u16).to_be_bytes());
    out.extend_from_slice(body);
    out.resize(4 + padded, 0);
    out
}

/// Walk the extension fields following the fixed header.
fn extension_fields(packet: &[u8]) -> Result<Vec<(u16, usize, usize)>, String> {
    let mut found = Vec::new();
    let mut offset = HEADER_LENGTH;

    while offset + 4 <= packet.len() {
        let kind = u16::from_be_bytes([packet[offset], packet[offset + 1]]);
        let length = u16::from_be_bytes([packet[offset + 2], packet[offset + 3]]) as usize;
        // A field that does not advance is a loop; a field longer than the packet is a lie.
        if length < 4 || !length.is_multiple_of(4) {
            return Err(format!("extension field at {offset} has invalid length {length}"));
        }
        if offset + length > packet.len() {
            return Err(format!("extension field at {offset} runs past the packet"));
        }
        found.push((kind, offset + 4, offset + length));
        offset += length;
    }

    Ok(found)
}

pub struct Request {
    pub packet: Vec<u8>,
    pub unique_id: [u8; UNIQUE_ID_LENGTH],
}

/// Build an authenticated client request for one cookie.
pub fn build_request(
    cookie: &[u8],
    c2s: &[u8],
    unique_id: [u8; UNIQUE_ID_LENGTH],
    nonce: [u8; NONCE_LENGTH],
) -> Result<Request, String> {
    let mut packet = vec![0u8; HEADER_LENGTH];
    // LI = 0, VN = 4, Mode = 3 (client).
    packet[0] = 0x23;
    // Everything else stays zero, including the transmit timestamp: with NTS the response is
    // matched by unique identifier, not by the origin timestamp, and a zero here leaks nothing
    // about a clock that is wrong anyway.

    packet.extend_from_slice(&extension_field(EF_UNIQUE_IDENTIFIER, &unique_id));
    packet.extend_from_slice(&extension_field(EF_COOKIE, cookie));

    // The authenticator covers everything before it, plus the nonce. There are no encrypted
    // extension fields in this request, so the plaintext is empty and the "ciphertext" is the
    // bare SIV tag.
    let mut siv = Aes128Siv::new_from_slice(c2s)
        .map_err(|_| format!("C2S key is {} bytes, not 32", c2s.len()))?;
    let ciphertext = siv
        .encrypt([packet.as_slice(), nonce.as_slice()], &[])
        .map_err(|_| "could not authenticate the request".to_string())?;

    let mut body = Vec::new();
    body.extend_from_slice(&(NONCE_LENGTH as u16).to_be_bytes());
    body.extend_from_slice(&(ciphertext.len() as u16).to_be_bytes());
    body.extend_from_slice(&nonce);
    body.extend_from_slice(&ciphertext);
    packet.extend_from_slice(&extension_field(EF_AUTHENTICATOR, &body));

    Ok(Request { packet, unique_id })
}

/// Verify a response and return the server's transmit timestamp as Unix seconds.
pub fn parse_response(
    packet: &[u8],
    s2c: &[u8],
    expected_unique_id: &[u8; UNIQUE_ID_LENGTH],
) -> Result<i64, String> {
    if packet.len() < HEADER_LENGTH {
        return Err(format!("response is {} bytes, shorter than a header", packet.len()));
    }
    let mode = packet[0] & 0x07;
    if mode != 4 {
        return Err(format!("response mode is {mode}, not server"));
    }
    // Leap indicator 3 is "clock not synchronised"; believing it would defeat the point.
    if packet[0] >> 6 == 3 {
        return Err("server reports an unsynchronised clock".to_string());
    }
    if packet[1] == 0 {
        // Stratum 0 is a kiss-of-death packet, never a timestamp.
        return Err("server returned a kiss-of-death packet".to_string());
    }

    let fields = extension_fields(packet)?;

    let (_, auth_start, auth_end) = *fields
        .iter()
        .find(|(kind, _, _)| *kind == EF_AUTHENTICATOR)
        .ok_or_else(|| "response is not authenticated".to_string())?;

    let unique = fields
        .iter()
        .find(|(kind, _, _)| *kind == EF_UNIQUE_IDENTIFIER)
        .ok_or_else(|| "response carries no unique identifier".to_string())?;
    // Only the bytes before the authenticator are covered by its tag, so an identifier after it
    // is unauthenticated and must not be the one that satisfies the check below. Taking the
    // FIRST match already makes an appended forgery inert whenever the server echoed the
    // identifier itself; this closes the remaining case, where it did not and the only
    // identifier present is one an attacker appended to a genuine packet.
    if unique.2 > auth_start {
        return Err("response unique identifier is not covered by the authenticator".to_string());
    }
    if &packet[unique.1..unique.2] != expected_unique_id.as_slice() {
        // The replay/mismatch guard: without this, any authenticated packet from this server,
        // including an old one, would be accepted as an answer to this request.
        return Err("response unique identifier does not match the request".to_string());
    }

    let body = &packet[auth_start..auth_end];
    if body.len() < 4 {
        return Err("authenticator field is too short".to_string());
    }
    let nonce_length = u16::from_be_bytes([body[0], body[1]]) as usize;
    let cipher_length = u16::from_be_bytes([body[2], body[3]]) as usize;
    let nonce_padded = nonce_length.div_ceil(4) * 4;
    let nonce = body
        .get(4..4 + nonce_length)
        .ok_or_else(|| "authenticator nonce runs past the field".to_string())?;
    let ciphertext = body
        .get(4 + nonce_padded..4 + nonce_padded + cipher_length)
        .ok_or_else(|| "authenticator ciphertext runs past the field".to_string())?;

    // Associated data is everything before the authenticator field's own header.
    let associated = &packet[..auth_start - 4];
    let mut siv = Aes128Siv::new_from_slice(s2c)
        .map_err(|_| format!("S2C key is {} bytes, not 32", s2c.len()))?;
    siv.decrypt([associated, nonce], ciphertext)
        .map_err(|_| "the response failed authentication".to_string())?;

    transmit_timestamp(packet)
}

/// The transmit timestamp from the fixed header, as Unix seconds.
///
/// NTP counts 32-bit seconds from 1900, which wraps in 2036. The wrap is resolved by treating
/// values below the 1968 pivot as belonging to the next era — the standard reading, and the one
/// that keeps this correct for the whole of era 1 rather than failing a decade from now.
fn transmit_timestamp(packet: &[u8]) -> Result<i64, String> {
    let bytes = packet
        .get(40..44)
        .ok_or_else(|| "packet has no transmit timestamp".to_string())?;
    let era0 = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
    if era0 == 0 {
        return Err("server sent a zero transmit timestamp".to_string());
    }
    let seconds = if era0 >= 2_147_483_648 {
        i64::from(era0) - NTP_TO_UNIX
    } else {
        i64::from(era0) + 4_294_967_296 - NTP_TO_UNIX
    };
    Ok(seconds)
}

#[cfg(test)]
mod tests {
    use super::*;

    const C2S: [u8; 32] = [7u8; 32];
    const S2C: [u8; 32] = [9u8; 32];
    const UID: [u8; UNIQUE_ID_LENGTH] = [3u8; UNIQUE_ID_LENGTH];
    const NONCE: [u8; NONCE_LENGTH] = [5u8; NONCE_LENGTH];

    /// Build a server response the way a server would, so the client path is exercised against
    /// bytes it did not produce itself.
    fn server_response(unique_id: &[u8], unix_seconds: i64, key: &[u8]) -> Vec<u8> {
        let mut packet = vec![0u8; HEADER_LENGTH];
        packet[0] = 0x24; // LI 0, VN 4, mode 4 (server)
        packet[1] = 3; // stratum
        let ntp = (unix_seconds + NTP_TO_UNIX) as u32;
        packet[40..44].copy_from_slice(&ntp.to_be_bytes());

        packet.extend_from_slice(&extension_field(EF_UNIQUE_IDENTIFIER, unique_id));

        let nonce = [11u8; NONCE_LENGTH];
        let mut siv = Aes128Siv::new_from_slice(key).unwrap();
        let ciphertext = siv
            .encrypt([packet.as_slice(), nonce.as_slice()], &[])
            .unwrap();
        let mut body = Vec::new();
        body.extend_from_slice(&(NONCE_LENGTH as u16).to_be_bytes());
        body.extend_from_slice(&(ciphertext.len() as u16).to_be_bytes());
        body.extend_from_slice(&nonce);
        body.extend_from_slice(&ciphertext);
        packet.extend_from_slice(&extension_field(EF_AUTHENTICATOR, &body));
        packet
    }

    #[test]
    fn a_request_has_the_shape_a_server_expects() {
        let request = build_request(b"cookie", &C2S, UID, NONCE).unwrap();
        assert_eq!(request.packet[0], 0x23, "version 4, mode 3");
        let fields = extension_fields(&request.packet).unwrap();
        let kinds: Vec<u16> = fields.iter().map(|(k, _, _)| *k).collect();
        assert_eq!(
            kinds,
            vec![EF_UNIQUE_IDENTIFIER, EF_COOKIE, EF_AUTHENTICATOR],
            "order matters: the authenticator must come last, it covers what precedes it"
        );
    }

    #[test]
    fn extension_fields_are_padded_to_four_bytes() {
        // A 6-byte cookie must not leave the next field misaligned.
        let request = build_request(b"abcdef", &C2S, UID, NONCE).unwrap();
        for (_, start, end) in extension_fields(&request.packet).unwrap() {
            assert_eq!((end - start + 4) % 4, 0, "field {start}..{end} is not padded");
        }
    }

    #[test]
    fn a_genuine_response_is_accepted_and_yields_the_time() {
        let response = server_response(&UID, 1_785_000_000, &S2C);
        assert_eq!(parse_response(&response, &S2C, &UID).unwrap(), 1_785_000_000);
    }

    #[test]
    fn a_response_authenticated_with_the_wrong_key_is_rejected() {
        // The whole point of NTS: an on-path attacker can produce a well-formed packet, and it
        // must not be believed.
        let response = server_response(&UID, 1_785_000_000, &[1u8; 32]);
        let error = parse_response(&response, &S2C, &UID).unwrap_err();
        assert!(error.contains("failed authentication"), "{error}");
    }

    #[test]
    fn a_tampered_timestamp_is_rejected() {
        // The timestamp is inside the associated data, so changing it breaks the tag. Without
        // that property the authentication would be decorative.
        let mut response = server_response(&UID, 1_785_000_000, &S2C);
        response[43] ^= 0xFF;
        assert!(parse_response(&response, &S2C, &UID).is_err());
    }

    #[test]
    fn a_response_for_a_different_request_is_rejected() {
        // Replay guard: correctly authenticated by this server, but answering something else.
        let response = server_response(&[4u8; UNIQUE_ID_LENGTH], 1_785_000_000, &S2C);
        let error = parse_response(&response, &S2C, &UID).unwrap_err();
        assert!(error.contains("unique identifier"), "{error}");
    }

    #[test]
    fn a_unique_identifier_after_the_authenticator_is_not_believed() {
        // Everything after the authenticator is outside its associated data, so an identifier
        // there is attacker-supplied. Built from a genuine packet that carries no identifier of
        // its own, which is the only shape where the "first match" rule would not already have
        // made the appended one inert.
        let mut packet = vec![0u8; HEADER_LENGTH];
        packet[0] = 0x24;
        packet[1] = 3;
        let ntp = (1_785_000_000i64 + NTP_TO_UNIX) as u32;
        packet[40..44].copy_from_slice(&ntp.to_be_bytes());

        let nonce = [11u8; NONCE_LENGTH];
        let mut siv = Aes128Siv::new_from_slice(&S2C).unwrap();
        let ciphertext = siv
            .encrypt([packet.as_slice(), nonce.as_slice()], &[])
            .unwrap();
        let mut body = Vec::new();
        body.extend_from_slice(&(NONCE_LENGTH as u16).to_be_bytes());
        body.extend_from_slice(&(ciphertext.len() as u16).to_be_bytes());
        body.extend_from_slice(&nonce);
        body.extend_from_slice(&ciphertext);
        packet.extend_from_slice(&extension_field(EF_AUTHENTICATOR, &body));
        // The tag over everything above is genuine; this is not covered by it.
        packet.extend_from_slice(&extension_field(EF_UNIQUE_IDENTIFIER, &UID));

        let error = parse_response(&packet, &S2C, &UID).unwrap_err();
        assert!(error.contains("not covered by the authenticator"), "{error}");
    }

    #[test]
    fn an_unauthenticated_response_is_rejected() {
        let mut packet = vec![0u8; HEADER_LENGTH];
        packet[0] = 0x24;
        packet[1] = 3;
        packet[40..44].copy_from_slice(&((1_785_000_000i64 + NTP_TO_UNIX) as u32).to_be_bytes());
        packet.extend_from_slice(&extension_field(EF_UNIQUE_IDENTIFIER, &UID));
        let error = parse_response(&packet, &S2C, &UID).unwrap_err();
        assert!(error.contains("not authenticated"), "{error}");
    }

    #[test]
    fn a_client_mode_packet_is_rejected() {
        let mut response = server_response(&UID, 1_785_000_000, &S2C);
        response[0] = 0x23;
        assert!(parse_response(&response, &S2C, &UID).is_err());
    }

    #[test]
    fn a_kiss_of_death_is_not_a_timestamp() {
        let mut response = server_response(&UID, 1_785_000_000, &S2C);
        response[1] = 0;
        let error = parse_response(&response, &S2C, &UID).unwrap_err();
        assert!(error.contains("kiss-of-death"), "{error}");
    }

    #[test]
    fn an_unsynchronised_server_is_not_believed() {
        let mut response = server_response(&UID, 1_785_000_000, &S2C);
        response[0] |= 0xC0; // leap indicator 3
        let error = parse_response(&response, &S2C, &UID).unwrap_err();
        assert!(error.contains("unsynchronised"), "{error}");
    }

    #[test]
    fn timestamps_round_trip_through_the_ntp_epoch() {
        for unix in [1_000_000_000i64, 1_785_000_000, 2_100_000_000] {
            let response = server_response(&UID, unix, &S2C);
            assert_eq!(parse_response(&response, &S2C, &UID).unwrap(), unix);
        }
    }

    #[test]
    fn timestamps_after_the_2036_wrap_are_read_in_the_next_era() {
        // era0 seconds below the pivot belong to era 1. 2040-01-01 is the case a naive
        // implementation reads as 1904.
        let mut packet = vec![0u8; HEADER_LENGTH];
        let unix_2040: i64 = 2_208_988_800; // 2040-01-01T00:00:00Z
        let era1 = ((unix_2040 + NTP_TO_UNIX) % 4_294_967_296) as u32;
        assert!(era1 < 2_147_483_648, "fixture must exercise the wrap");
        packet[40..44].copy_from_slice(&era1.to_be_bytes());
        assert_eq!(transmit_timestamp(&packet).unwrap(), unix_2040);
    }

    #[test]
    fn a_zero_timestamp_is_rejected() {
        let packet = vec![0u8; HEADER_LENGTH];
        assert!(transmit_timestamp(&packet).is_err());
    }

    #[test]
    fn a_field_claiming_more_than_the_packet_holds_is_rejected() {
        let mut packet = vec![0u8; HEADER_LENGTH];
        packet[0] = 0x24;
        packet[1] = 3;
        packet.extend_from_slice(&EF_UNIQUE_IDENTIFIER.to_be_bytes());
        packet.extend_from_slice(&0xFFFFu16.to_be_bytes());
        assert!(extension_fields(&packet).is_err());
    }

    #[test]
    fn a_zero_length_field_cannot_loop() {
        let mut packet = vec![0u8; HEADER_LENGTH];
        packet[0] = 0x24;
        packet[1] = 3;
        packet.extend_from_slice(&EF_UNIQUE_IDENTIFIER.to_be_bytes());
        packet.extend_from_slice(&0u16.to_be_bytes());
        let error = extension_fields(&packet).unwrap_err();
        assert!(error.contains("invalid length"), "{error}");
    }

    #[test]
    fn a_short_packet_is_rejected() {
        assert!(parse_response(&[0x24, 3], &S2C, &UID).is_err());
    }

    #[test]
    fn a_wrong_length_key_is_reported_rather_than_panicking() {
        assert!(build_request(b"c", &[0u8; 16], UID, NONCE).is_err());
    }
}
