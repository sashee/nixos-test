//! Establish a rough system clock at boot, so that everything downstream which needs TLS can
//! work at all.
//!
//! The hosts in this repo resolve names over DoH and synchronise time over NTS. Both are TLS,
//! so a clock outside certificate validity blocks name resolution and time synchronisation at
//! once, and neither can recover the other. A Raspberry Pi with no RTC battery starts in
//! exactly that state on every cold boot.
//!
//! So: ask two of the configured DoH providers what time it is over HTTPS, believe them only
//! if they agree, and step the clock. The answer is a seed, not a time source -- it only has
//! to land inside certificate validity. chrony takes over from there and is authoritative.
//!
//! Runs as a systemd oneshot that restarts until it succeeds (see `modules/time-sync.nix`).
//! A failed run exits non-zero and is retried, which keeps the failure visible in
//! `systemctl status` rather than hidden in an internal retry loop.

mod fetch;
mod httpdate;
mod quorum;
mod verify;

use std::io::Read;
use std::net::IpAddr;
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use quorum::Answer;

#[derive(Debug, Clone)]
struct Provider {
    name: String,
    hostname: String,
    addresses: Vec<IpAddr>,
}

struct Options {
    providers: Vec<Provider>,
    sample: usize,
    tolerance: i64,
    floor: i64,
    only: Option<Vec<String>>,
    timeout: Duration,
    force: bool,
    dry_run: bool,
}

const USAGE: &str = "\
usage: rough-time [options]

  --provider NAME=HOSTNAME@ADDR[,ADDR]  a DoH provider to ask; repeatable. The addresses are
                                        dialled directly and the hostname is used for SNI and
                                        certificate verification -- nothing here resolves names
  --sample N                            how many providers to ask (default: 2). They must all
                                        answer and agree
  --tolerance SECONDS                   how far apart two answers may be (default: 60)
  --floor EPOCH                         refuse any time earlier than this (default: 0)
  --only NAME[,NAME]                    ask exactly these providers instead of sampling; for
                                        tests, which need the choice to be deterministic
  --timeout SECONDS                     per-connection connect and read timeout (default: 10)
  --force                               ask the providers even if the clock is already
                                        synchronised. With --dry-run, this is how to check
                                        that the configured providers still answer usably on
                                        a host whose clock is fine
  --dry-run                             report the decision without touching the clock
  --help                                this text
";

fn parse_provider(spec: &str) -> Result<Provider, String> {
    let (name, rest) = spec
        .split_once('=')
        .ok_or_else(|| format!("provider {spec:?} is not NAME=HOSTNAME@ADDR[,ADDR]"))?;
    let (hostname, addresses) = rest
        .split_once('@')
        .ok_or_else(|| format!("provider {spec:?} has no @ADDR list"))?;

    if name.is_empty() {
        return Err(format!("provider {spec:?} has an empty name"));
    }
    if hostname.is_empty() {
        return Err(format!("provider {spec:?} has an empty hostname"));
    }

    let addresses: Vec<IpAddr> = addresses
        .split(',')
        .filter(|a| !a.is_empty())
        .map(|a| {
            a.parse::<IpAddr>()
                .map_err(|_| format!("provider {name}: {a:?} is not an IP address"))
        })
        .collect::<Result<_, _>>()?;

    if addresses.is_empty() {
        return Err(format!("provider {name} has no addresses"));
    }

    Ok(Provider {
        name: name.to_string(),
        hostname: hostname.to_string(),
        addresses,
    })
}

fn parse_args(args: impl Iterator<Item = String>) -> Result<Option<Options>, String> {
    let mut options = Options {
        providers: Vec::new(),
        sample: 2,
        tolerance: 60,
        floor: 0,
        only: None,
        timeout: Duration::from_secs(10),
        force: false,
        dry_run: false,
    };

    let mut args = args;
    while let Some(arg) = args.next() {
        let mut value = |name: &str| -> Result<String, String> {
            args.next().ok_or_else(|| format!("{name} needs a value"))
        };
        match arg.as_str() {
            "--help" | "-h" => return Ok(None),
            "--provider" => options.providers.push(parse_provider(&value("--provider")?)?),
            "--sample" => {
                options.sample = value("--sample")?
                    .parse()
                    .map_err(|_| "--sample needs a number".to_string())?
            }
            "--tolerance" => {
                options.tolerance = value("--tolerance")?
                    .parse()
                    .map_err(|_| "--tolerance needs a number".to_string())?
            }
            "--floor" => {
                options.floor = value("--floor")?
                    .parse()
                    .map_err(|_| "--floor needs a number".to_string())?
            }
            "--timeout" => {
                let seconds: u64 = value("--timeout")?
                    .parse()
                    .map_err(|_| "--timeout needs a number".to_string())?;
                options.timeout = Duration::from_secs(seconds);
            }
            "--only" => {
                options.only = Some(
                    value("--only")?
                        .split(',')
                        .filter(|s| !s.is_empty())
                        .map(str::to_string)
                        .collect(),
                )
            }
            "--force" => options.force = true,
            "--dry-run" => options.dry_run = true,
            other => return Err(format!("unknown argument {other:?}")),
        }
    }

    if options.providers.is_empty() {
        return Err("no --provider given".to_string());
    }
    if options.sample == 0 {
        return Err("--sample must be at least 1".to_string());
    }
    if options.sample > options.providers.len() {
        return Err(format!(
            "--sample {} exceeds the {} configured providers",
            options.sample,
            options.providers.len()
        ));
    }
    if let Some(only) = &options.only {
        if only.is_empty() {
            return Err("--only needs at least one name".to_string());
        }
        for name in only {
            if !options.providers.iter().any(|p| &p.name == name) {
                return Err(format!("--only names {name:?}, which is not configured"));
            }
        }
    }

    Ok(Some(options))
}

/// True when the kernel reports the clock as disciplined, in which case an authenticated
/// source already owns it and a `Date` header must not overwrite it.
///
/// `STA_UNSYNC` is the kernel's own answer rather than a proxy for it: it is clear only
/// because something synchronised the clock and told the kernel so, which chrony does and this
/// program does not. Asking the kernel keeps the check independent of *which* daemon is
/// running and of any marker file we might write about ourselves.
///
/// This can never be true because of a previous run of this program: `ntp_clear()`, which the
/// kernel calls from `do_settimeofday64()`, re-sets `STA_UNSYNC` on every clock step. "Rough
/// time set" and "synchronised" therefore stay distinct states, which is what makes the check
/// meaningful at all.
fn clock_is_disciplined() -> bool {
    // SAFETY: the one raw call in this crate. `adjtimex` reads the caller's `timex` and writes
    // its result back into it; `modes = 0` makes that a pure query, so no other field is
    // interpreted as a request. `timex` is a plain struct of integers, so an all-zero value is
    // valid, and `buf` is uniquely owned by this frame for the whole call, so the pointer is
    // valid and non-aliased. rustix 1.x does not bind adjtimex and the crates that do are
    // unvetted, so AGENTS.md's no-unsafe preference yields to interoperability here.
    let mut buf: libc::timex = unsafe { std::mem::zeroed() };
    let result = unsafe { libc::adjtimex(&mut buf) };

    // A negative return is a failed call, not evidence of a good clock. Otherwise read the bit
    // directly rather than comparing the return against TIME_ERROR: TIME_ERROR also covers
    // STA_CLOCKERR, and it is specifically "nothing has synchronised this clock" we care about.
    result >= 0 && (buf.status & libc::STA_UNSYNC) == 0
}

fn set_clock(seconds: i64) -> Result<(), String> {
    use rustix::time::{clock_settime, ClockId, Timespec};

    clock_settime(
        ClockId::Realtime,
        Timespec {
            tv_sec: seconds,
            tv_nsec: 0,
        },
    )
    .map_err(|e| format!("cannot set the clock: {e}"))
}

fn seed() -> u64 {
    // /dev/urandom rather than a time-derived seed, for the obvious reason.
    let mut bytes = [0u8; 8];
    match std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut bytes)) {
        Ok(()) => u64::from_ne_bytes(bytes),
        // Not fatal. A fixed seed still draws distinct providers; it only makes which two
        // predictable, and an attacker who knows the pair still has to compromise both.
        Err(e) => {
            eprintln!("warning: cannot read /dev/urandom ({e}); falling back to a fixed draw");
            0
        }
    }
}

fn collect_answers(options: &Options, chosen: &[Provider]) -> Vec<Answer> {
    let verifier = match verify::Verifier::new(Arc::new(rustls::crypto::ring::default_provider()))
    {
        Ok(v) => v,
        Err(e) => {
            eprintln!("error: {e}");
            return Vec::new();
        }
    };

    // One thread per address, so an unreachable endpoint costs the timeout once rather than
    // once per provider in series. A v4-only host has every IPv6 address time out, and that
    // must not add up to a boot delay.
    //
    // Flattened into (name, hostname, address) up front: building the list inside nested
    // closures would move the shared Arcs out of an FnMut, which does not borrow-check.
    let tasks: Vec<(String, String, IpAddr)> = chosen
        .iter()
        .flat_map(|provider| {
            provider
                .addresses
                .iter()
                .map(|address| (provider.name.clone(), provider.hostname.clone(), *address))
        })
        .collect();

    std::thread::scope(|scope| {
        let handles: Vec<_> = tasks
            .into_iter()
            .map(|(name, hostname, address)| {
                let verifier = verifier.clone();
                let timeout = options.timeout;

                scope.spawn(move || {
                    let outcome = fetch::probe(verifier, &hostname, address, timeout);
                    (name, address, outcome)
                })
            })
            .collect();

        handles
            .into_iter()
            .filter_map(|handle| {
                let (name, address, outcome) = handle.join().ok()?;
                match outcome {
                    Ok(response) => {
                        if let Some(age) = response.age {
                            // A cached response was stamped when it was first generated, which
                            // may be arbitrarily long ago. Dropping it is safer than trusting
                            // it: the remaining provider then fails the quorum and we retry.
                            eprintln!(
                                "{name} via {address}: ignoring a response served from a cache (Age: {age})"
                            );
                            return None;
                        }
                        let seconds = match httpdate::parse(&response.date) {
                            Ok(seconds) => seconds,
                            Err(e) => {
                                eprintln!("{name} via {address}: {e}");
                                return None;
                            }
                        };
                        eprintln!(
                            "{name} via {address}: {} ({seconds}) over {}",
                            response.date, response.version
                        );
                        Some(Answer {
                            provider: name,
                            endpoint: address.to_string(),
                            seconds,
                        })
                    }
                    Err(e) => {
                        eprintln!("{name} via {address}: {e}");
                        None
                    }
                }
            })
            .collect()
    })
}

fn run(options: Options) -> Result<(), String> {
    if !options.force && clock_is_disciplined() {
        println!("the clock is already synchronised; leaving it alone");
        return Ok(());
    }

    let names: Vec<String> = options.providers.iter().map(|p| p.name.clone()).collect();
    let sampled = match &options.only {
        Some(only) => only.clone(),
        None => quorum::sample(&names, options.sample, seed()),
    };

    let chosen: Vec<Provider> = options
        .providers
        .iter()
        .filter(|p| sampled.contains(&p.name))
        .cloned()
        .collect();

    eprintln!("asking {}", sampled.join(", "));

    let answers = collect_answers(&options, &chosen);
    let seconds = quorum::decide(&sampled, &answers, options.tolerance, options.floor)?;

    if options.dry_run {
        println!("would set the clock to {seconds}");
        return Ok(());
    }

    set_clock(seconds)?;
    println!("clock set to {seconds}");
    Ok(())
}

fn main() -> ExitCode {
    match parse_args(std::env::args().skip(1)) {
        Ok(None) => {
            print!("{USAGE}");
            ExitCode::SUCCESS
        }
        Ok(Some(options)) => match run(options) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("error: {e}");
                ExitCode::FAILURE
            }
        },
        Err(e) => {
            eprintln!("error: {e}\n\n{USAGE}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    fn parse(items: &[&str]) -> Result<Option<Options>, String> {
        parse_args(args(items).into_iter())
    }

    const ONE: &str = "--provider";
    const CF: &str = "cloudflare=cloudflare-dns.com@1.1.1.1,2606:4700:4700::1111";
    const Q9: &str = "quad9=dns10.quad9.net@9.9.9.10";

    #[test]
    fn parses_a_provider_with_both_families() {
        let options = parse(&[ONE, CF, ONE, Q9]).unwrap().unwrap();
        assert_eq!(options.providers.len(), 2);
        assert_eq!(options.providers[0].name, "cloudflare");
        assert_eq!(options.providers[0].hostname, "cloudflare-dns.com");
        assert_eq!(options.providers[0].addresses.len(), 2);
        assert_eq!(options.providers[1].addresses.len(), 1);
    }

    #[test]
    fn defaults_match_the_documented_ones() {
        let options = parse(&[ONE, CF, ONE, Q9]).unwrap().unwrap();
        assert_eq!(options.sample, 2);
        assert_eq!(options.tolerance, 60);
        assert_eq!(options.floor, 0);
        assert_eq!(options.timeout, Duration::from_secs(10));
        assert!(!options.dry_run);
        assert!(options.only.is_none());
    }

    #[test]
    fn rejects_malformed_provider_specs() {
        for spec in [
            "cloudflare",                        // no =
            "cloudflare=cloudflare-dns.com",     // no @
            "=cloudflare-dns.com@1.1.1.1",       // empty name
            "cloudflare=@1.1.1.1",               // empty hostname
            "cloudflare=cloudflare-dns.com@",    // no addresses
            "cloudflare=cloudflare-dns.com@nope", // not an address
        ] {
            assert!(parse(&[ONE, spec]).is_err(), "{spec:?} should be rejected");
        }
    }

    #[test]
    fn requires_at_least_one_provider() {
        assert!(parse(&[]).is_err());
    }

    #[test]
    fn rejects_a_sample_larger_than_the_pool() {
        assert!(parse(&[ONE, CF, "--sample", "2"]).is_err());
        assert!(parse(&[ONE, CF, "--sample", "0"]).is_err());
        assert!(parse(&[ONE, CF, ONE, Q9, "--sample", "2"]).is_ok());
    }

    #[test]
    fn rejects_only_naming_an_unconfigured_provider() {
        // Left unchecked this would silently sample nothing and report "did not answer",
        // which points at the network rather than at the typo.
        assert!(parse(&[ONE, CF, ONE, Q9, "--only", "google"]).is_err());
        assert!(parse(&[ONE, CF, ONE, Q9, "--only", ""]).is_err());
        assert!(parse(&[ONE, CF, ONE, Q9, "--only", "quad9"]).is_ok());
    }

    #[test]
    fn rejects_unknown_arguments_and_missing_values() {
        assert!(parse(&[ONE, CF, "--nope"]).is_err());
        assert!(parse(&[ONE, CF, "--tolerance"]).is_err());
        assert!(parse(&[ONE, CF, "--tolerance", "soon"]).is_err());
        assert!(parse(&[ONE]).is_err());
    }

    #[test]
    fn force_is_off_by_default() {
        // A default-on --force would make the service overwrite a chrony-disciplined clock on
        // every boot, which is the one thing the adjtimex check exists to prevent.
        assert!(!parse(&[ONE, CF, ONE, Q9]).unwrap().unwrap().force);
        assert!(parse(&[ONE, CF, ONE, Q9, "--force"]).unwrap().unwrap().force);
    }

    #[test]
    fn help_short_circuits_before_validation() {
        // --help must work without a valid configuration, or it is useless for finding out
        // what a valid configuration looks like.
        assert!(parse(&["--help"]).unwrap().is_none());
    }

    #[test]
    fn accepts_a_negative_floor_but_not_a_word() {
        assert_eq!(
            parse(&[ONE, CF, ONE, Q9, "--floor", "0"]).unwrap().unwrap().floor,
            0
        );
        assert!(parse(&[ONE, CF, ONE, Q9, "--floor", "yesterday"]).is_err());
    }
}
