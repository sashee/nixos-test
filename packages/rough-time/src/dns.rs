//! DNS wire format, enough to ask a DoH resolver for one name's addresses.
//!
//! Hand-rolled rather than pulled in, for the same reason the rest of this crate is: a full
//! resolver library is a large dependency for one question, and the part that matters here --
//! not hanging, not reading past the end of a buffer -- is easier to be sure of in 150 lines
//! that are entirely pure and entirely tested than in someone else's 20,000.
//!
//! Pure `&[u8] -> Result<_, String>` throughout, so every case below is a fixture rather than
//! a VM boot. That matters most for the compression-pointer loop: a self-referential pointer
//! is an infinite loop, and an infinite loop in this program is a host that never finishes
//! establishing a clock and therefore never gets DNS, on the one box that cannot be reached to
//! be told so.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

pub const TYPE_A: u16 = 1;
pub const TYPE_AAAA: u16 = 28;
const TYPE_CNAME: u16 = 5;
const CLASS_IN: u16 = 1;

/// Maximum pointer hops while expanding one name. RFC 1035 allows a pointer to appear anywhere,
/// so the only bound that holds is "fewer hops than the message could possibly need"; each hop
/// must point strictly backwards in a well-formed message, but a hostile one need not, hence a
/// hard ceiling rather than a monotonicity check.
const MAX_JUMPS: usize = 64;

/// Encode a standard recursive query. `id` is echoed by the server and must be checked.
pub fn encode_query(id: u16, name: &str, qtype: u16) -> Result<Vec<u8>, String> {
    let mut out = Vec::with_capacity(32 + name.len());
    out.extend_from_slice(&id.to_be_bytes());
    // RD only: no truncation games, no DNSSEC records we would not check anyway.
    out.extend_from_slice(&0x0100u16.to_be_bytes());
    out.extend_from_slice(&1u16.to_be_bytes()); // QDCOUNT
    out.extend_from_slice(&[0; 6]); // AN/NS/AR COUNT

    for label in name.split('.').filter(|l| !l.is_empty()) {
        if label.len() > 63 {
            return Err(format!("label {label:?} exceeds 63 bytes"));
        }
        out.push(label.len() as u8);
        out.extend_from_slice(label.as_bytes());
    }
    out.push(0);

    out.extend_from_slice(&qtype.to_be_bytes());
    out.extend_from_slice(&CLASS_IN.to_be_bytes());
    Ok(out)
}

fn u16_at(message: &[u8], offset: usize) -> Result<u16, String> {
    let bytes = message
        .get(offset..offset + 2)
        .ok_or_else(|| format!("truncated message: wanted 2 bytes at {offset}"))?;
    Ok(u16::from_be_bytes([bytes[0], bytes[1]]))
}

/// Walk a (possibly compressed) name, returning the offset just past it *in the original
/// stream* -- which is not where the walk ended if it followed a pointer.
///
/// The name itself is not returned: nothing here needs to compare names, only to skip them.
/// CNAME targets are followed by RR type, not by name equality, which keeps this simple and
/// removes a whole class of case-folding bugs.
fn skip_name(message: &[u8], start: usize) -> Result<usize, String> {
    let mut offset = start;
    let mut jumps = 0usize;
    let mut after_pointer: Option<usize> = None;

    loop {
        let length = *message
            .get(offset)
            .ok_or_else(|| format!("truncated name at {offset}"))?;

        match length & 0xC0 {
            0 => {
                if length == 0 {
                    let end = offset + 1;
                    return Ok(after_pointer.unwrap_or(end));
                }
                offset += 1 + length as usize;
                if offset > message.len() {
                    return Err(format!("label at {offset} runs past the message"));
                }
            }
            0xC0 => {
                let pointer = (u16_at(message, offset)? & 0x3FFF) as usize;
                // The first pointer ends the name as far as the caller's cursor is concerned;
                // everything after it is expansion.
                after_pointer.get_or_insert(offset + 2);
                jumps += 1;
                if jumps > MAX_JUMPS {
                    return Err("compressed name exceeds the pointer limit; refusing to follow a possible loop".to_string());
                }
                if pointer >= message.len() {
                    return Err(format!("compression pointer to {pointer} is past the message"));
                }
                offset = pointer;
            }
            // 0x40 and 0x80 are reserved label types (RFC 6891 retired the one that used them).
            other => return Err(format!("reserved label type {other:#x} at {offset}")),
        }
    }
}

/// The addresses a DoH response carries for the question that was asked.
///
/// CNAME chains are followed only in the sense that every A/AAAA record in the answer section
/// is taken, whatever it is a record *for*. That is deliberate: a resolver that answers
/// `nts.example` with `CNAME -> host.example` plus `host.example A 1.2.3.4` has answered the
/// question, and matching owner names would mean implementing name comparison and chain
/// walking to reach the same conclusion. The addresses are only ever used as dial targets for
/// a TLS session that verifies the ORIGINAL hostname, so a resolver that returns an address
/// for something else cannot gain anything by it -- the certificate check is what binds the
/// answer to the name, not this parser.
pub fn parse_response(message: &[u8], id: u16, qtype: u16) -> Result<Vec<IpAddr>, String> {
    if message.len() < 12 {
        return Err(format!("response is {} bytes, shorter than a header", message.len()));
    }

    if u16_at(message, 0)? != id {
        return Err("response id does not match the query".to_string());
    }

    let flags = u16_at(message, 2)?;
    if flags & 0x8000 == 0 {
        return Err("response is not marked as a response".to_string());
    }
    if flags & 0x0200 != 0 {
        // A truncated answer over DoH means something is badly wrong; half-parsing it would be
        // worse than reporting it.
        return Err("response is truncated".to_string());
    }
    let rcode = flags & 0x000F;
    if rcode != 0 {
        return Err(format!("resolver returned rcode {rcode}"));
    }

    let questions = u16_at(message, 4)?;
    let answers = u16_at(message, 6)?;

    let mut offset = 12;
    for _ in 0..questions {
        offset = skip_name(message, offset)?;
        offset += 4; // QTYPE + QCLASS
        if offset > message.len() {
            return Err("question section runs past the message".to_string());
        }
    }

    let mut found = Vec::new();
    for _ in 0..answers {
        offset = skip_name(message, offset)?;
        let rtype = u16_at(message, offset)?;
        let rclass = u16_at(message, offset + 2)?;
        let rdlength = u16_at(message, offset + 8)? as usize;
        offset += 10;

        let rdata = message
            .get(offset..offset + rdlength)
            .ok_or_else(|| format!("record data at {offset} runs past the message"))?;
        offset += rdlength;

        if rclass != CLASS_IN {
            continue;
        }
        match rtype {
            TYPE_A if qtype == TYPE_A && rdlength == 4 => {
                found.push(IpAddr::V4(Ipv4Addr::new(rdata[0], rdata[1], rdata[2], rdata[3])));
            }
            TYPE_AAAA if qtype == TYPE_AAAA && rdlength == 16 => {
                let mut octets = [0u8; 16];
                octets.copy_from_slice(rdata);
                found.push(IpAddr::V6(Ipv6Addr::from(octets)));
            }
            // An A record whose rdata is not 4 bytes is malformed, not merely uninteresting.
            TYPE_A if qtype == TYPE_A => {
                return Err(format!("A record with {rdlength} bytes of data"));
            }
            TYPE_AAAA if qtype == TYPE_AAAA => {
                return Err(format!("AAAA record with {rdlength} bytes of data"));
            }
            // CNAMEs are expected and carry no address; anything else is simply not our answer.
            TYPE_CNAME => {}
            _ => {}
        }
    }

    if found.is_empty() {
        return Err("no address records in the answer".to_string());
    }
    Ok(found)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Header + question for `a.example`, so fixtures below only have to append answers.
    fn preamble(answers: u16) -> Vec<u8> {
        let mut m = vec![0x12, 0x34, 0x81, 0x80, 0x00, 0x01];
        m.extend_from_slice(&answers.to_be_bytes());
        m.extend_from_slice(&[0, 0, 0, 0]);
        m.extend_from_slice(b"\x01a\x07example\x00");
        m.extend_from_slice(&TYPE_A.to_be_bytes());
        m.extend_from_slice(&CLASS_IN.to_be_bytes());
        m
    }

    fn a_record(name: &[u8], ip: [u8; 4]) -> Vec<u8> {
        let mut r = name.to_vec();
        r.extend_from_slice(&TYPE_A.to_be_bytes());
        r.extend_from_slice(&CLASS_IN.to_be_bytes());
        r.extend_from_slice(&60u32.to_be_bytes());
        r.extend_from_slice(&4u16.to_be_bytes());
        r.extend_from_slice(&ip);
        r
    }

    #[test]
    fn encodes_a_query_the_shape_a_resolver_expects() {
        let q = encode_query(0x1234, "a.example", TYPE_A).unwrap();
        assert_eq!(&q[0..2], &[0x12, 0x34], "id");
        assert_eq!(&q[2..4], &[0x01, 0x00], "RD set, nothing else");
        assert_eq!(&q[4..6], &[0x00, 0x01], "one question");
        assert_eq!(&q[12..], b"\x01a\x07example\x00\x00\x01\x00\x01");
    }

    #[test]
    fn encoding_tolerates_a_trailing_dot() {
        assert_eq!(
            encode_query(1, "a.example.", TYPE_A).unwrap(),
            encode_query(1, "a.example", TYPE_A).unwrap()
        );
    }

    #[test]
    fn encoding_rejects_an_overlong_label() {
        let long = "x".repeat(64);
        assert!(encode_query(1, &format!("{long}.example"), TYPE_A).is_err());
    }

    #[test]
    fn parses_an_uncompressed_answer() {
        let mut m = preamble(1);
        m.extend_from_slice(&a_record(b"\x01a\x07example\x00", [1, 2, 3, 4]));
        assert_eq!(
            parse_response(&m, 0x1234, TYPE_A).unwrap(),
            vec![IpAddr::V4(Ipv4Addr::new(1, 2, 3, 4))]
        );
    }

    #[test]
    fn parses_a_compressed_answer() {
        // 0xC00C points at the question's name, which is what every real resolver emits.
        let mut m = preamble(1);
        m.extend_from_slice(&a_record(b"\xc0\x0c", [5, 6, 7, 8]));
        assert_eq!(
            parse_response(&m, 0x1234, TYPE_A).unwrap(),
            vec![IpAddr::V4(Ipv4Addr::new(5, 6, 7, 8))]
        );
    }

    #[test]
    fn follows_a_cname_to_the_address_behind_it() {
        let mut m = preamble(2);
        // CNAME a.example -> b.example
        m.extend_from_slice(b"\xc0\x0c");
        m.extend_from_slice(&TYPE_CNAME.to_be_bytes());
        m.extend_from_slice(&CLASS_IN.to_be_bytes());
        m.extend_from_slice(&60u32.to_be_bytes());
        let target: &[u8] = b"\x01b\x07example\x00";
        m.extend_from_slice(&(target.len() as u16).to_be_bytes());
        m.extend_from_slice(target);
        m.extend_from_slice(&a_record(target, [9, 9, 9, 9]));
        assert_eq!(
            parse_response(&m, 0x1234, TYPE_A).unwrap(),
            vec![IpAddr::V4(Ipv4Addr::new(9, 9, 9, 9))]
        );
    }

    #[test]
    fn collects_every_address_offered() {
        let mut m = preamble(2);
        m.extend_from_slice(&a_record(b"\xc0\x0c", [1, 1, 1, 1]));
        m.extend_from_slice(&a_record(b"\xc0\x0c", [2, 2, 2, 2]));
        assert_eq!(parse_response(&m, 0x1234, TYPE_A).unwrap().len(), 2);
    }

    #[test]
    fn a_self_referential_pointer_terminates() {
        // The case that would otherwise hang the boot. The pointer at offset 12 addresses
        // itself, so an unguarded walk never returns.
        let mut m = vec![0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x00, 0, 0, 0, 0];
        m.extend_from_slice(&[0xC0, 0x0C]);
        let error = parse_response(&m, 0x1234, TYPE_A).unwrap_err();
        assert!(error.contains("pointer limit"), "{error}");
    }

    #[test]
    fn a_two_pointer_cycle_terminates() {
        let mut m = vec![0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x00, 0, 0, 0, 0];
        m.extend_from_slice(&[0xC0, 0x0E, 0xC0, 0x0C]); // 12 -> 14 -> 12
        let error = parse_response(&m, 0x1234, TYPE_A).unwrap_err();
        assert!(error.contains("pointer limit"), "{error}");
    }

    #[test]
    fn a_pointer_past_the_end_is_rejected() {
        let mut m = vec![0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x00, 0, 0, 0, 0];
        m.extend_from_slice(&[0xC0, 0xFF]);
        assert!(parse_response(&m, 0x1234, TYPE_A).is_err());
    }

    #[test]
    fn rejects_a_mismatched_id() {
        let mut m = preamble(1);
        m.extend_from_slice(&a_record(b"\xc0\x0c", [1, 2, 3, 4]));
        let error = parse_response(&m, 0x9999, TYPE_A).unwrap_err();
        assert!(error.contains("id"), "{error}");
    }

    #[test]
    fn rejects_a_query_masquerading_as_a_response() {
        let mut m = preamble(1);
        m[2] = 0x01; // clear QR
        m.extend_from_slice(&a_record(b"\xc0\x0c", [1, 2, 3, 4]));
        assert!(parse_response(&m, 0x1234, TYPE_A).is_err());
    }

    #[test]
    fn rejects_a_truncated_flag() {
        let mut m = preamble(1);
        m[2] |= 0x02; // TC
        m.extend_from_slice(&a_record(b"\xc0\x0c", [1, 2, 3, 4]));
        let error = parse_response(&m, 0x1234, TYPE_A).unwrap_err();
        assert!(error.contains("truncated"), "{error}");
    }

    #[test]
    fn reports_the_rcode_rather_than_guessing() {
        let mut m = preamble(0);
        m[3] = 0x83; // NXDOMAIN
        let error = parse_response(&m, 0x1234, TYPE_A).unwrap_err();
        assert!(error.contains("rcode 3"), "{error}");
    }

    #[test]
    fn an_empty_answer_section_is_an_error_not_an_empty_list() {
        // Otherwise a NODATA answer would look like "resolved to nothing" and the caller would
        // report an unreachable server rather than a name that does not resolve.
        let error = parse_response(&preamble(0), 0x1234, TYPE_A).unwrap_err();
        assert!(error.contains("no address records"), "{error}");
    }

    #[test]
    fn rejects_a_malformed_address_record() {
        let mut m = preamble(1);
        let mut r: Vec<u8> = b"\xc0\x0c".to_vec();
        r.extend_from_slice(&TYPE_A.to_be_bytes());
        r.extend_from_slice(&CLASS_IN.to_be_bytes());
        r.extend_from_slice(&60u32.to_be_bytes());
        r.extend_from_slice(&5u16.to_be_bytes()); // A with 5 bytes
        r.extend_from_slice(&[1, 2, 3, 4, 5]);
        m.extend_from_slice(&r);
        let error = parse_response(&m, 0x1234, TYPE_A).unwrap_err();
        assert!(error.contains("A record with 5"), "{error}");
    }

    #[test]
    fn rejects_rdata_running_past_the_message() {
        let mut m = preamble(1);
        let mut r: Vec<u8> = b"\xc0\x0c".to_vec();
        r.extend_from_slice(&TYPE_A.to_be_bytes());
        r.extend_from_slice(&CLASS_IN.to_be_bytes());
        r.extend_from_slice(&60u32.to_be_bytes());
        r.extend_from_slice(&64u16.to_be_bytes()); // claims 64 bytes, supplies 4
        r.extend_from_slice(&[1, 2, 3, 4]);
        m.extend_from_slice(&r);
        assert!(parse_response(&m, 0x1234, TYPE_A).is_err());
    }

    #[test]
    fn parses_aaaa_when_that_is_what_was_asked() {
        let mut m = vec![0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0, 0, 0, 0];
        m.extend_from_slice(b"\x01a\x07example\x00");
        m.extend_from_slice(&TYPE_AAAA.to_be_bytes());
        m.extend_from_slice(&CLASS_IN.to_be_bytes());
        m.extend_from_slice(b"\xc0\x0c");
        m.extend_from_slice(&TYPE_AAAA.to_be_bytes());
        m.extend_from_slice(&CLASS_IN.to_be_bytes());
        m.extend_from_slice(&60u32.to_be_bytes());
        m.extend_from_slice(&16u16.to_be_bytes());
        m.extend_from_slice(&[0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);
        let got = parse_response(&m, 0x1234, TYPE_AAAA).unwrap();
        assert_eq!(got, vec!["2001:db8::1".parse::<IpAddr>().unwrap()]);
    }

    #[test]
    fn ignores_records_of_the_other_family() {
        // An AAAA in an A answer is normal (additional-section style padding) and must not be
        // mistaken for the answer or treated as malformed.
        let mut m = preamble(2);
        m.extend_from_slice(b"\xc0\x0c");
        m.extend_from_slice(&TYPE_AAAA.to_be_bytes());
        m.extend_from_slice(&CLASS_IN.to_be_bytes());
        m.extend_from_slice(&60u32.to_be_bytes());
        m.extend_from_slice(&16u16.to_be_bytes());
        m.extend_from_slice(&[0; 16]);
        m.extend_from_slice(&a_record(b"\xc0\x0c", [7, 7, 7, 7]));
        assert_eq!(
            parse_response(&m, 0x1234, TYPE_A).unwrap(),
            vec![IpAddr::V4(Ipv4Addr::new(7, 7, 7, 7))]
        );
    }

    #[test]
    fn a_header_only_message_is_rejected() {
        assert!(parse_response(&[0x12, 0x34], 0x1234, TYPE_A).is_err());
        assert!(parse_response(&[], 0x1234, TYPE_A).is_err());
    }

    #[test]
    fn rejects_a_reserved_label_type() {
        let mut m = vec![0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x00, 0, 0, 0, 0];
        m.extend_from_slice(&[0x80, 0x00]);
        let error = parse_response(&m, 0x1234, TYPE_A).unwrap_err();
        assert!(error.contains("reserved label type"), "{error}");
    }

    #[test]
    fn a_long_but_legal_pointer_chain_is_accepted() {
        // Guards against the loop limit being so tight it rejects legitimate compression.
        // 8 hops, each pointing strictly backwards, ending in a real name.
        let mut m = vec![0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x00, 0, 0, 0, 0];
        m.extend_from_slice(b"\x01a\x07example\x00"); // at 12
        let mut previous = 12u16;
        for _ in 0..8 {
            let here = m.len() as u16;
            m.extend_from_slice(&(0xC000 | previous).to_be_bytes());
            previous = here;
        }
        assert!(skip_name(&m, previous as usize).is_ok());
    }
}
