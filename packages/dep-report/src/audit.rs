//! RustSec advisories for a Cargo.lock, from `cargo audit --json`: vulnerabilities, plus its
//! unsound / unmaintained / yanked warnings. Covers every locked crate, transitive ones included,
//! and says for each whether a plain `cargo update` gets past it (from the same dry run that
//! fills the "cargo update takes" column).

use serde_json::Value;

use crate::cargo::Change;

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum Kind {
    Vulnerability,
    Unsound,
    Yanked,
    Unmaintained,
    Other(String),
}

impl Kind {
    fn from(s: &str) -> Kind {
        match s {
            "unsound" => Kind::Unsound,
            "yanked" => Kind::Yanked,
            "unmaintained" => Kind::Unmaintained,
            other => Kind::Other(other.to_string()),
        }
    }

    pub fn label(&self) -> &str {
        match self {
            Kind::Vulnerability => "vulnerability",
            Kind::Unsound => "unsound",
            Kind::Yanked => "yanked",
            Kind::Unmaintained => "unmaintained",
            Kind::Other(s) => s,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finding {
    pub kind: Kind,
    pub id: Option<String>,
    pub name: String,
    pub version: String,
    pub title: Option<String>,
    /// Requirements a fixed version meets (`>=1.54.1`); empty when no release fixes it, `None`
    /// for a yanked crate, where any other release will do.
    pub patched: Option<Vec<String>>,
}

fn finding(kind: Kind, entry: &Value) -> Option<Finding> {
    let package = entry.get("package")?;
    let advisory = entry.get("advisory").filter(|a| !a.is_null());
    let text = |v: Option<&Value>, key: &str| v.and_then(|v| v.get(key)).and_then(Value::as_str).map(str::to_string);
    Some(Finding {
        kind,
        id: text(advisory, "id"),
        name: text(Some(package), "name")?,
        version: text(Some(package), "version")?,
        title: text(advisory, "title"),
        patched: entry
            .get("versions")
            .and_then(|v| v.get("patched"))
            .and_then(Value::as_array)
            .map(|reqs| reqs.iter().filter_map(Value::as_str).map(str::to_string).collect()),
    })
}

pub fn parse(json: &str) -> Result<Vec<Finding>, String> {
    let v: Value = serde_json::from_str(json).map_err(|e| format!("cargo audit output: {e}"))?;
    let vulnerabilities = v
        .get("vulnerabilities")
        .and_then(|x| x.get("list"))
        .and_then(Value::as_array)
        .ok_or("cargo audit output: no vulnerability list")?
        .iter()
        .filter_map(|e| finding(Kind::Vulnerability, e));
    let warnings = v.get("warnings").and_then(Value::as_object).into_iter().flat_map(|w| {
        w.iter().flat_map(|(kind, list)| list.as_array().into_iter().flatten().filter_map(move |e| finding(Kind::from(kind), e)))
    });
    let mut all: Vec<Finding> = vulnerabilities.chain(warnings).collect();
    all.sort_by(|a, b| (&a.kind, &a.name, &a.version, &a.id).cmp(&(&b.kind, &b.name, &b.version, &b.id)));
    Ok(all)
}

fn fixed_by(patched: &Option<Vec<String>>, version: &str) -> bool {
    let Ok(version) = semver::Version::parse(version) else { return false };
    match patched {
        None => true,
        Some(reqs) => reqs.iter().filter_map(|r| semver::VersionReq::parse(r).ok()).any(|r| r.matches(&version)),
    }
}

/// What getting past this finding takes, given what `cargo update` would do to the lockfile.
pub fn remedy(f: &Finding, changes: &Result<Vec<Change>, String>) -> String {
    let moved = changes.as_ref().ok().and_then(|cs| {
        cs.iter().find_map(|c| match c {
            Change::Update { name, from, to } | Change::Downgrade { name, from, to } if *name == f.name && *from == f.version => {
                Some(Some(to.clone()))
            }
            Change::Remove { name, version } if *name == f.name && *version == f.version => Some(None),
            _ => None,
        })
    });
    let fixed_in = f.patched.as_ref().filter(|p| !p.is_empty()).map(|p| p.join(", "));
    match (moved, &fixed_in) {
        (Some(None), _) => "`cargo update` drops the crate".to_string(),
        (Some(Some(to)), _) if fixed_by(&f.patched, &to) => format!("`cargo update` fixes it ({to})"),
        (Some(Some(to)), Some(fix)) => format!("`cargo update` only reaches {to}; fixed in {fix}"),
        (_, None) if f.patched.is_some() => "no fixed release".to_string(),
        (_, Some(fix)) => format!("fixed in {fix}; `cargo update` cannot reach it"),
        (_, None) => "`cargo update` cannot move it".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_real_output() {
        let all = parse(include_str!("fixtures/cargo-audit-iroh-ssh.json")).unwrap();
        let summary: Vec<(&str, &str, &str)> = all.iter().map(|f| (f.kind.label(), f.name.as_str(), f.version.as_str())).collect();
        assert_eq!(&summary[..2], [("vulnerability", "ctutils", "0.4.3"), ("vulnerability", "tokio", "1.54.0")]);
        assert_eq!(all.iter().filter(|f| f.kind == Kind::Unsound && f.name == "heapless").count(), 9);
        let yanked = all.iter().find(|f| f.kind == Kind::Yanked).unwrap();
        assert_eq!((yanked.name.as_str(), &yanked.id, &yanked.patched), ("tokio", &None, &None));
        let paste = all.iter().find(|f| f.name == "paste").unwrap();
        assert_eq!((&paste.kind, paste.patched.as_deref()), (&Kind::Unmaintained, Some(&[][..])));
        assert!(parse("{}").is_err());
    }

    fn f(name: &str, version: &str, patched: Option<&[&str]>) -> Finding {
        Finding { kind: Kind::Vulnerability, id: None, name: name.into(), version: version.into(), title: None,
            patched: patched.map(|p| p.iter().map(|s| s.to_string()).collect()) }
    }

    #[test]
    fn remedies() {
        let changes = Ok(vec![
            Change::Update { name: "tokio".into(), from: "1.54.0".into(), to: "1.54.1".into() },
            Change::Update { name: "rusqlite".into(), from: "0.40.1".into(), to: "0.40.2".into() },
            Change::Remove { name: "once_cell".into(), version: "1.21.4".into() },
        ]);
        assert_eq!(remedy(&f("tokio", "1.54.0", Some(&[">=1.54.1"])), &changes), "`cargo update` fixes it (1.54.1)");
        assert_eq!(remedy(&f("tokio", "1.54.0", None), &changes), "`cargo update` fixes it (1.54.1)");
        assert_eq!(remedy(&f("rusqlite", "0.40.1", Some(&[">=0.41.0"])), &changes), "`cargo update` only reaches 0.40.2; fixed in >=0.41.0");
        assert_eq!(remedy(&f("heapless", "0.7.17", Some(&[">=0.9.4"])), &changes), "fixed in >=0.9.4; `cargo update` cannot reach it");
        assert_eq!(remedy(&f("paste", "1.0.15", Some(&[])), &changes), "no fixed release");
        assert_eq!(remedy(&f("once_cell", "1.21.4", Some(&[])), &changes), "`cargo update` drops the crate");
        assert_eq!(remedy(&f("x", "1.0.0", None), &changes), "`cargo update` cannot move it");
    }
}
