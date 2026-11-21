//! Command line. Hand-parsed: a dozen flags do not need a parser crate running unconfined.

use std::path::PathBuf;

use crate::repo::{RepoId, parse_slug};

pub const USAGE: &str = "\
dep-report: how stale every dependency is, in this repository and the ones it pins that you own

usage: dep-report [options]

  --flake DIR           the checkout to start from (default: the current directory)
  --output FILE         where to write the report (default: DIR/results/dep-report.txt);
                        it is printed to stdout as well
  --owner NAME          GitHub owner whose repositories are entered; repeatable
                        (default: the owner of the checkout's origin remote)
  --root-repo O/R       the checkout's GitHub repository, when its origin remote does not say
  --transitive          also list every transitive crate `cargo update` would move, with dates
  --no-cache            ignore cached answers (they are still refreshed)
  --depth N             how deep to follow pins (default: 5)
  --no-bwrap            skip the bwrap layer (Landlock and seccomp still apply)
  --probe-sandbox       apply the sandbox, try what it must deny, and report; does no work
  -h, --help            this text

Pins are read at the commit they lock. GitHub is asked without a token (about 14 calls a run,
against 60 an hour); crates.io at most once a second. Answers are cached for 6 hours under
$XDG_CACHE_HOME/dep-report.
";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Options {
    pub flake: Option<PathBuf>,
    pub output: Option<PathBuf>,
    pub owners: Vec<String>,
    pub root_repo: Option<RepoId>,
    pub transitive: bool,
    pub no_cache: bool,
    pub depth: u32,
    pub no_bwrap: bool,
    pub probe_sandbox: bool,
    /// Set by the outer process when it re-executes itself inside bwrap: the resolved layout.
    pub layout: Option<String>,
}

impl Default for Options {
    fn default() -> Self {
        Options {
            flake: None,
            output: None,
            owners: Vec::new(),
            root_repo: None,
            transitive: false,
            no_cache: false,
            depth: 5,
            no_bwrap: false,
            probe_sandbox: false,
            layout: None,
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum Parsed {
    Help,
    Run(Options),
}

pub fn parse<I: IntoIterator<Item = String>>(args: I) -> Result<Parsed, String> {
    let mut opts = Options::default();
    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        let (flag, inline) = match arg.split_once('=') {
            Some((f, v)) if f.starts_with("--") => (f.to_string(), Some(v.to_string())),
            _ => (arg.clone(), None),
        };
        let mut value = |name: &str| inline.clone().or_else(|| args.next()).ok_or(format!("{name} needs a value"));
        match flag.as_str() {
            "-h" | "--help" => return Ok(Parsed::Help),
            "--flake" => opts.flake = Some(PathBuf::from(value("--flake")?)),
            "--output" => opts.output = Some(PathBuf::from(value("--output")?)),
            "--owner" => opts.owners.push(value("--owner")?),
            "--root-repo" => {
                let v = value("--root-repo")?;
                opts.root_repo = Some(parse_slug(&v).ok_or(format!("--root-repo: not OWNER/REPO: {v}"))?);
            }
            "--depth" => {
                let v = value("--depth")?;
                opts.depth = v.parse().map_err(|_| format!("--depth: not a number: {v}"))?;
            }
            "--layout" => opts.layout = Some(value("--layout")?),
            "--transitive" => opts.transitive = true,
            "--no-cache" => opts.no_cache = true,
            "--no-bwrap" => opts.no_bwrap = true,
            "--probe-sandbox" => opts.probe_sandbox = true,
            other => return Err(format!("unknown argument: {other} (see --help)")),
        }
    }
    Ok(Parsed::Run(opts))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(args: &[&str]) -> Result<Options, String> {
        match parse(args.iter().map(|s| s.to_string()))? {
            Parsed::Run(o) => Ok(o),
            Parsed::Help => Err("help".into()),
        }
    }

    #[test]
    fn flags() {
        let o = run(&["--flake", "/x", "--owner=a", "--owner", "b", "--transitive", "--depth=2", "--root-repo", "s/r"]).unwrap();
        assert_eq!(o.flake, Some(PathBuf::from("/x")));
        assert_eq!(o.owners, ["a", "b"]);
        assert!(o.transitive && !o.no_cache);
        assert_eq!(o.depth, 2);
        assert_eq!(o.root_repo, RepoId::new("s", "r"));
        assert_eq!(run(&[]).unwrap(), Options::default());
    }

    #[test]
    fn errors() {
        assert!(run(&["--depth", "x"]).is_err());
        assert!(run(&["--flake"]).is_err());
        assert!(run(&["--bogus"]).is_err());
        assert!(run(&["--root-repo", "nope"]).is_err());
        assert_eq!(parse(["--help".to_string()]).unwrap(), Parsed::Help);
    }
}
