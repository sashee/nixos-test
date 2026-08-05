//! Generate a fresh iroh secret key. The secret (lowercase hex) goes to stdout
//! so it can be piped straight into `systemd-creds encrypt`; a ready-to-use
//! connect command for the resulting endpoint goes to stderr so it doesn't
//! corrupt that pipe but the operator can configure the client side right
//! away. The ticket carries only the endpoint id (the key is not online yet,
//! so there are no addresses to embed); the connecting side resolves it via
//! discovery. That is the canonical form, so it is byte-identical to what the
//! provisioned host publishes at /run/iroh-ssh/ticket -- both derive it with
//! `id_ticket`. The running listener also logs tickets embedding its live relay
//! urls, which pin the client to a relay that may later go away.
//!
//! Usage: iroh-ssh-generate-secret
//!   iroh-ssh-generate-secret | systemd-creds encrypt --name=iroh-secret - <path>
//!
//! Using iroh's own key generator keeps the key correctly sized for whatever
//! iroh version is compiled in, rather than hardcoding a byte count.
use iroh::SecretKey;
use iroh_ssh::id_ticket;

fn main() {
    let key = SecretKey::generate();
    let secret: String = key.to_bytes().iter().map(|b| format!("{b:02x}")).collect();
    let ticket = id_ticket(&key);
    eprintln!("connect with e.g.:");
    eprintln!("ssh -o ProxyCommand='iroh-ssh-connect {ticket}' <user>@<any-name>");
    println!("{secret}");
}
