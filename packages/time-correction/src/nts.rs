//! NTS key establishment (RFC 8915 §4): the record protocol spoken inside the TLS session on
//! tcp/4460, and the key material exported from that session.
//!
//! Only the client half, and only enough of it for a single one-shot exchange: no cookie store,
//! no re-keying, no NTPv5. The record codec is pure and lives here; the TLS session and the
//! socket live in the caller.
//!
//! The one rule that must not be skipped: a record carrying the critical bit that this client
//! does not understand MUST abort the exchange. That is the whole extensibility contract of the
//! protocol -- a server using it to say something load-bearing has to be able to assume a
//! client either understands or gives up, never that it quietly continues.

/// ALPN protocol identifier for NTS-KE. A server that does not negotiate this is not speaking
/// the protocol, and continuing would mean parsing whatever else it sent as records.
pub const ALPN: &[u8] = b"ntske/1";

/// RFC 8915 §4.3. The context is five bytes: next-protocol, AEAD id, and a direction byte.
pub const EXPORTER_LABEL: &[u8] = b"EXPORTER-network-time-security";

const NEXT_PROTOCOL_NTPV4: u16 = 0;
/// AEAD_AES_SIV_CMAC_256. Note the crate that implements it calls this `Aes128Siv`: the 256 is
/// the *key* size, which SIV splits into two AES-128 keys. Everyone trips over this once.
pub const AEAD_AES_SIV_CMAC_256: u16 = 15;
/// Key length for the AEAD above, per direction.
pub const KEY_LENGTH: usize = 32;

const RECORD_END_OF_MESSAGE: u16 = 0;
const RECORD_NEXT_PROTOCOL: u16 = 1;
const RECORD_ERROR: u16 = 2;
const RECORD_WARNING: u16 = 3;
const RECORD_AEAD_ALGORITHM: u16 = 4;
const RECORD_NEW_COOKIE: u16 = 5;
const RECORD_SERVER_NEGOTIATION: u16 = 6;
const RECORD_PORT_NEGOTIATION: u16 = 7;

const CRITICAL: u16 = 0x8000;

/// The five-byte exporter context for one direction.
///
/// `client_to_server` selects which of the two keys the export produces; the rest identifies
/// the negotiated protocol and algorithm so that keys cannot be reused across either.
pub fn exporter_context(aead: u16, client_to_server: bool) -> [u8; 5] {
    let protocol = NEXT_PROTOCOL_NTPV4.to_be_bytes();
    let algorithm = aead.to_be_bytes();
    [
        protocol[0],
        protocol[1],
        algorithm[0],
        algorithm[1],
        if client_to_server { 0x00 } else { 0x01 },
    ]
}

/// The complete client request: "I want NTPv4, I can do AES-SIV-CMAC-256, that is all."
///
/// Both records are sent critical, which is what RFC 8915 requires of the client for these two.
/// The client MUST NOT send cookie records.
pub fn request(aead: u16) -> Vec<u8> {
    let mut out = Vec::with_capacity(16);
    for (record, body) in [
        (RECORD_NEXT_PROTOCOL, NEXT_PROTOCOL_NTPV4),
        (RECORD_AEAD_ALGORITHM, aead),
    ] {
        out.extend_from_slice(&(record | CRITICAL).to_be_bytes());
        out.extend_from_slice(&2u16.to_be_bytes());
        out.extend_from_slice(&body.to_be_bytes());
    }
    out.extend_from_slice(&(RECORD_END_OF_MESSAGE | CRITICAL).to_be_bytes());
    out.extend_from_slice(&0u16.to_be_bytes());
    out
}

/// What the server agreed to, and where to ask for the time.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Agreement {
    pub aead: u16,
    pub cookies: Vec<Vec<u8>>,
    /// Present when the server redirected the NTP exchange elsewhere. `nts.netnod.se` does
    /// exactly this -- it answers key establishment itself and hands the timestamping off to
    /// another host entirely -- and it marks the record critical, so this is not optional to
    /// support.
    pub server: Option<String>,
    pub port: Option<u16>,
}

fn u16_at(bytes: &[u8], offset: usize) -> Result<u16, String> {
    let slice = bytes
        .get(offset..offset + 2)
        .ok_or_else(|| format!("truncated NTS-KE record at {offset}"))?;
    Ok(u16::from_be_bytes([slice[0], slice[1]]))
}

/// Whether a complete response has arrived, i.e. an end-of-message record has been seen.
///
/// The caller reads from a TLS stream and cannot know where the server stopped: some close the
/// connection after answering and some hold it open. Scanning for the terminator is the only
/// way to tell "the response is finished" from "more is coming", and treating the second as the
/// first would mean parsing a partial message.
pub fn response_complete(message: &[u8]) -> bool {
    let mut offset = 0usize;
    while offset + 4 <= message.len() {
        let header = u16::from_be_bytes([message[offset], message[offset + 1]]);
        let length = u16::from_be_bytes([message[offset + 2], message[offset + 3]]) as usize;
        if header & !CRITICAL == RECORD_END_OF_MESSAGE {
            return true;
        }
        offset += 4 + length;
    }
    false
}

/// Parse a complete NTS-KE response.
pub fn parse_response(message: &[u8], requested_aead: u16) -> Result<Agreement, String> {
    let mut offset = 0usize;
    let mut next_protocol = None;
    let mut aead = None;
    let mut cookies = Vec::new();
    let mut server = None;
    let mut port = None;
    let mut ended = false;

    while offset < message.len() {
        let header = u16_at(message, offset)?;
        let critical = header & CRITICAL != 0;
        let record = header & !CRITICAL;
        let length = u16_at(message, offset + 2)? as usize;
        let body = message
            .get(offset + 4..offset + 4 + length)
            .ok_or_else(|| format!("NTS-KE record {record} claims {length} bytes it did not send"))?;
        offset += 4 + length;

        match record {
            RECORD_END_OF_MESSAGE => {
                ended = true;
                break;
            }
            RECORD_NEXT_PROTOCOL => {
                // Zero-length means "none of what you asked for", which is a refusal.
                if body.len() != 2 {
                    return Err("server agreed to no next protocol".to_string());
                }
                next_protocol = Some(u16::from_be_bytes([body[0], body[1]]));
            }
            RECORD_ERROR => {
                let code = if body.len() == 2 {
                    u16::from_be_bytes([body[0], body[1]]).to_string()
                } else {
                    "unknown".to_string()
                };
                return Err(format!("server returned NTS-KE error {code}"));
            }
            RECORD_WARNING => {
                // Warnings are critical-by-spec but carry no action for a client that has
                // nothing to fall back to; refusing is the conservative reading.
                return Err("server returned an NTS-KE warning".to_string());
            }
            RECORD_AEAD_ALGORITHM => {
                if body.len() != 2 {
                    return Err("server agreed to no AEAD algorithm".to_string());
                }
                aead = Some(u16::from_be_bytes([body[0], body[1]]));
            }
            RECORD_NEW_COOKIE => cookies.push(body.to_vec()),
            RECORD_SERVER_NEGOTIATION => {
                server = Some(
                    std::str::from_utf8(body)
                        .map_err(|_| "server negotiation record is not UTF-8".to_string())?
                        .to_string(),
                );
            }
            RECORD_PORT_NEGOTIATION => {
                if body.len() != 2 {
                    return Err("port negotiation record is not two bytes".to_string());
                }
                port = Some(u16::from_be_bytes([body[0], body[1]]));
            }
            unknown => {
                // The extensibility contract. Anything else is ignorable.
                if critical {
                    return Err(format!(
                        "server sent critical NTS-KE record {unknown}, which this client does not implement"
                    ));
                }
            }
        }
    }

    if !ended {
        return Err("NTS-KE response ended without an end-of-message record".to_string());
    }
    match next_protocol {
        Some(NEXT_PROTOCOL_NTPV4) => {}
        Some(other) => return Err(format!("server chose next protocol {other}, not NTPv4")),
        None => return Err("server sent no next protocol record".to_string()),
    }
    match aead {
        Some(chosen) if chosen == requested_aead => {}
        Some(other) => return Err(format!("server chose AEAD {other}, which was not offered")),
        None => return Err("server sent no AEAD record".to_string()),
    }
    if cookies.is_empty() {
        return Err("server sent no cookies".to_string());
    }

    Ok(Agreement {
        aead: requested_aead,
        cookies,
        server,
        port,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(kind: u16, critical: bool, body: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        let header = if critical { kind | CRITICAL } else { kind };
        out.extend_from_slice(&header.to_be_bytes());
        out.extend_from_slice(&(body.len() as u16).to_be_bytes());
        out.extend_from_slice(body);
        out
    }

    fn ok_response(extra: &[u8]) -> Vec<u8> {
        let mut m = record(RECORD_NEXT_PROTOCOL, true, &NEXT_PROTOCOL_NTPV4.to_be_bytes());
        m.extend_from_slice(&record(
            RECORD_AEAD_ALGORITHM,
            true,
            &AEAD_AES_SIV_CMAC_256.to_be_bytes(),
        ));
        m.extend_from_slice(&record(RECORD_NEW_COOKIE, false, b"cookie-one"));
        m.extend_from_slice(extra);
        m.extend_from_slice(&record(RECORD_END_OF_MESSAGE, true, b""));
        m
    }

    #[test]
    fn the_request_is_the_sixteen_bytes_the_rfc_describes() {
        assert_eq!(
            request(AEAD_AES_SIV_CMAC_256),
            vec![
                0x80, 0x01, 0x00, 0x02, 0x00, 0x00, // next protocol, critical, NTPv4
                0x80, 0x04, 0x00, 0x02, 0x00, 0x0f, // AEAD, critical, AES-SIV-CMAC-256
                0x80, 0x00, 0x00, 0x00, // end of message, critical
            ]
        );
    }

    #[test]
    fn exporter_context_encodes_protocol_algorithm_and_direction() {
        assert_eq!(
            exporter_context(AEAD_AES_SIV_CMAC_256, true),
            [0x00, 0x00, 0x00, 0x0f, 0x00]
        );
        assert_eq!(
            exporter_context(AEAD_AES_SIV_CMAC_256, false),
            [0x00, 0x00, 0x00, 0x0f, 0x01]
        );
    }

    #[test]
    fn parses_a_plain_agreement() {
        let got = parse_response(&ok_response(b""), AEAD_AES_SIV_CMAC_256).unwrap();
        assert_eq!(got.aead, AEAD_AES_SIV_CMAC_256);
        assert_eq!(got.cookies, vec![b"cookie-one".to_vec()]);
        assert_eq!(got.server, None);
        assert_eq!(got.port, None);
    }

    #[test]
    fn collects_every_cookie() {
        let mut extra = Vec::new();
        for _ in 0..7 {
            extra.extend_from_slice(&record(RECORD_NEW_COOKIE, false, b"another"));
        }
        let got = parse_response(&ok_response(&extra), AEAD_AES_SIV_CMAC_256).unwrap();
        assert_eq!(got.cookies.len(), 8, "one from ok_response plus seven");
    }

    #[test]
    fn honours_a_server_and_port_redirect() {
        // The netnod shape, measured 2026-08-02: a critical server negotiation record carrying
        // an IP literal, plus a critical port negotiation record for 4123. A client that
        // ignored these would send its NTP request to a host that will not answer it.
        let mut extra = record(RECORD_SERVER_NEGOTIATION, true, b"194.58.207.80");
        extra.extend_from_slice(&record(RECORD_PORT_NEGOTIATION, true, &4123u16.to_be_bytes()));
        let got = parse_response(&ok_response(&extra), AEAD_AES_SIV_CMAC_256).unwrap();
        assert_eq!(got.server.as_deref(), Some("194.58.207.80"));
        assert_eq!(got.port, Some(4123));
    }

    #[test]
    fn aborts_on_an_unknown_critical_record() {
        // The extensibility contract: a server that marks something critical is entitled to
        // assume a client that does not understand it stops.
        let extra = record(999, true, b"whatever");
        let error = parse_response(&ok_response(&extra), AEAD_AES_SIV_CMAC_256).unwrap_err();
        assert!(error.contains("critical NTS-KE record 999"), "{error}");
    }

    #[test]
    fn ignores_an_unknown_non_critical_record() {
        let extra = record(999, false, b"whatever");
        assert!(parse_response(&ok_response(&extra), AEAD_AES_SIV_CMAC_256).is_ok());
    }

    #[test]
    fn reports_a_server_error_record() {
        let mut m = record(RECORD_ERROR, true, &1u16.to_be_bytes());
        m.extend_from_slice(&record(RECORD_END_OF_MESSAGE, true, b""));
        let error = parse_response(&m, AEAD_AES_SIV_CMAC_256).unwrap_err();
        assert!(error.contains("error 1"), "{error}");
    }

    #[test]
    fn rejects_an_aead_that_was_not_offered() {
        let mut m = record(RECORD_NEXT_PROTOCOL, true, &NEXT_PROTOCOL_NTPV4.to_be_bytes());
        m.extend_from_slice(&record(RECORD_AEAD_ALGORITHM, true, &17u16.to_be_bytes()));
        m.extend_from_slice(&record(RECORD_NEW_COOKIE, false, b"c"));
        m.extend_from_slice(&record(RECORD_END_OF_MESSAGE, true, b""));
        let error = parse_response(&m, AEAD_AES_SIV_CMAC_256).unwrap_err();
        assert!(error.contains("AEAD 17"), "{error}");
    }

    #[test]
    fn rejects_a_different_next_protocol() {
        let mut m = record(RECORD_NEXT_PROTOCOL, true, &1u16.to_be_bytes());
        m.extend_from_slice(&record(
            RECORD_AEAD_ALGORITHM,
            true,
            &AEAD_AES_SIV_CMAC_256.to_be_bytes(),
        ));
        m.extend_from_slice(&record(RECORD_NEW_COOKIE, false, b"c"));
        m.extend_from_slice(&record(RECORD_END_OF_MESSAGE, true, b""));
        assert!(parse_response(&m, AEAD_AES_SIV_CMAC_256).is_err());
    }

    #[test]
    fn rejects_a_refusal_expressed_as_an_empty_negotiation() {
        let mut m = record(RECORD_NEXT_PROTOCOL, true, b"");
        m.extend_from_slice(&record(RECORD_END_OF_MESSAGE, true, b""));
        assert!(parse_response(&m, AEAD_AES_SIV_CMAC_256).is_err());
    }

    #[test]
    fn rejects_an_agreement_with_no_cookies() {
        let mut m = record(RECORD_NEXT_PROTOCOL, true, &NEXT_PROTOCOL_NTPV4.to_be_bytes());
        m.extend_from_slice(&record(
            RECORD_AEAD_ALGORITHM,
            true,
            &AEAD_AES_SIV_CMAC_256.to_be_bytes(),
        ));
        m.extend_from_slice(&record(RECORD_END_OF_MESSAGE, true, b""));
        let error = parse_response(&m, AEAD_AES_SIV_CMAC_256).unwrap_err();
        assert!(error.contains("no cookies"), "{error}");
    }

    #[test]
    fn rejects_a_response_that_never_ends() {
        // Without the end-of-message record there is no way to know the server finished rather
        // than the connection being cut mid-stream.
        let m = record(RECORD_NEXT_PROTOCOL, true, &NEXT_PROTOCOL_NTPV4.to_be_bytes());
        let error = parse_response(&m, AEAD_AES_SIV_CMAC_256).unwrap_err();
        assert!(error.contains("end-of-message"), "{error}");
    }

    #[test]
    fn rejects_a_record_longer_than_the_message() {
        let m = vec![0x80, 0x05, 0xFF, 0xFF, 0x01];
        assert!(parse_response(&m, AEAD_AES_SIV_CMAC_256).is_err());
    }

    #[test]
    fn completeness_is_detectable_before_parsing() {
        let full = ok_response(b"");
        assert!(response_complete(&full));
        // Every strict prefix short of the terminator must read as incomplete, or the reader
        // would parse a half-arrived message as a malformed one.
        for cut in 0..full.len() - 4 {
            assert!(!response_complete(&full[..cut]), "prefix of {cut} looked complete");
        }
    }

    #[test]
    fn stops_at_end_of_message_and_ignores_trailing_bytes() {
        let mut m = ok_response(b"");
        m.extend_from_slice(b"garbage that must not be parsed");
        assert!(parse_response(&m, AEAD_AES_SIV_CMAC_256).is_ok());
    }
}
