//! Leg one: resolve a name through a DoH resolver, without a working clock and without a
//! working resolver.
//!
//! The resolver is dialled by pinned address with the hostname supplied for SNI and
//! verification, so this needs no DNS to do DNS. Certificate time checks are deferred exactly
//! as before; the chain is handed to the caller's `Deferred` rather than checked here, because
//! the time that would check it does not exist yet.
//!
//! The HTTP version is whatever the server negotiates. Two of the four configured providers
//! speak only HTTP/2, and an earlier hand-rolled HTTP/1.1 client silently lost them.

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use rustls::pki_types::ServerName;

use crate::deferred::Deferred;
use crate::dns;
use crate::verify::{TimeAgnosticVerifier, Verifier};

/// Resolve `name` to addresses using the DoH resolver at `address`, recording the resolver's
/// certificate chain for later validation.
#[allow(clippy::too_many_arguments)]
pub fn resolve(
    verifier: Arc<Verifier>,
    deferred: &mut Deferred,
    resolver_host: &str,
    resolver_address: IpAddr,
    name: &str,
    qtype: u16,
    query_id: u16,
    timeout: Duration,
) -> Result<Vec<IpAddr>, String> {
    let server_name = ServerName::try_from(resolver_host.to_string())
        .map_err(|_| format!("{resolver_host} is not a valid server name"))?;

    let handshake_verifier = TimeAgnosticVerifier::new(verifier.clone());

    let mut config = rustls::ClientConfig::builder_with_provider(verifier.crypto())
        .with_safe_default_protocol_versions()
        .map_err(|e| format!("cannot select TLS versions: {e}"))?
        .dangerous()
        .with_custom_certificate_verifier(handshake_verifier.clone())
        .with_no_client_auth();
    config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];

    let client = reqwest::blocking::Client::builder()
        .use_preconfigured_tls(config)
        .resolve(resolver_host, SocketAddr::new(resolver_address, 443))
        // A redirect would move the request to a host that was neither pinned nor verified.
        .redirect(reqwest::redirect::Policy::none())
        // A proxy would terminate TLS somewhere this cannot check.
        .no_proxy()
        .timeout(timeout)
        .connect_timeout(timeout)
        .build()
        .map_err(|e| format!("cannot build an HTTP client: {e}"))?;

    let query = dns::encode_query(query_id, name, qtype)?;

    // POST rather than the GET-with-base64url form: no encoding step, and no cache to worry
    // about, since RFC 8484 makes POST uncacheable by construction.
    let response = client
        .post(format!("https://{resolver_host}/dns-query"))
        .header("content-type", "application/dns-message")
        .header("accept", "application/dns-message")
        .body(query)
        .send()
        .map_err(|e| format!("DoH request to {resolver_address} failed: {e}"))?;

    if !response.status().is_success() {
        return Err(format!("DoH resolver answered {}", response.status()));
    }

    let body = response
        .bytes()
        .map_err(|e| format!("cannot read the DoH response: {e}"))?;

    let addresses = dns::parse_response(&body, query_id, qtype)?;

    // Recorded only after the answer is in hand, and only on success, so a leg that failed
    // cannot leave a chain behind that would make `accept` look better attested than it is.
    let chain = handshake_verifier
        .chain()
        .ok_or_else(|| format!("{resolver_address} completed no verified handshake"))?;
    deferred.record(&format!("DoH {resolver_host}"), chain, server_name);

    Ok(addresses)
}
