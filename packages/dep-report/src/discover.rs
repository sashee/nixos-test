//! The walk: scan the root checkout, then every repository it pins whose owner is on the
//! allowlist, at the pinned commit, recursively. Runs in the first sandbox stage because it
//! needs to run Nix (to fetch trees), Cargo (for `cargo update --dry-run`) and cargo-audit; it
//! makes no GitHub or crates.io API calls of its own.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::audit::{self, Finding};
use crate::cache::Cache;
use crate::cargo::{self, Change};
use crate::flake_lock::InputSource;
use crate::nix::{self, Archive};
use crate::repo::{RepoId, owner_allowed};
use crate::scan::{self, Findings};

#[derive(Debug)]
pub struct Tree {
    pub repo: RepoId,
    /// `None` for the root, which is scanned as checked out (tracked files, uncommitted edits
    /// included), not at a commit.
    pub rev: Option<String>,
    pub findings: Findings,
    /// One per `findings.cargo` entry, in the same order.
    pub cargo_runs: Vec<CargoRun>,
    pub children: Vec<Child>,
}

/// What Cargo's own tools say about one lockfile.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CargoRun {
    pub changes: Result<Vec<Change>, String>,
    pub audit: Result<Vec<Finding>, String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Via {
    Input { lock: String, name: String },
    Pin { file: String, line: usize },
}

#[derive(Debug)]
pub enum Node {
    Scanned(Box<Tree>),
    /// Already scanned at this commit, earlier in the report.
    SeeAbove,
    /// A pin of the root repository (pw-mgr's and media-store's dev tooling pins nixos-test).
    /// Walking it would scan the root again at an older commit.
    RootRepo,
    DepthLimit,
    Failed(String),
}

#[derive(Debug)]
pub struct Child {
    pub via: Via,
    pub node: Node,
}

/// Cache key for "the advisory database was fetched recently": within the TTL every audit runs
/// with `--no-fetch` instead of each one pulling the database again.
const ADVISORY_DB_FETCHED: &str = "cargo audit: advisory-db fetched";

pub struct CargoRunner<'a> {
    pub cargo: &'a Path,
    pub rustc: &'a Path,
    pub cargo_audit: &'a Path,
    pub cargo_home: PathBuf,
    /// An empty directory: Cargo reads `.cargo/config.toml` from its working directory up, and a
    /// config can name programs for it to run (credential providers).
    pub cwd: PathBuf,
    pub env: Vec<(String, String)>,
    pub cache: Cache,
}

impl CargoRunner<'_> {
    pub fn dry_run(&self, manifest: &Path) -> Result<Vec<Change>, String> {
        let key = format!("cargo update --dry-run --verbose|{}|{}", manifest.display(), self.rustc.display());
        if let Some(hit) = self.cache.get(&key) {
            return Ok(cargo::parse_update_output(&hit.body));
        }
        let mut cmd = Command::new(self.cargo);
        cmd.env_clear()
            .envs(self.env.iter().map(|(k, v)| (k, v)))
            .env("CARGO_HOME", &self.cargo_home)
            .env("RUSTC", self.rustc)
            .env("CARGO_TERM_COLOR", "never")
            .env("CARGO_NET_GIT_FETCH_WITH_CLI", "false")
            .current_dir(&self.cwd)
            .args(["update", "--dry-run", "--verbose", "--manifest-path"])
            .arg(manifest);
        let program = self.cargo.display().to_string();
        let out = cmd.output().map_err(|e| format!("{program}: {e}"))?;
        let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
        if !out.status.success() {
            let last = stderr.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("").trim().to_string();
            return Err(format!("cargo update --dry-run failed: {last}"));
        }
        self.cache.put(&key, 200, &stderr);
        Ok(cargo::parse_update_output(&stderr))
    }

    fn run_audit(&self, lockfile: &Path, fetch: bool) -> Result<String, String> {
        let mut cmd = Command::new(self.cargo_audit);
        cmd.env_clear()
            .envs(self.env.iter().map(|(k, v)| (k, v)))
            .env("CARGO_HOME", &self.cargo_home)
            .current_dir(&self.cwd)
            .args(["audit", "--json", "--color", "never", "--db"])
            .arg(self.cargo_home.join("advisory-db"))
            .arg("--file")
            .arg(lockfile);
        if !fetch {
            cmd.arg("--no-fetch");
        }
        let program = self.cargo_audit.display().to_string();
        let out = cmd.output().map_err(|e| format!("{program}: {e}"))?;
        // Exit status 1 means "found something"; whether it ran is told by the JSON.
        let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
        if audit::parse(&stdout).is_ok() {
            return Ok(stdout);
        }
        let stderr = String::from_utf8_lossy(&out.stderr);
        let last = stderr.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("").trim().to_string();
        Err(format!("cargo audit failed: {last}"))
    }

    /// RustSec findings for one lockfile. The advisory database is a git clone in CARGO_HOME,
    /// fetched from github.com over git, which GitHub's API quota does not count.
    pub fn audit(&self, lockfile: &Path) -> Result<Vec<Finding>, String> {
        let key = format!("cargo audit|{}", lockfile.display());
        if let Some(hit) = self.cache.get(&key) {
            return audit::parse(&hit.body);
        }
        let fresh = self.cache.get(ADVISORY_DB_FETCHED).is_some();
        // A database recorded as fresh but gone from disk: fetch after all.
        let json = self.run_audit(lockfile, !fresh).or_else(|e| if fresh { self.run_audit(lockfile, true) } else { Err(e) })?;
        self.cache.put(ADVISORY_DB_FETCHED, 200, "");
        self.cache.put(&key, 200, &json);
        audit::parse(&json)
    }
}

pub struct Walk<'a> {
    /// `Nix::fetch_tarball` in the program, a lookup table in the tests.
    pub fetch_tarball: &'a dyn Fn(&str) -> Result<PathBuf, String>,
    /// `CargoRunner::dry_run` in the program, given the workspace manifest.
    pub dry_run: &'a dyn Fn(&Path) -> Result<Vec<Change>, String>,
    /// `CargoRunner::audit` in the program, given the lockfile.
    pub audit: &'a dyn Fn(&Path) -> Result<Vec<Finding>, String>,
    pub root_repo: RepoId,
    pub owners: Vec<String>,
    pub max_depth: u32,
    pub log: &'a dyn Fn(&str),
}

impl Walk<'_> {
    pub fn run(&self, archive: &Archive) -> Tree {
        let mut visited = BTreeSet::new();
        self.visit(&archive.path, &self.root_repo, None, 0, Some(archive), &mut visited)
    }

    fn visit(&self, path: &Path, repo: &RepoId, rev: Option<&str>, depth: u32, archive: Option<&Archive>,
        visited: &mut BTreeSet<String>) -> Tree
    {
        (self.log)(&format!("scanning {}", label(repo, rev)));
        let findings = scan::scan(path);
        let cargo_runs = findings
            .cargo
            .iter()
            .map(|(rel, info)| {
                (self.log)(&format!("  cargo update --dry-run, cargo audit  {rel}"));
                CargoRun {
                    changes: info.as_ref().map_err(Clone::clone).and_then(|info| (self.dry_run)(&info.manifest)),
                    audit: (self.audit)(&path.join(rel)),
                }
            })
            .collect();
        let inputs = findings.flake_locks.iter().flat_map(|(lock, inputs)| {
            inputs.iter().flatten().filter_map(move |input| match &input.source {
                InputSource::GitHub { repo, rev, .. } => {
                    Some((Via::Input { lock: lock.clone(), name: input.name.clone() }, repo.clone(), rev.clone(), None))
                }
                _ => None,
            })
        });
        let pins = findings.pins.iter().map(|pin| {
            (Via::Pin { file: pin.file.clone(), line: pin.line }, pin.repo.clone(), pin.rev.clone(), pin.sha256.clone())
        });
        let wanted: Vec<_> = inputs.chain(pins).filter(|(_, repo, _, _)| owner_allowed(&self.owners, repo)).collect();
        let children = wanted
            .into_iter()
            .map(|(via, child_repo, child_rev, sha256)| {
                let node = self.child(&via, &child_repo, &child_rev, sha256.as_deref(), depth, archive, visited);
                Child { via, node }
            })
            .collect();
        Tree {
            repo: repo.clone(),
            rev: rev.map(str::to_string),
            findings,
            cargo_runs,
            children,
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn child(&self, via: &Via, repo: &RepoId, rev: &str, sha256: Option<&str>, depth: u32, archive: Option<&Archive>,
        visited: &mut BTreeSet<String>) -> Node
    {
        if repo.same(&self.root_repo) {
            return Node::RootRepo;
        }
        if !visited.insert(format!("{}@{rev}", repo.key())) {
            return Node::SeeAbove;
        }
        if depth + 1 > self.max_depth {
            return Node::DepthLimit;
        }
        // The root's own flake.lock inputs come from `nix flake archive`; anything deeper is a
        // tarball of the pinned commit.
        let from_archive = match (via, archive) {
            (Via::Input { lock, name }, Some(archive)) if lock == "flake.lock" => archive.inputs.get(name).cloned(),
            _ => None,
        };
        let path = match from_archive {
            Some(path) => Ok(path),
            None => {
                (self.log)(&format!("fetching {}", label(repo, Some(rev))));
                nix::fetch_tarball_expr(repo, rev, sha256).and_then(|expr| (self.fetch_tarball)(&expr))
            }
        };
        match path {
            Ok(path) => Node::Scanned(Box::new(self.visit(&path, repo, Some(rev), depth + 1, None, visited))),
            Err(e) => Node::Failed(e),
        }
    }
}

pub fn label(repo: &RepoId, rev: Option<&str>) -> String {
    match rev {
        Some(rev) => format!("{repo} @{}", crate::repo::short(rev)),
        None => format!("{repo} (working tree)"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::BTreeMap;
    use std::fs;

    fn write(base: &Path, rel: &str, text: &str) {
        let path = base.join(rel);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }

    fn lock_node(owner: &str, repo: &str, rev: &str) -> String {
        format!(r#"{{"flake":false,"locked":{{"lastModified":1794872590,"owner":"{owner}","repo":"{repo}","rev":"{rev}","type":"github"}},"original":{{"owner":"{owner}","repo":"{repo}","type":"github"}}}}"#)
    }

    fn pin(repo: &str, rev: &str) -> String {
        format!("fetchTarball \"https://github.com/sashee/{repo}/archive/{rev}.tar.gz\"\n")
    }

    #[test]
    fn walks_owned_pins_once_and_never_the_root() {
        let base = std::env::temp_dir().join(format!("dep-report-walk-{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        let (e, x, y) = ("e".repeat(40), "1".repeat(40), "2".repeat(40));
        write(&base, "root/flake.lock", &format!(
            r#"{{"root":"root","version":7,"nodes":{{"root":{{"inputs":{{"pw-mgr":"pw-mgr","media-store":"media-store","nixpkgs":"nixpkgs_2"}}}},
            "pw-mgr":{},"media-store":{},"nixpkgs_2":{}}}}}"#,
            lock_node("sashee", "pw-mgr", &"a".repeat(40)), lock_node("sashee", "media-store", &"b".repeat(40)),
            lock_node("NixOS", "nixpkgs", &"c".repeat(40))));
        write(&base, "pw/nix/e2ee-store.nix", &pin("e2ee-store", &e));
        write(&base, "pw/nix/iroh-ssh.nix", &pin("nixos-test", &x));
        write(&base, "media/nix/e2ee-store.nix", &pin("e2ee-store", &e));
        write(&base, "media/nix/iroh-ssh.nix", &pin("nixos-test", &y));
        write(&base, "e2ee/backend/README", "");

        let archive = Archive {
            path: base.join("root"),
            inputs: BTreeMap::from([("pw-mgr".to_string(), base.join("pw")), ("media-store".to_string(), base.join("media")),
                ("nixpkgs".to_string(), base.join("nixpkgs"))]),
        };
        let fetched = RefCell::new(Vec::new());
        let fetch = |expr: &str| -> Result<PathBuf, String> {
            fetched.borrow_mut().push(expr.to_string());
            if expr.contains(&format!("sashee/e2ee-store/archive/{e}")) { Ok(base.join("e2ee")) } else { Err("unexpected".into()) }
        };
        let dry_run = |_: &Path| -> Result<Vec<Change>, String> { Ok(Vec::new()) };
        let audit = |_: &Path| -> Result<Vec<Finding>, String> { Ok(Vec::new()) };
        let walk = Walk {
            fetch_tarball: &fetch,
            dry_run: &dry_run,
            audit: &audit,
            root_repo: RepoId::new("sashee", "nixos-test").unwrap(),
            owners: vec!["sashee".into()],
            max_depth: 5,
            log: &|_| {},
        };
        let tree = walk.run(&archive);

        let names: Vec<_> = tree.children.iter().map(|c| match &c.via { Via::Input { name, .. } => name.clone(), Via::Pin { file, .. } => file.clone() }).collect();
        assert_eq!(names, ["media-store", "pw-mgr"], "third-party inputs are reported, not entered");
        let Node::Scanned(media) = &tree.children[0].node else { panic!() };
        let Node::Scanned(pw) = &tree.children[1].node else { panic!() };
        let kinds = |t: &Tree| -> Vec<(String, &'static str)> {
            t.children.iter().map(|c| (match &c.via { Via::Pin { file, .. } => file.clone(), Via::Input { name, .. } => name.clone() }, match c.node {
                Node::Scanned(_) => "scanned", Node::SeeAbove => "see above", Node::RootRepo => "root",
                Node::DepthLimit => "depth", Node::Failed(_) => "failed" })).collect()
        };
        assert_eq!(kinds(media), [("nix/e2ee-store.nix".into(), "scanned"), ("nix/iroh-ssh.nix".into(), "root")]);
        assert_eq!(kinds(pw), [("nix/e2ee-store.nix".into(), "see above"), ("nix/iroh-ssh.nix".into(), "root")]);
        assert_eq!(fetched.borrow().len(), 1, "e2ee-store is fetched once; root pins are never fetched");
        fs::remove_dir_all(&base).unwrap();
    }
}
