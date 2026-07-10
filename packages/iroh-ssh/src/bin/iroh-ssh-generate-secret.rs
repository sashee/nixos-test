//! Generate a fresh iroh secret key. The secret (lowercase hex) goes to stdout
//! so it can be piped straight into `systemd-creds encrypt`; the endpoint id
//! goes to stderr so it doesn't corrupt that pipe but the operator still sees
//! the node's identity.
//!
//! Usage: iroh-ssh-generate-secret
//!   iroh-ssh-generate-secret | systemd-creds encrypt --name=iroh-secret - <path>
//!
//! Using iroh's own key generator keeps the key correctly sized for whatever
//! iroh version is compiled in, rather than hardcoding a byte count.
use iroh::SecretKey;

fn main() {
    let key = SecretKey::generate();
    let secret: String = key.to_bytes().iter().map(|b| format!("{b:02x}")).collect();
    eprintln!("endpoint id: {}", key.public());
    println!("{secret}");
}
