//! What to ask GitHub and crates.io about the discovered trees, and how to read the answers.
//! Planning and parsing are pure; only `fetch_all` touches the network, through the `Fetcher`.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::Value;

use crate::cargo::Change;
use crate::date::parse_rfc3339;
use crate::discover::{Node, Tree};
use crate::flake_lock::InputSource;
use crate::http::{Fetcher, Outcome};
use crate::repo::RepoId;

fn encode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'/' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// What a branch (the default branch when there is no ref) has that `base` lacks: GitHub's
/// compare, oldest commits first. One page is enough: `ahead_by` is the exact count however long
/// the list, and the commits that say since when the pin has been behind are the oldest ones.
pub fn compare_url(repo: &RepoId, base: &str, reference: Option<&str>) -> String {
    format!("https://api.github.com/repos/{}/{}/compare/{}...{}?per_page=100", repo.owner, repo.repo, base,
        encode(reference.unwrap_or("HEAD")))
}

pub fn release_url(repo: &RepoId) -> String {
    format!("https://api.github.com/repos/{}/{}/releases/latest", repo.owner, repo.repo)
}

pub fn valid_crate_name(name: &str) -> bool {
    !name.is_empty() && name.len() <= 64 && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

pub fn versions_url(name: &str) -> String {
    format!("https://crates.io/api/v1/crates/{name}/versions")
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Comparison {
    /// GitHub's verdict on the branch relative to the pin: `identical`, `ahead` (it moved on),
    /// `behind` (the pin is newer than the branch) or `diverged`.
    pub status: String,
    pub ahead_by: u64,
    /// The pinned commit's own date.
    pub base_date: Option<i64>,
    /// The date of the oldest commit the pin lacks, counting only commits dated after the pinned
    /// one: a branch merged today can carry commits written a month ago, and those were not on
    /// the branch, so not missing from the pin, back then.
    pub first_new: Option<i64>,
    /// `first_new` is the pinned commit's own date standing in for an answer the page did not
    /// hold: nixos-unstable's oldest 100 new commits can all be staging work dated before the
    /// pin. A branch that busy moved on right after the pin, so the stand-in is close, and
    /// never later than the truth.
    pub approximate: bool,
}

pub fn parse_compare(body: &str) -> Option<Comparison> {
    let v: Value = serde_json::from_str(body).ok()?;
    let date = |c: &Value| c.get("commit")?.get("committer")?.get("date")?.as_str().and_then(parse_rfc3339);
    let base = v.get("base_commit")?;
    let (base_sha, base_date) = (base.get("sha").and_then(Value::as_str), date(base));
    let ahead_by = v.get("ahead_by")?.as_u64()?;
    let found = v
        .get("commits")?
        .as_array()?
        .iter()
        .filter(|c| c.get("sha").and_then(Value::as_str) != base_sha)
        .filter_map(date)
        .filter(|d| base_date.is_none_or(|b| *d >= b))
        .min();
    let (first_new, approximate) = match found {
        Some(t) => (Some(t), false),
        None if ahead_by > 0 => (base_date, base_date.is_some()),
        None => (None, false),
    };
    Some(Comparison { status: v.get("status")?.as_str()?.to_string(), ahead_by, base_date, first_new, approximate })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Release {
    pub tag: String,
    pub published: Option<i64>,
}

pub fn parse_release(body: &str) -> Option<Release> {
    let v: Value = serde_json::from_str(body).ok()?;
    Some(Release {
        tag: v.get("tag_name")?.as_str()?.to_string(),
        published: v.get("published_at").and_then(Value::as_str).and_then(parse_rfc3339),
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CrateVersion {
    pub num: semver::Version,
    pub created: Option<i64>,
    pub yanked: bool,
}

/// One page of `/api/v1/crates/{name}/versions`, and the query string of the next one.
pub fn parse_versions(body: &str) -> Result<(Vec<CrateVersion>, Option<String>), String> {
    let v: Value = serde_json::from_str(body).map_err(|e| format!("crates.io: {e}"))?;
    let versions = v
        .get("versions")
        .and_then(Value::as_array)
        .ok_or("crates.io: no `versions`")?
        .iter()
        .filter_map(|entry| {
            Some(CrateVersion {
                num: semver::Version::parse(entry.get("num")?.as_str()?).ok()?,
                created: entry.get("created_at").and_then(Value::as_str).and_then(parse_rfc3339),
                yanked: entry.get("yanked").and_then(Value::as_bool).unwrap_or(false),
            })
        })
        .collect();
    let next = v.get("meta").and_then(|m| m.get("next_page")).and_then(Value::as_str).map(str::to_string);
    Ok((versions, next))
}

/// The newest release that is not yanked; pre-releases only when the locked version is one.
pub fn newest(versions: &[CrateVersion], include_pre: bool) -> Option<&CrateVersion> {
    versions.iter().filter(|v| !v.yanked && (include_pre || v.num.pre.is_empty())).max_by(|a, b| a.num.cmp(&b.num))
}

pub fn find_version<'a>(versions: &'a [CrateVersion], num: &str) -> Option<&'a CrateVersion> {
    let wanted = semver::Version::parse(num).ok()?;
    versions.iter().find(|v| v.num == wanted)
}

/// Every tree in report order, the root first.
pub fn trees(root: &Tree) -> Vec<&Tree> {
    std::iter::once(root)
        .chain(root.children.iter().flat_map(|c| match &c.node {
            Node::Scanned(t) => trees(t),
            _ => Vec::new(),
        }))
        .collect()
}

/// The GitHub URLs a report on these trees needs, deduplicated, in first-use order.
pub fn github_urls(root: &Tree) -> Vec<String> {
    let mut seen = BTreeSet::new();
    trees(root)
        .into_iter()
        .flat_map(|tree| {
            let inputs = tree.findings.flake_locks.iter().flat_map(|(_, inputs)| inputs.iter().flatten()).filter_map(
                |input| match &input.source {
                    InputSource::GitHub { repo, rev, reference, .. } => Some(compare_url(repo, rev, reference.as_deref())),
                    _ => None,
                },
            );
            let pins = tree.findings.pins.iter().map(|p| compare_url(&p.repo, &p.rev, None));
            let actions = tree.findings.actions.iter().map(|a| release_url(&a.repo));
            inputs.chain(pins).chain(actions).collect::<Vec<_>>()
        })
        .filter(|url| seen.insert(url.clone()))
        .collect()
}

/// Names a report needs crates.io data for: every direct dependency, and with `transitive` every
/// other crate `cargo update` would move or reports as held back.
pub fn crate_names(root: &Tree, transitive: bool) -> Vec<String> {
    let names: BTreeSet<String> = trees(root)
        .into_iter()
        .flat_map(|tree| {
            let direct = tree.findings.cargo.iter().flat_map(|(_, info)| info.iter()).flat_map(|i| i.direct.iter()).map(|d| d.name.clone());
            let changed = tree
                .cargo_runs
                .iter()
                .flat_map(|run| run.changes.iter().flatten())
                .filter(|c| transitive && matches!(c, Change::Update { .. } | Change::Downgrade { .. } | Change::Unchanged { .. }))
                .map(|c| c.name().to_string());
            direct.chain(changed).collect::<Vec<_>>()
        })
        .filter(|n| valid_crate_name(n))
        .collect();
    names.into_iter().collect()
}

#[derive(Debug, Default)]
pub struct Answers {
    pub github: BTreeMap<String, Outcome>,
    pub crates: BTreeMap<String, Result<Vec<CrateVersion>, Outcome>>,
}

pub fn fetch_all(root: &Tree, transitive: bool, fetcher: &mut Fetcher, log: &dyn Fn(&str)) -> Answers {
    let github = github_urls(root).into_iter().map(|url| (url.clone(), fetcher.get(&url))).collect();
    let names = crate_names(root, transitive);
    log(&format!("looking up {} crates on crates.io (at most 1 request a second)", names.len()));
    let crates = names.into_iter().map(|name| (name.clone(), fetch_versions(&name, fetcher))).collect();
    Answers { github, crates }
}

fn fetch_versions(name: &str, fetcher: &mut Fetcher) -> Result<Vec<CrateVersion>, Outcome> {
    let base = versions_url(name);
    let mut all = Vec::new();
    let mut url = base.clone();
    // Without `per_page` crates.io returns every version on one page; following `next_page` is
    // for the day that changes. Capped so a misbehaving server cannot keep the loop going.
    for _ in 0..20 {
        let body = match fetcher.get(&url) {
            Outcome::Ok(body) => body,
            other => return Err(other),
        };
        let (versions, next) = parse_versions(&body).map_err(Outcome::Failed)?;
        all.extend(versions);
        match next {
            Some(query) if query.starts_with('?') => url = format!("{base}{query}"),
            _ => return Ok(all),
        }
    }
    Ok(all)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urls() {
        let repo = RepoId::new("NixOS", "nixpkgs").unwrap();
        assert_eq!(compare_url(&repo, "f684076", Some("nixos-26.05")),
            "https://api.github.com/repos/NixOS/nixpkgs/compare/f684076...nixos-26.05?per_page=100");
        assert_eq!(compare_url(&repo, "f684076", None), "https://api.github.com/repos/NixOS/nixpkgs/compare/f684076...HEAD?per_page=100");
        assert_eq!(compare_url(&repo, "f684076", Some("a&b c")),
            "https://api.github.com/repos/NixOS/nixpkgs/compare/f684076...a%26b%20c?per_page=100");
        assert!(valid_crate_name("rustls-pki-types"));
        assert!(!valid_crate_name("../x"));
    }

    #[test]
    fn parses_github_answers() {
        // monitoring-platform on 2026-11-21: pinned at a 2026-10-21 merge, and PR #19 merged
        // that afternoon. Behind since the PR, not since the pinned commit's date.
        let compare = r#"{"status":"ahead","ahead_by":2,"behind_by":0,
            "base_commit":{"sha":"71626dd","commit":{"committer":{"date":"2026-10-21T07:49:01Z"}}},
            "commits":[{"sha":"b3c7d49","commit":{"committer":{"date":"2026-11-21T15:50:55Z"}}},
                {"sha":"10b31a5","commit":{"committer":{"date":"2026-11-21T16:56:26Z"}}}]}"#;
        assert_eq!(parse_compare(compare), Some(Comparison { status: "ahead".into(), ahead_by: 2,
            base_date: parse_rfc3339("2026-10-21T07:49:01Z"), first_new: parse_rfc3339("2026-11-21T15:50:55Z"),
            approximate: false }));
        // A backport written before the pin but merged after it does not date the gap.
        let backport = r#"{"status":"ahead","ahead_by":2,
            "base_commit":{"sha":"f684076","commit":{"committer":{"date":"2026-11-16T23:43:10Z"}}},
            "commits":[{"sha":"17eca9a","commit":{"committer":{"date":"2026-10-23T20:02:08Z"}}},
                {"sha":"f074464","commit":{"committer":{"date":"2026-11-17T01:00:06Z"}}}]}"#;
        assert_eq!(parse_compare(backport).unwrap().first_new, parse_rfc3339("2026-11-17T01:00:06Z"));
        // nixos-unstable: 3041 new commits, and the oldest page holds only staging work dated
        // before the pin. The pin's own date stands in, marked as such.
        let truncated = r#"{"status":"ahead","ahead_by":3041,
            "base_commit":{"sha":"0490633","commit":{"committer":{"date":"2026-11-17T04:43:17Z"}}},
            "commits":[{"sha":"aaa","commit":{"committer":{"date":"2026-11-02T10:00:00Z"}}}]}"#;
        let c = parse_compare(truncated).unwrap();
        assert_eq!((c.first_new, c.approximate), (parse_rfc3339("2026-11-17T04:43:17Z"), true));
        assert_eq!(parse_compare("{}"), None);
        assert_eq!(parse_release(r#"{"tag_name":"v31.11.0","published_at":"2026-11-12T10:00:00Z"}"#),
            Some(Release { tag: "v31.11.0".into(), published: parse_rfc3339("2026-11-12T10:00:00Z") }));
    }

    #[test]
    fn parses_crates_io_versions() {
        let body = r#"{"versions":[
            {"num":"1.55.0-rc.1","created_at":"2026-11-20T00:00:00Z","yanked":false},
            {"num":"1.54.1","created_at":"2026-10-21T21:05:43.950213Z","yanked":false},
            {"num":"1.54.0","created_at":"2026-10-01T00:00:00Z","yanked":true}],
            "meta":{"total":3,"next_page":null}}"#;
        let (versions, next) = parse_versions(body).unwrap();
        assert_eq!(next, None);
        assert_eq!(newest(&versions, false).unwrap().num.to_string(), "1.54.1");
        assert_eq!(newest(&versions, true).unwrap().num.to_string(), "1.55.0-rc.1");
        assert!(find_version(&versions, "1.54.0").unwrap().yanked);
        assert!(parse_versions("{}").is_err());
    }
}
