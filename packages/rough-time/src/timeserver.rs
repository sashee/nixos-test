//! Leg two: key establishment with an NTS server, then one authenticated NTP exchange.
//!
//! Raw `rustls::ClientConnection` over a `TcpStream` rather than an HTTP client, because
//! NTS-KE is not HTTP -- it is a record stream in a TLS session with its own ALPN. That turns
//! out to be simpler than the DoH leg: the chain comes straight off `peer_certificates()`, so
//! none of the capture machinery the reqwest path needs applies here.
//!
//! Certificate time checks are deferred as on the other leg. The difference is what binds the
//! answer to the chain: on the DoH leg the resolver's answer arrives inside the TLS session, so
//! the session itself is the binding. Here the timestamp arrives afterwards over UDP, and the
//! binding is the AEAD key exported from the handshake -- only the holder of the private key
//! behind that chain can produce a packet that authenticates. Different argument, same
//! strength, and it is the reason `Deferred` exists rather than a local pass 2.

use std::io::{Read, Write};
use std::net::{IpAddr, SocketAddr, TcpStream, UdpSocket};
use std::sync::Arc;
use std::time::Duration;

use rustls::pki_types::ServerName;

use crate::deferred::Deferred;
use crate::nts;
use crate::ntp;
use crate::verify::{TimeAgnosticVerifier, Verifier};

const NTS_KE_PORT: u16 = 4460;
const DEFAULT_NTP_PORT: u16 = 123;
/// A key establishment response is a handful of cookies; anything at this scale is a peer
/// streaming to keep us busy.
const MAX_KE_RESPONSE: usize = 64 * 1024;

pub struct Keys {
    pub c2s: [u8; nts::KEY_LENGTH],
    pub s2c: [u8; nts::KEY_LENGTH],
}

pub struct Established {
    pub agreement: nts::Agreement,
    pub keys: Keys,
}

/// Do NTS-KE against `address`, presenting `hostname`, and record the chain for later checking.
pub fn establish(
    verifier: Arc<Verifier>,
    deferred: &mut Deferred,
    hostname: &str,
    address: IpAddr,
    timeout: Duration,
) -> Result<Established, String> {
    let server_name = ServerName::try_from(hostname.to_string())
        .map_err(|_| format!("{hostname} is not a valid server name"))?;

    let mut config = rustls::ClientConfig::builder_with_provider(verifier.crypto())
        .with_safe_default_protocol_versions()
        .map_err(|e| format!("cannot select TLS versions: {e}"))?
        .dangerous()
        .with_custom_certificate_verifier(TimeAgnosticVerifier::new(verifier.clone()))
        .with_no_client_auth();
    config.alpn_protocols = vec![nts::ALPN.to_vec()];

    let connection = rustls::ClientConnection::new(Arc::new(config), server_name.clone())
        .map_err(|e| format!("cannot start a TLS session with {hostname}: {e}"))?;

    let socket = TcpStream::connect_timeout(&SocketAddr::new(address, NTS_KE_PORT), timeout)
        .map_err(|e| format!("cannot connect to {address}:{NTS_KE_PORT}: {e}"))?;
    socket
        .set_read_timeout(Some(timeout))
        .and_then(|_| socket.set_write_timeout(Some(timeout)))
        .map_err(|e| format!("cannot set timeouts on {address}: {e}"))?;

    // StreamOwned drives the handshake lazily on the first write below.
    let mut stream = rustls::StreamOwned::new(connection, socket);
    stream
        .write_all(&nts::request(nts::AEAD_AES_SIV_CMAC_256))
        .and_then(|_| stream.flush())
        .map_err(|e| format!("cannot send the NTS-KE request to {address}: {e}"))?;

    // A server that did not agree to ntske/1 is not speaking this protocol, and whatever it
    // sends would be parsed as records if this were not checked.
    match stream.conn.alpn_protocol() {
        Some(nts::ALPN) => {}
        other => {
            return Err(format!(
                "{hostname} negotiated ALPN {:?}, not ntske/1",
                other.map(String::from_utf8_lossy)
            ))
        }
    }

    // Read until the response terminates itself, or the peer stops talking.
    //
    // A close without TLS close_notify is not an error here. chronyd answers and closes
    // immediately, and rustls surfaces that as UnexpectedEof -- which, if treated as fatal,
    // discards a response that has already arrived in full. It only shows up when the reply
    // spans more than one read, so it hid behind fast local networks and behind the real
    // servers' timing, and appeared the moment a test slowed the link down.
    let mut response = Vec::new();
    let mut chunk = [0u8; 4096];
    while !nts::response_complete(&response) {
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(read) => {
                response.extend_from_slice(&chunk[..read]);
                if response.len() > MAX_KE_RESPONSE {
                    return Err(format!("NTS-KE response exceeded {MAX_KE_RESPONSE} bytes"));
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(e) => {
                return Err(format!("cannot read the NTS-KE response from {address}: {e}"))
            }
        }
    }

    // Whether the peer closing was benign is decided here, on what actually arrived, rather
    // than on how the connection ended.
    if !nts::response_complete(&response) {
        return Err(format!("{address} closed the NTS-KE session before answering"));
    }

    let agreement = nts::parse_response(&response, nts::AEAD_AES_SIV_CMAC_256)?;

    let mut c2s = [0u8; nts::KEY_LENGTH];
    let mut s2c = [0u8; nts::KEY_LENGTH];
    for (buffer, client_to_server) in [(&mut c2s, true), (&mut s2c, false)] {
        stream
            .conn
            .export_keying_material(
                &mut buffer[..],
                nts::EXPORTER_LABEL,
                Some(&nts::exporter_context(agreement.aead, client_to_server)),
            )
            .map_err(|e| format!("cannot export NTS keys from the {hostname} session: {e}"))?;
    }

    // Straight off the connection: rustls only sets this after verification succeeded, so its
    // presence already means pass 1 passed.
    let chain: Vec<_> = stream
        .conn
        .peer_certificates()
        .ok_or_else(|| format!("{address} presented no certificates"))?
        .iter()
        .map(|c| c.clone().into_owned())
        .collect();
    deferred.record(&format!("NTS-KE {hostname}"), chain, server_name);

    Ok(Established {
        agreement,
        keys: Keys { c2s, s2c },
    })
}

/// Ask the (possibly redirected) time server for the time, authenticated with `keys`.
pub fn ask_time(
    established: &Established,
    address: IpAddr,
    port: u16,
    unique_id: [u8; ntp::UNIQUE_ID_LENGTH],
    nonce: [u8; ntp::NONCE_LENGTH],
    timeout: Duration,
) -> Result<i64, String> {
    let cookie = established
        .agreement
        .cookies
        .first()
        .ok_or_else(|| "no cookie to spend".to_string())?;

    let request = ntp::build_request(cookie, &established.keys.c2s, unique_id, nonce)?;

    let bind: SocketAddr = if address.is_ipv4() {
        "0.0.0.0:0".parse().expect("literal")
    } else {
        "[::]:0".parse().expect("literal")
    };
    let socket = UdpSocket::bind(bind).map_err(|e| format!("cannot open a UDP socket: {e}"))?;
    socket
        .set_read_timeout(Some(timeout))
        .map_err(|e| format!("cannot set a UDP timeout: {e}"))?;
    socket
        .connect(SocketAddr::new(address, port))
        .map_err(|e| format!("cannot reach {address}:{port}: {e}"))?;
    socket
        .send(&request.packet)
        .map_err(|e| format!("cannot send an NTP request to {address}: {e}"))?;

    let mut buffer = [0u8; 1024];
    let read = socket
        .recv(&mut buffer)
        .map_err(|e| format!("no NTP response from {address}:{port}: {e}"))?;

    ntp::parse_response(&buffer[..read], &established.keys.s2c, &request.unique_id)
}

/// Where the NTP exchange should go, honouring a server's redirect.
///
/// `nts.netnod.se` answers key establishment itself and hands timestamping to another host on a
/// non-default port, marking both records critical. When the redirect names an address there is
/// nothing further to resolve; when it names a host, the caller has to resolve it.
pub fn ntp_target(established: &Established, fallback: IpAddr) -> (Option<String>, IpAddr, u16) {
    let port = established.agreement.port.unwrap_or(DEFAULT_NTP_PORT);
    match &established.agreement.server {
        None => (None, fallback, port),
        Some(server) => match server.parse::<IpAddr>() {
            Ok(address) => (None, address, port),
            Err(_) => (Some(server.clone()), fallback, port),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn established(server: Option<&str>, port: Option<u16>) -> Established {
        Established {
            agreement: nts::Agreement {
                aead: nts::AEAD_AES_SIV_CMAC_256,
                cookies: vec![b"c".to_vec()],
                server: server.map(str::to_string),
                port,
            },
            keys: Keys {
                c2s: [0; nts::KEY_LENGTH],
                s2c: [0; nts::KEY_LENGTH],
            },
        }
    }

    #[test]
    fn without_a_redirect_the_key_server_is_the_time_server() {
        let fallback: IpAddr = "192.0.2.1".parse().unwrap();
        assert_eq!(
            ntp_target(&established(None, None), fallback),
            (None, fallback, 123)
        );
    }

    #[test]
    fn an_address_redirect_needs_no_further_resolution() {
        // The netnod shape: an IP literal and port 4123.
        let fallback: IpAddr = "192.0.2.1".parse().unwrap();
        assert_eq!(
            ntp_target(&established(Some("194.58.207.80"), Some(4123)), fallback),
            (None, "194.58.207.80".parse().unwrap(), 4123)
        );
    }

    #[test]
    fn a_hostname_redirect_is_handed_back_for_resolution() {
        let fallback: IpAddr = "192.0.2.1".parse().unwrap();
        let (name, address, port) =
            ntp_target(&established(Some("ts.example"), Some(4123)), fallback);
        assert_eq!(name.as_deref(), Some("ts.example"));
        assert_eq!((address, port), (fallback, 4123));
    }

    #[test]
    fn a_port_redirect_alone_still_applies() {
        let fallback: IpAddr = "192.0.2.1".parse().unwrap();
        assert_eq!(
            ntp_target(&established(None, Some(4123)), fallback),
            (None, fallback, 4123)
        );
    }
}
