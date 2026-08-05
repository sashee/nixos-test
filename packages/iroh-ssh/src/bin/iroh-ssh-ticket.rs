//! Print the endpoint's canonical connect ticket, derived from the secret key.
//!
//! Usage: iroh-ssh-ticket [secret-file]
//!
//! The ticket carries only the endpoint id -- no relay urls, no direct addresses
//! -- which makes it a pure function of the secret: no endpoint is bound, no
//! network is touched. That is the form operators distribute, because it stays
//! valid across relay changes, where a ticket with a relay url baked in stops
//! working once that relay goes away. The connecting side resolves the id
//! through discovery.
//!
//! The secret is read exactly as the listener reads it (see `load_secret`): the
//! argument as an explicit path, else the systemd credential, else
//! `$IROH_SECRET`. The service passes no argument.
//!
//! The path argument is for re-deriving a ticket when both the one printed at
//! generation time and `/run/iroh-ssh/ticket` are gone -- the latter happens
//! whenever the listener has not started this boot, which is exactly when an
//! operator most wants the ticket. It reads *plaintext* hex, so the encrypted
//! blob on a provisioned host has to be decrypted on the way in:
//!
//!   systemd-creds decrypt --name=iroh-secret \
//!     /etc/credentials/iroh-ssh/iroh-secret - | iroh-ssh-ticket /dev/stdin
//!
//! (a pipe, so the plaintext key never lands on disk).
use std::path::PathBuf;

use iroh_ssh::{id_ticket, load_secret};
use iroh_tickets::endpoint::EndpointTicket;
use n0_error::Result;

/// Derive the id-only ticket. Pure: same secret in, same ticket out, offline.
fn ticket(secret_file: Option<PathBuf>) -> Result<EndpointTicket> {
    Ok(id_ticket(&load_secret(secret_file)?))
}

fn main() -> ! {
    // No tokio runtime here on purpose: the derivation is synchronous, so this
    // binary stays usable in contexts that have no reactor (and no network).
    match ticket(std::env::args().nth(1).map(PathBuf::from)) {
        Ok(ticket) => {
            println!("{ticket}");
            std::process::exit(0)
        }
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1)
        }
    }
}
