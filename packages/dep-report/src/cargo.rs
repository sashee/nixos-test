//! Cargo workspaces: which crates.io crates are direct dependencies and at what locked version,
//! and what `cargo update --dry-run --verbose` says it would change.
//!
//! "What `cargo update` would take" is Cargo's answer, not a re-derivation from `Cargo.toml`
//! requirements: Cargo.lock holds no requirements for transitive crates, and the edition-2024
//! resolver also holds versions back for `rust-version`/the toolchain, which a requirement match
//! cannot see (a dry run on system-metrics showed `itertools 0.14.0 -> 0.15.0`, a 0.x bump a
//! caret rule would call breaking).

use std::collections::BTreeSet;

use serde::Deserialize;
use toml::{Table, Value};

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct LockPkg {
    pub name: String,
    pub version: String,
    #[serde(default)]
    pub source: Option<String>,
    #[serde(default)]
    pub dependencies: Vec<String>,
}

#[derive(Deserialize)]
struct LockFile {
    #[serde(default)]
    package: Vec<LockPkg>,
}

pub fn parse_lock(text: &str) -> Result<Vec<LockPkg>, String> {
    toml::from_str::<LockFile>(text).map(|l| l.package).map_err(|e| format!("Cargo.lock: {e}"))
}

pub fn is_crates_io(source: &str) -> bool {
    source == "registry+https://github.com/rust-lang/crates.io-index" || source == "sparse+https://index.crates.io/"
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum DepSource {
    CratesIo,
    Path,
    Git(String),
    OtherRegistry(String),
}

/// One dependency declaration of one workspace member.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct DepSpec {
    pub member: String,
    /// The crate's real name (`package = ...` when renamed).
    pub name: String,
    pub source: DepSource,
}

const DEP_TABLES: [&str; 5] = ["dependencies", "dev-dependencies", "dev_dependencies", "build-dependencies",
    "build_dependencies"];

/// Every dependency a member manifest declares, across normal/dev/build and target-specific
/// sections, with `workspace = true` entries resolved against `[workspace.dependencies]`.
pub fn dep_specs(member: &str, manifest: &Table, workspace_deps: Option<&Table>) -> Vec<DepSpec> {
    let top = DEP_TABLES.iter().filter_map(|t| manifest.get(*t));
    let targets = manifest.get("target").and_then(Value::as_table).into_iter().flat_map(|targets| {
        targets.values().filter_map(Value::as_table).flat_map(|t| DEP_TABLES.iter().filter_map(|n| t.get(*n)))
    });
    let mut specs: Vec<DepSpec> = top
        .chain(targets)
        .filter_map(Value::as_table)
        .flat_map(|table| table.iter())
        .map(|(key, value)| {
            let inherited = value.get("workspace").and_then(Value::as_bool) == Some(true);
            let base = if inherited { workspace_deps.and_then(|ws| ws.get(key)) } else { Some(value) };
            spec_from(member, key, value, base)
        })
        .collect();
    specs.sort();
    specs.dedup();
    specs
}

fn spec_from(member: &str, key: &str, local: &Value, base: Option<&Value>) -> DepSpec {
    let field = |name: &str| -> Option<&Value> { local.get(name).or_else(|| base.and_then(|b| b.get(name))) };
    let name = field("package").and_then(Value::as_str).unwrap_or(key).to_string();
    let source = if let Some(git) = field("git").and_then(Value::as_str) {
        DepSource::Git(git.to_string())
    } else if field("path").is_some() {
        DepSource::Path
    } else if let Some(registry) = field("registry").and_then(Value::as_str) {
        DepSource::OtherRegistry(registry.to_string())
    } else {
        DepSource::CratesIo
    };
    DepSpec { member: member.to_string(), name, source }
}

/// `[workspace] members` patterns and `exclude`s, or none for a single-package manifest.
pub fn workspace_members(root: &Table) -> (Vec<String>, Vec<String>) {
    let list = |key: &str| -> Vec<String> {
        root.get("workspace")
            .and_then(|w| w.get(key))
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect())
            .unwrap_or_default()
    };
    (list("members"), list("exclude"))
}

pub fn package_name(manifest: &Table) -> Option<String> {
    manifest.get("package")?.get("name")?.as_str().map(str::to_string)
}

/// Shell-style match of one path component against a pattern with `*` and `?`.
pub fn wildcard_match(pattern: &str, name: &str) -> bool {
    fn go(p: &[u8], n: &[u8]) -> bool {
        match (p.first(), n.first()) {
            (None, None) => true,
            (Some(b'*'), _) => go(&p[1..], n) || (!n.is_empty() && go(p, &n[1..])),
            (Some(b'?'), Some(_)) => go(&p[1..], &n[1..]),
            (Some(a), Some(b)) if a == b => go(&p[1..], &n[1..]),
            _ => false,
        }
    }
    go(pattern.as_bytes(), name.as_bytes())
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct DirectDep {
    pub name: String,
    pub locked: String,
}

/// The locked version of every crates.io dependency the members declare. A member's own
/// `[[package]]` entry in Cargo.lock names each dependency, with a version exactly when more than
/// one version of that crate is locked, so this resolves duplicates (e2ee-store locks three
/// `getrandom`s) the way Cargo did, not by guessing from the name.
pub fn resolve_direct(specs: &[DepSpec], lock: &[LockPkg]) -> (Vec<DirectDep>, Vec<String>) {
    let mut found = BTreeSet::new();
    let mut unresolved = BTreeSet::new();
    for spec in specs.iter().filter(|s| s.source == DepSource::CratesIo) {
        let member = lock.iter().find(|p| p.name == spec.member && p.source.is_none());
        let entry = member.and_then(|m| {
            m.dependencies.iter().find(|d| d.split_whitespace().next() == Some(spec.name.as_str()))
        });
        let version = entry.and_then(|entry| match entry.split_whitespace().nth(1) {
            Some(version) => Some(version.to_string()),
            None => {
                let mut candidates =
                    lock.iter().filter(|p| p.name == spec.name && p.source.as_deref().is_some_and(is_crates_io));
                match (candidates.next(), candidates.next()) {
                    (Some(only), None) => Some(only.version.clone()),
                    _ => None,
                }
            }
        });
        match version {
            Some(locked) => {
                found.insert(DirectDep { name: spec.name.clone(), locked });
            }
            None => {
                unresolved.insert(spec.name.clone());
            }
        }
    }
    (found.into_iter().collect(), unresolved.into_iter().collect())
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Change {
    Update { name: String, from: String, to: String },
    Downgrade { name: String, from: String, to: String },
    Add { name: String, version: String },
    Remove { name: String, version: String },
    /// Kept at `at` although `available` exists: outside a requirement, or held back for the
    /// toolchain.
    Unchanged { name: String, at: String, available: String },
}

impl Change {
    pub fn name(&self) -> &str {
        match self {
            Change::Update { name, .. }
            | Change::Downgrade { name, .. }
            | Change::Add { name, .. }
            | Change::Remove { name, .. }
            | Change::Unchanged { name, .. } => name,
        }
    }
}

fn version_token(token: &str) -> Option<String> {
    let v = token.strip_prefix('v')?;
    v.starts_with(|c: char| c.is_ascii_digit()).then(|| v.trim_end_matches(',').to_string())
}

/// The `Updating x v1 -> v2` / `Adding` / `Removing` / `Unchanged x v1 (available: v2)` lines of
/// `cargo update --dry-run --verbose` (Cargo writes them to stderr).
pub fn parse_update_output(text: &str) -> Vec<Change> {
    text.lines()
        .filter_map(|line| {
            let tokens: Vec<&str> = line.split_whitespace().collect();
            let name = || tokens.get(1).map(|n| n.to_string());
            let version = |i: usize| tokens.get(i).and_then(|t| version_token(t));
            match tokens.first().copied()? {
                verb @ ("Updating" | "Downgrading") if tokens.get(3) == Some(&"->") => {
                    let (name, from, to) = (name()?, version(2)?, version(4)?);
                    Some(if verb == "Updating" {
                        Change::Update { name, from, to }
                    } else {
                        Change::Downgrade { name, from, to }
                    })
                }
                "Adding" => Some(Change::Add { name: name()?, version: version(2)? }),
                "Removing" => Some(Change::Remove { name: name()?, version: version(2)? }),
                "Unchanged" => {
                    let available = line.split("available: ").nth(1).and_then(|rest| {
                        version_token(rest.split(|c: char| c == ')' || c == ',' || c.is_whitespace()).next()?)
                    })?;
                    Some(Change::Unchanged { name: name()?, at: version(2)?, available })
                }
                _ => None,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn table(s: &str) -> Table {
        s.parse().unwrap()
    }

    #[test]
    fn dependency_sections_renames_and_workspace_inheritance() {
        let root = table(r#"
            [workspace]
            members = ["crates/*"]
            [workspace.dependencies]
            tokio = { version = "1.54.0", features = ["rt"] }
            rand_core = { version = "0.9", package = "rand_core" }
            local = { path = "crates/local" }
        "#);
        let member = table(r#"
            [package]
            name = "mp-host"
            [dependencies]
            tokio = { workspace = true, features = ["net"] }
            local = { workspace = true }
            serde = "1"
            pki = { package = "rustls-pki-types", version = "1" }
            [dev-dependencies]
            tempfile = "3"
            [build-dependencies]
            cc = { version = "1", optional = true }
            [target.'cfg(windows)'.dependencies]
            windows-sys = "0.61"
            [dependencies.gitdep]
            git = "https://github.com/x/y"
        "#);
        let ws = root.get("workspace").and_then(|w| w.get("dependencies")).and_then(Value::as_table);
        let specs = dep_specs("mp-host", &member, ws);
        let summary: Vec<(&str, &DepSource)> = specs.iter().map(|s| (s.name.as_str(), &s.source)).collect();
        assert_eq!(summary, [
            ("cc", &DepSource::CratesIo),
            ("gitdep", &DepSource::Git("https://github.com/x/y".into())),
            ("local", &DepSource::Path),
            ("rustls-pki-types", &DepSource::CratesIo),
            ("serde", &DepSource::CratesIo),
            ("tempfile", &DepSource::CratesIo),
            ("tokio", &DepSource::CratesIo),
            ("windows-sys", &DepSource::CratesIo),
        ]);
        assert_eq!(workspace_members(&root), (vec!["crates/*".to_string()], vec![]));
        assert_eq!(package_name(&member).as_deref(), Some("mp-host"));
    }

    #[test]
    fn resolves_duplicate_versions_through_the_member_entry() {
        let lock = parse_lock(r#"
            version = 4
            [[package]]
            name = "backend"
            version = "0.1.0"
            dependencies = ["getrandom 0.3.4", "serde", "local"]
            [[package]]
            name = "getrandom"
            version = "0.2.17"
            source = "registry+https://github.com/rust-lang/crates.io-index"
            [[package]]
            name = "getrandom"
            version = "0.3.4"
            source = "registry+https://github.com/rust-lang/crates.io-index"
            [[package]]
            name = "serde"
            version = "1.0.229"
            source = "registry+https://github.com/rust-lang/crates.io-index"
            [[package]]
            name = "local"
            version = "0.1.0"
        "#).unwrap();
        let spec = |name: &str, source| DepSpec { member: "backend".into(), name: name.into(), source };
        let specs = [spec("getrandom", DepSource::CratesIo), spec("serde", DepSource::CratesIo),
            spec("local", DepSource::Path), spec("missing", DepSource::CratesIo)];
        let (direct, unresolved) = resolve_direct(&specs, &lock);
        assert_eq!(direct, [DirectDep { name: "getrandom".into(), locked: "0.3.4".into() },
            DirectDep { name: "serde".into(), locked: "1.0.229".into() }]);
        assert_eq!(unresolved, ["missing"]);
    }

    #[test]
    fn parses_cargo_update_output() {
        let changes = parse_update_output(include_str!("fixtures/cargo-update-iroh-ssh.txt"));
        assert!(changes.contains(&Change::Update { name: "bumpalo".into(), from: "3.20.3".into(), to: "3.20.4".into() }));
        assert!(changes.contains(&Change::Unchanged { name: "iroh".into(), at: "1.3.0".into(), available: "1.5.0".into() }));
        assert!(changes.contains(&Change::Add { name: "lru".into(), version: "0.19.1".into() }));
        assert_eq!(changes.iter().filter(|c| matches!(c, Change::Update { .. })).count(), 73);
        // "Updating crates.io index" and "Locking 82 packages" are not changes.
        assert!(!changes.iter().any(|c| c.name() == "crates.io"));
    }

    #[test]
    fn parses_annotated_and_downgrade_lines() {
        let text = "    Updating foo v1.0.0 -> v1.1.0 (available: v2.0.0)\n Downgrading bar v0.3.1 -> v0.3.0\n    Removing baz v0.1.0\n   Unchanged qux v1.2.3 (available: v1.3.0, requires Rust 1.99)\n";
        assert_eq!(parse_update_output(text), [
            Change::Update { name: "foo".into(), from: "1.0.0".into(), to: "1.1.0".into() },
            Change::Downgrade { name: "bar".into(), from: "0.3.1".into(), to: "0.3.0".into() },
            Change::Remove { name: "baz".into(), version: "0.1.0".into() },
            Change::Unchanged { name: "qux".into(), at: "1.2.3".into(), available: "1.3.0".into() },
        ]);
    }

    #[test]
    fn wildcards() {
        assert!(wildcard_match("*", "mp-host"));
        assert!(wildcard_match("mp-*", "mp-host"));
        assert!(wildcard_match("m?-host", "mp-host"));
        assert!(!wildcard_match("x*", "mp-host"));
    }
}
