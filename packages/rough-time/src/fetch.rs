//! One HTTPS request to one address, for its `Date` header.
//!
//! The HTTP version is whatever the server negotiates over ALPN. Nothing here assumes 1.1 or
//! 2: an earlier hand-rolled HTTP/1.1 client worked against three of the four configured
//! providers and was one operator decision away from working against two, which is not a
//! property to build a boot path on. A provider that answers in a version we cannot speak, or
//! answers without a `Date`, simply fails and the quorum reports it -- that is a normal
//! outcome, not a case to special-case.
//!
//! The address is dialled directly and the hostname is used only for SNI and certificate
//! verification -- there is no name resolution anywhere in this program. That is the point:
//! DNS on these hosts is DoH, DoH is TLS, and TLS needs the very clock this program exists to
//! establish.

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use reqwest::header::HeaderMap;
use rustls::pki_types::ServerName;

use crate::verify::{TimeAgnosticVerifier, Verifier};

/// What a single endpoint told us, after its chain has been re-verified at the time it
/// claimed. The chain is not carried out of here: pass 2 happens inside `probe`, so no caller
/// can obtain a `Date` that has not been through it.
pub struct Response {
    pub date: String,
    /// Present when the response travelled through a cache. A cached `Date` was stamped when
    /// the response was first generated, which may be arbitrarily long ago.
    pub age: Option<String>,
    /// For diagnostics only; nothing branches on it.
    pub version: String,
}

/// The RFC 8484 path, and that RFC's own example query (`www.example.com A`, id 0) as the
/// base64url payload.
///
/// A real DoH request rather than `GET /`, because the site root is not something these
/// operators agree on: measured on 2026-08-02, mullvad closes the connection there and google
/// answers from a cache (`Age: 122`), whose `Date` was stamped whenever that entry was made.
/// `/dns-query` is the path all of them serve, and lib/doh-stamps.nix already records that
/// every provider in the list uses it.
const DOH_PATH: &str = "/dns-query?dns=AAABAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB";

/// Pull the two headers that matter out of a response.
///
/// The status code is deliberately not consulted. A provider that rejects the query has still
/// stamped a `Date` on the rejection -- quad9 answers `505 HTTP Version Not Supported` over
/// HTTP/1.1 and does exactly that -- and requiring `200` would couple this to whether a
/// resolver could answer a DNS question we do not care about.
fn extract(headers: &HeaderMap) -> Result<(String, Option<String>), String> {
    let text = |name: &str| -> Option<String> {
        headers
            .get(name)
            .and_then(|v| v.to_str().ok())
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
    };

    let date = text("date").ok_or_else(|| "no Date header in the response".to_string())?;
    Ok((date, text("age")))
}

/// Query `address` over HTTPS, presenting `hostname` for SNI and verification.
pub fn probe(
    verifier: Arc<Verifier>,
    hostname: &str,
    address: IpAddr,
    timeout: Duration,
) -> Result<Response, String> {
    let server_name = ServerName::try_from(hostname.to_string())
        .map_err(|_| format!("{hostname} is not a valid server name"))?;

    // One verifier per connection, so the chain it records is unambiguously this
    // connection's.
    let handshake_verifier = TimeAgnosticVerifier::new(verifier.clone());

    let mut config = rustls::ClientConfig::builder_with_provider(verifier.crypto())
        .with_safe_default_protocol_versions()
        .map_err(|e| format!("cannot select TLS versions: {e}"))?
        .dangerous()
        .with_custom_certificate_verifier(handshake_verifier.clone())
        .with_no_client_auth();
    // Offer both and let the server choose. The response is read through the client, so
    // whichever it picks is handled.
    config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];

    let client = reqwest::blocking::Client::builder()
        .use_preconfigured_tls(config)
        // Dial the pinned address while still presenting and verifying the hostname. This is
        // what keeps the program free of name resolution.
        .resolve(hostname, SocketAddr::new(address, 443))
        // A redirect would move the request to a host we did not pin and did not verify
        // against; there is nothing at the other end of one that we want.
        .redirect(reqwest::redirect::Policy::none())
        // No environment proxy: the whole point is a direct, verified connection to a known
        // address, and a proxy would terminate TLS somewhere we cannot check.
        .no_proxy()
        .timeout(timeout)
        .connect_timeout(timeout)
        .build()
        .map_err(|e| format!("cannot build an HTTP client: {e}"))?;

    let response = client
        .get(format!("https://{hostname}{DOH_PATH}"))
        .header("accept", "application/dns-message")
        // A `Date` served from a cache was stamped when the response was first generated and
        // says nothing about now. The `Age` check below is what enforces this; these ask
        // nicely first.
        .header("cache-control", "no-cache, no-store")
        .header("pragma", "no-cache")
        .send()
        .map_err(|e| format!("request to {address} failed: {e}"))?;

    let version = format!("{:?}", response.version());
    let (date, age) = extract(response.headers())?;

    // Pass 2, on the chain this very connection presented. Done here rather than by the caller
    // so no code path can read a Date without it.
    let chain = handshake_verifier
        .chain()
        .ok_or_else(|| format!("{address} completed no verified handshake"))?;
    let seconds = crate::httpdate::parse(&date)?;
    verifier.verify_at(&chain, &server_name, seconds)?;

    Ok(Response { date, age, version })
}

#[cfg(test)]
mod tests {
    use super::*;
    use reqwest::header::{HeaderMap, HeaderValue};

    fn headers(pairs: &[(&'static str, &str)]) -> HeaderMap {
        let mut map = HeaderMap::new();
        for (name, value) in pairs {
            map.insert(*name, HeaderValue::from_str(value).unwrap());
        }
        map
    }

    #[test]
    fn finds_the_date() {
        let map = headers(&[("date", "Sun, 06 Nov 1994 08:49:37 GMT")]);
        assert_eq!(
            extract(&map).unwrap(),
            ("Sun, 06 Nov 1994 08:49:37 GMT".to_string(), None)
        );
    }

    #[test]
    fn reports_a_missing_date_as_an_error() {
        // Two of the configured providers really do answer without one, so this is a normal
        // outcome that has to be reported precisely rather than defaulted around.
        assert!(extract(&headers(&[("server", "nginx")])).is_err());
    }

    #[test]
    fn treats_an_empty_date_as_missing() {
        assert!(extract(&headers(&[("date", "   ")])).is_err());
    }

    #[test]
    fn surfaces_age_when_present() {
        let map = headers(&[("date", "Sun, 06 Nov 1994 08:49:37 GMT"), ("age", "122")]);
        assert_eq!(extract(&map).unwrap().1.as_deref(), Some("122"));
    }

    #[test]
    fn header_lookup_is_case_insensitive() {
        // HeaderMap normalises, but the lookup keys here are literals and a typo'd case would
        // otherwise silently mean "absent".
        let map = headers(&[("DATE", "Sun, 06 Nov 1994 08:49:37 GMT")]);
        assert!(extract(&map).is_ok());
    }

    #[test]
    fn trims_surrounding_whitespace() {
        let map = headers(&[("date", " Sun, 06 Nov 1994 08:49:37 GMT ")]);
        assert_eq!(extract(&map).unwrap().0, "Sun, 06 Nov 1994 08:49:37 GMT");
    }
}
