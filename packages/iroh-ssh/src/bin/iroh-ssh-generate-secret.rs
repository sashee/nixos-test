//! Generate a fresh iroh secret key. The secret (lowercase hex) goes to stdout
//! so it can be piped straight into `systemd-creds encrypt`; a ready-to-use
//! connect command for the resulting endpoint goes to stderr so it doesn't
//! corrupt that pipe but the operator can configure the client side right
//! away. The ticket carries only the endpoint id (the key is not online yet,
//! so there are no addresses to embed); the connecting side resolves it via
//! relay discovery. The running listener also logs a ticket that embeds its
//! live relay urls.
//!
//! Usage: iroh-ssh-generate-secret
//!   iroh-ssh-generate-secret | systemd-creds encrypt --name=iroh-secret - <path>
//!
//! Using iroh's own key generator keeps the key correctly sized for whatever
//! iroh version is compiled in, rather than hardcoding a byte count.
use iroh::{EndpointAddr, SecretKey};
use iroh_tickets::endpoint::EndpointTicket;

fn main() {
    let key = SecretKey::generate();
    let secret: String = key.to_bytes().iter().map(|b| format!("{b:02x}")).collect();
    let ticket = EndpointTicket::from(EndpointAddr::new(key.public()));
    eprintln!("connect with e.g.:");
    eprintln!("ssh -o ProxyCommand='iroh-ssh-connect {ticket}' <user>@<any-name>");
    println!("{secret}");
}
