//! A one-shot HTTP/1.1 POST over a unix socket.
//!
//! Hand-written rather than hyper + a unix connector: this sends exactly one request per process
//! with a known length and reads one response, so an async runtime and a connection pool would be
//! several megabytes of dependency for a code path that is a write and a read.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

/// Bounds a run that would otherwise hang forever against a wedged receiver -- the unit is on a
/// timer, so a stuck run would still be holding the socket when the next one is due.
const TIMEOUT: Duration = Duration::from_secs(30);

pub struct Response {
    pub status: u16,
    pub body: Vec<u8>,
}

pub fn post(
    socket: &Path,
    path: &str,
    content_type: &str,
    body: &[u8],
) -> Result<Response, String> {
    let mut stream = UnixStream::connect(socket)
        .map_err(|e| format!("cannot reach {}: {e}", socket.display()))?;
    stream.set_read_timeout(Some(TIMEOUT)).map_err(|e| format!("setting read timeout: {e}"))?;
    stream.set_write_timeout(Some(TIMEOUT)).map_err(|e| format!("setting write timeout: {e}"))?;

    // `Connection: close` is what lets the body be read to EOF instead of parsing
    // Content-Length or chunked framing off the response.
    let head = format!(
        "POST {path} HTTP/1.1\r\n\
         Host: localhost\r\n\
         Content-Type: {content_type}\r\n\
         Content-Length: {}\r\n\
         Connection: close\r\n\
         \r\n",
        body.len()
    );

    stream.write_all(head.as_bytes()).map_err(|e| format!("writing request head: {e}"))?;
    stream.write_all(body).map_err(|e| format!("writing request body: {e}"))?;
    stream.flush().map_err(|e| format!("flushing request: {e}"))?;

    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).map_err(|e| format!("reading response: {e}"))?;
    parse_response(&raw)
}

fn parse_response(raw: &[u8]) -> Result<Response, String> {
    let separator = raw
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .ok_or_else(|| "response has no header terminator".to_owned())?;

    let head = String::from_utf8_lossy(&raw[..separator]);
    let status_line = head.lines().next().ok_or_else(|| "empty response".to_owned())?;
    let status: u16 = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|code| code.parse().ok())
        .ok_or_else(|| format!("unparsable status line {status_line:?}"))?;

    Ok(Response { status, body: raw[separator + 4..].to_vec() })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_the_status_line_from_the_body() {
        let raw = b"HTTP/1.1 200 OK\r\ncontent-type: application/x-protobuf\r\n\r\n\x08\x01";
        let response = parse_response(raw).unwrap();
        assert_eq!(response.status, 200);
        assert_eq!(response.body, vec![0x08, 0x01]);
    }

    #[test]
    fn an_error_status_is_reported_not_swallowed() {
        let raw = b"HTTP/1.1 415 Unsupported Media Type\r\n\r\nnope";
        assert_eq!(parse_response(raw).unwrap().status, 415);
    }

    #[test]
    fn an_empty_body_is_not_an_error() {
        let response = parse_response(b"HTTP/1.1 200 OK\r\n\r\n").unwrap();
        assert_eq!(response.status, 200);
        assert!(response.body.is_empty());
    }

    #[test]
    fn a_truncated_response_fails_loudly() {
        assert!(parse_response(b"HTTP/1.1 200 OK\r\n").is_err());
    }
}
