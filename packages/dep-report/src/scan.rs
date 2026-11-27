//! One repository tree in, everything the collectors find in it out. Reads files only; the
//! lookups that turn findings into staleness happen later, in the network stage.

use std::fs;
use std::path::{Path, PathBuf};

use toml::{Table, Value};

use crate::actions::{self, ActionUse};
use crate::cargo::{self, DepSource, DirectDep};
use crate::flake_lock::{self, FlakeInput};
use crate::pins::{self, TarballPin};

#[derive(Debug)]
pub struct CargoLockInfo {
    /// The workspace manifest next to the lock, which `cargo update` is pointed at.
    pub manifest: PathBuf,
    pub members: Vec<String>,
    pub direct: Vec<DirectDep>,
    pub unresolved: Vec<String>,
    pub git_deps: Vec<String>,
}

#[derive(Debug, Default)]
pub struct Findings {
    pub flake_locks: Vec<(String, Result<Vec<FlakeInput>, String>)>,
    pub cargo: Vec<(String, Result<CargoLockInfo, String>)>,
    pub pins: Vec<TarballPin>,
    pub actions: Vec<ActionUse>,
}

/// Directories no pin file lives in: build output, VCS data, vendored JS. Symlinks are never
/// followed either (`result` links into the store would otherwise drag whole closures in).
const SKIP_DIRS: [&str; 4] = [".git", "target", "node_modules", ".direnv"];

/// Every regular file under `root`, as sorted `/`-separated relative paths.
pub fn files(root: &Path) -> Vec<String> {
    let mut out = Vec::new();
    let mut stack = vec![String::new()];
    while let Some(rel) = stack.pop() {
        let Ok(entries) = fs::read_dir(root.join(&rel)) else { continue };
        for entry in entries.flatten() {
            let (Some(name), Ok(kind)) = (entry.file_name().to_str().map(str::to_string), entry.file_type()) else {
                continue;
            };
            let child = if rel.is_empty() { name.clone() } else { format!("{rel}/{name}") };
            if kind.is_dir() && !SKIP_DIRS.contains(&name.as_str()) {
                stack.push(child);
            } else if kind.is_file() {
                out.push(child);
            }
        }
    }
    out.sort();
    out
}

fn file_name(rel: &str) -> &str {
    rel.rsplit('/').next().unwrap_or(rel)
}

fn is_workflow(rel: &str) -> bool {
    rel.starts_with(".github/") && (rel.ends_with(".yml") || rel.ends_with(".yaml"))
}

pub fn scan(root: &Path) -> Findings {
    let read = |rel: &str| fs::read_to_string(root.join(rel)).map_err(|e| format!("{rel}: {e}"));
    let all = files(root);
    let flake_locks = all
        .iter()
        .filter(|rel| file_name(rel) == "flake.lock")
        .map(|rel| (rel.clone(), read(rel).and_then(|t| flake_lock::direct_inputs(&t))))
        .collect();
    let cargo = all
        .iter()
        .filter(|rel| file_name(rel) == "Cargo.lock")
        .map(|rel| (rel.clone(), cargo_lock(root, rel)))
        .collect();
    let pins = all
        .iter()
        .filter(|rel| rel.ends_with(".nix"))
        .filter_map(|rel| read(rel).ok().map(|text| pins::find(rel, &text)))
        .flatten()
        .collect();
    let actions = all
        .iter()
        .filter(|rel| is_workflow(rel))
        .filter_map(|rel| read(rel).ok().map(|text| actions::find(rel, &text)))
        .flatten()
        .collect();
    Findings { flake_locks, cargo, pins, actions }
}

fn read_table(path: &Path) -> Result<Table, String> {
    let text = fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    text.parse::<Table>().map_err(|e| format!("{}: {e}", path.display()))
}

/// Member directories matching `[workspace] members` patterns (`*` and `?` per component).
fn expand_members(dir: &Path, patterns: &[String], excludes: &[String]) -> Vec<PathBuf> {
    let mut found: Vec<PathBuf> = patterns
        .iter()
        .flat_map(|pattern| {
            pattern.split('/').filter(|c| !c.is_empty() && *c != ".").fold(vec![PathBuf::new()], |acc, component| {
                acc.into_iter()
                    .flat_map(|base| {
                        if !component.contains(['*', '?']) {
                            return vec![base.join(component)];
                        }
                        let mut names: Vec<String> = fs::read_dir(dir.join(&base))
                            .into_iter()
                            .flatten()
                            .flatten()
                            .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
                            .filter_map(|e| e.file_name().to_str().map(str::to_string))
                            .filter(|name| cargo::wildcard_match(component, name))
                            .collect();
                        names.sort();
                        names.into_iter().map(|n| base.join(n)).collect()
                    })
                    .collect()
            })
        })
        .filter(|rel| !excludes.iter().any(|ex| Path::new(ex) == rel.as_path()))
        .filter(|rel| dir.join(rel).join("Cargo.toml").is_file())
        .collect();
    found.sort();
    found.dedup();
    found
}

fn cargo_lock(root: &Path, rel: &str) -> Result<CargoLockInfo, String> {
    let lock_path = root.join(rel);
    let dir = lock_path.parent().ok_or("lock has no directory")?;
    let manifest = dir.join("Cargo.toml");
    let root_table = read_table(&manifest)?;
    let (patterns, excludes) = cargo::workspace_members(&root_table);
    let member_tables = expand_members(dir, &patterns, &excludes)
        .into_iter()
        .map(|member_dir| read_table(&dir.join(member_dir).join("Cargo.toml")))
        .collect::<Result<Vec<_>, _>>()?;
    let members: Vec<(String, &Table)> = std::iter::once(&root_table)
        .chain(member_tables.iter())
        .filter_map(|t| cargo::package_name(t).map(|name| (name, t)))
        .collect();
    let workspace_deps = root_table.get("workspace").and_then(|w| w.get("dependencies")).and_then(Value::as_table);
    let specs: Vec<_> =
        members.iter().flat_map(|(name, table)| cargo::dep_specs(name, table, workspace_deps)).collect();
    let lock = cargo::parse_lock(&fs::read_to_string(&lock_path).map_err(|e| format!("{rel}: {e}"))?)?;
    let (direct, unresolved) = cargo::resolve_direct(&specs, &lock);
    let mut git_deps: Vec<String> = specs
        .iter()
        .filter_map(|s| match &s.source {
            DepSource::Git(url) => Some(format!("{} ({url})", s.name)),
            _ => None,
        })
        .collect();
    git_deps.sort();
    git_deps.dedup();
    Ok(CargoLockInfo {
        manifest,
        members: members.into_iter().map(|(name, _)| name).collect(),
        direct,
        unresolved,
        git_deps,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(base: &Path, rel: &str, text: &str) {
        let path = base.join(rel);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }

    const CRATES_IO: &str = "registry+https://github.com/rust-lang/crates.io-index";

    #[test]
    fn scans_a_tree_with_a_workspace() {
        let base = std::env::temp_dir().join(format!("dep-report-scan-{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        write(&base, "Cargo.toml", "[workspace]\nmembers = [\"crates/*\"]\n[workspace.dependencies]\ntokio = \"1.54\"\n\
            [package]\nname = \"mp\"\nversion = \"0.1.0\"\n[dependencies]\nserde = \"1\"\n");
        write(&base, "crates/mp-host/Cargo.toml",
            "[package]\nname = \"mp-host\"\nversion = \"0.1.0\"\n[dependencies]\ntokio = { workspace = true }\n");
        write(&base, "Cargo.lock", &format!("version = 4\n\
            [[package]]\nname = \"mp\"\nversion = \"0.1.0\"\ndependencies = [\"serde\"]\n\
            [[package]]\nname = \"mp-host\"\nversion = \"0.1.0\"\ndependencies = [\"tokio\"]\n\
            [[package]]\nname = \"serde\"\nversion = \"1.0.229\"\nsource = \"{CRATES_IO}\"\n\
            [[package]]\nname = \"tokio\"\nversion = \"1.54.1\"\nsource = \"{CRATES_IO}\"\ndependencies = [\"bytes\"]\n\
            [[package]]\nname = \"bytes\"\nversion = \"1.12.1\"\nsource = \"{CRATES_IO}\"\n"));
        write(&base, "target/debug/Cargo.lock", "garbage");
        write(&base, "nix/e2ee-store.nix", include_str!("fixtures/e2ee-store.nix.txt"));
        write(&base, ".github/workflows/ci.yml", include_str!("fixtures/dotfiles-ci.yml.txt"));
        write(&base, "flake.lock", include_str!("fixtures/flake-lock.json"));

        let found = scan(&base);
        assert_eq!(found.cargo.len(), 1, "target/ is skipped");
        let (rel, info) = &found.cargo[0];
        let info = info.as_ref().unwrap();
        assert_eq!(rel, "Cargo.lock");
        assert_eq!(info.members, ["mp", "mp-host"]);
        let direct: Vec<_> = info.direct.iter().map(|d| (d.name.as_str(), d.locked.as_str())).collect();
        assert_eq!(direct, [("serde", "1.0.229"), ("tokio", "1.54.1")]);
        assert_eq!(found.pins.len(), 1);
        assert_eq!(found.actions.len(), 4);
        assert_eq!(found.flake_locks.len(), 1);
        assert_eq!(found.flake_locks[0].1.as_ref().unwrap().len(), 7);
        fs::remove_dir_all(&base).unwrap();
    }
}
