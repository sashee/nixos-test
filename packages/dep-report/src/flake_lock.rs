//! Direct inputs of a flake.lock.
//!
//! Inputs are resolved through the root node's `inputs` map, never by node key: node keys are
//! deduplicated names (`nixpkgs_2`) that need not match the input name, and the node called
//! `nixpkgs` can belong to a third-party flake's own inputs.

use serde_json::Value;

use crate::repo::RepoId;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InputSource {
    GitHub { repo: RepoId, rev: String, last_modified: Option<i64>, reference: Option<String> },
    /// `inputs.x.follows = "y/z"`: the input is another flake's input, reported where it lives.
    Follows(Vec<String>),
    /// Any other fetcher (`path`, `git`, `tarball`, ...): listed, not looked up.
    Other(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FlakeInput {
    pub name: String,
    pub source: InputSource,
}

pub fn direct_inputs(text: &str) -> Result<Vec<FlakeInput>, String> {
    let lock: Value = serde_json::from_str(text).map_err(|e| format!("not JSON: {e}"))?;
    let nodes = lock.get("nodes").and_then(Value::as_object).ok_or("no `nodes` object")?;
    let root_key = lock.get("root").and_then(Value::as_str).unwrap_or("root");
    let root = nodes.get(root_key).ok_or_else(|| format!("no root node `{root_key}`"))?;
    let Some(inputs) = root.get("inputs").and_then(Value::as_object) else {
        return Ok(Vec::new());
    };
    Ok(inputs
        .iter()
        .map(|(name, target)| FlakeInput {
            name: name.clone(),
            source: match target {
                Value::String(key) => nodes.get(key).map_or_else(|| InputSource::Other("missing node".into()), source_of),
                Value::Array(path) => {
                    InputSource::Follows(path.iter().map(|p| p.as_str().unwrap_or("?").to_string()).collect())
                }
                _ => InputSource::Other("unrecognised input".into()),
            },
        })
        .collect())
}

fn source_of(node: &Value) -> InputSource {
    let locked = node.get("locked");
    let field = |name: &str| locked.and_then(|l| l.get(name)).and_then(Value::as_str);
    let kind = field("type").unwrap_or("unknown");
    let github = || {
        let repo = RepoId::new(field("owner")?, field("repo")?)?;
        let rev = field("rev")?.to_string();
        Some(InputSource::GitHub {
            repo,
            rev,
            last_modified: locked.and_then(|l| l.get("lastModified")).and_then(Value::as_i64),
            reference: node.get("original").and_then(|o| o.get("ref")).and_then(Value::as_str).map(str::to_string),
        })
    };
    match kind {
        "github" => github().unwrap_or_else(|| InputSource::Other("github (incomplete lock entry)".into())),
        other => InputSource::Other(other.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const REAL_LOCK: &str = include_str!("fixtures/flake-lock.json");

    fn github(inputs: &[FlakeInput], name: &str) -> (String, String, Option<i64>, Option<String>) {
        match &inputs.iter().find(|i| i.name == name).unwrap().source {
            InputSource::GitHub { repo, rev, last_modified, reference } => {
                (repo.to_string(), rev[..7].to_string(), *last_modified, reference.clone())
            }
            other => panic!("{name}: {other:?}"),
        }
    }

    #[test]
    fn maps_input_names_through_the_root_node() {
        let inputs = direct_inputs(REAL_LOCK).unwrap();
        let names: Vec<_> = inputs.iter().map(|i| i.name.as_str()).collect();
        assert_eq!(names, ["dotfiles", "media-store", "monitoring-platform", "nixos-raspberrypi", "nixpkgs",
            "nixpkgs-unstable", "pw-mgr"]);
        // Root's `nixpkgs` is node `nixpkgs_2`; node `nixpkgs` is nixos-raspberrypi's.
        assert_eq!(github(&inputs, "nixpkgs"),
            ("NixOS/nixpkgs".into(), "f684076".into(), Some(1_794_872_590), Some("nixos-26.05".into())));
        assert_eq!(github(&inputs, "dotfiles").3.as_deref(), Some("master"));
        assert_eq!(github(&inputs, "pw-mgr"), ("sashee/pw-mgr".into(), "b046fb0".into(), Some(1_793_396_950), None));
    }

    #[test]
    fn follows_and_other_types() {
        let lock = r#"{"root":"root","version":7,"nodes":{
            "root":{"inputs":{"a":["b","nixpkgs"],"local":"local"}},
            "local":{"locked":{"type":"path","path":"/x"},"original":{"type":"path","path":"/x"}}}}"#;
        let inputs = direct_inputs(lock).unwrap();
        assert_eq!(inputs[0].source, InputSource::Follows(vec!["b".into(), "nixpkgs".into()]));
        assert_eq!(inputs[1].source, InputSource::Other("path".into()));
    }

    #[test]
    fn rejects_non_locks() {
        assert!(direct_inputs("{}").is_err());
        assert!(direct_inputs("nope").is_err());
    }
}
