//! The plain-text report: discovered trees plus lookup answers in, text out. Pure, so the whole
//! layout is testable without a network.

use std::collections::{BTreeMap, BTreeSet};

use crate::actions::{ActionUse, TagRelation, compare_tags};
use crate::audit::{self, Finding, Kind};
use crate::cargo::{Change, DirectDep};
use crate::date::{ago, format_date, format_datetime, format_time, gap_days};
use crate::discover::{CargoRun, Child, Node, Tree, Via, label};
use crate::flake_lock::{FlakeInput, InputSource};
use crate::http::{Outcome, Stats};
use crate::lookups::{self, Answers, CrateVersion};
use crate::repo::{RepoId, short};
use crate::scan::CargoLockInfo;

pub struct Context<'a> {
    pub answers: &'a Answers,
    pub now: i64,
    pub transitive: bool,
}

/// Rows padded into columns; the last column is not padded.
pub fn table(rows: &[Vec<String>], indent: usize) -> Vec<String> {
    let columns = rows.iter().map(Vec::len).max().unwrap_or(0);
    let widths: Vec<usize> = (0..columns)
        .map(|c| rows.iter().filter_map(|r| r.get(c)).map(|s| s.chars().count()).max().unwrap_or(0))
        .collect();
    rows.iter()
        .map(|row| {
            let cells: Vec<String> = row
                .iter()
                .enumerate()
                .map(|(c, cell)| if c + 1 == row.len() { cell.clone() } else { format!("{cell:<width$}", width = widths[c]) })
                .collect();
            format!("{}{}", " ".repeat(indent), cells.join("  ")).trim_end().to_string()
        })
        .collect()
}

fn unknown(outcome: &Outcome) -> String {
    match outcome {
        Outcome::RateLimited { reset: Some(at) } => format!("unknown (rate limited, resets at {})", format_time(*at)),
        Outcome::RateLimited { reset: None } => "unknown (rate limited)".to_string(),
        Outcome::NotFound => "unknown (not found)".to_string(),
        Outcome::Failed(e) => format!("unknown ({e})"),
        Outcome::Ok(_) => "unknown (unexpected answer)".to_string(),
    }
}

fn github<'a>(ctx: &'a Context, url: &str) -> Result<&'a str, String> {
    match ctx.answers.github.get(url) {
        Some(Outcome::Ok(body)) => Ok(body),
        Some(other) => Err(unknown(other)),
        None => Err("unknown (not looked up)".to_string()),
    }
}

fn plural(n: u64, one: &str) -> String {
    if n == 1 { format!("1 {one}") } else { format!("{n} {one}s") }
}

/// How long a pin has been behind its branch, and by how many commits: "behind 0 days, 2
/// commits" for a pin whose branch moved on today. Days count from the oldest commit the pin
/// lacks, not from the pinned commit's own date, so a repository that sat untouched for a month
/// and changed this afternoon is a few hours behind, not a month. Also returns the pinned
/// commit's date, which the compare carries.
fn staleness(ctx: &Context, url: &str) -> (Option<i64>, String) {
    let compare = match github(ctx, url).map(lookups::parse_compare) {
        Ok(Some(c)) => c,
        Ok(None) => return (None, "unknown (unexpected GitHub answer)".into()),
        Err(reason) => return (None, reason),
    };
    let status = match (compare.status.as_str(), compare.ahead_by) {
        ("identical", _) | ("behind", 0) | (_, 0) => "up to date".to_string(),
        (verdict, ahead) => {
            let commits = plural(ahead, "commit");
            let about = if compare.approximate { "~" } else { "" };
            let since = match compare.first_new.map(|t| gap_days(t, ctx.now).max(0)) {
                Some(days) => format!("behind {about}{}, {commits}", plural(days as u64, "day")),
                None => format!("behind by {commits}"),
            };
            if verdict == "diverged" { format!("{since}; the pinned commit is not on the branch") } else { since }
        }
    };
    (compare.base_date, status)
}

fn child_note(children: &[Child], via: &Via) -> String {
    match children.iter().find(|c| &c.via == via).map(|c| &c.node) {
        Some(Node::Scanned(_)) => "scanned below".into(),
        Some(Node::SeeAbove) => "see above".into(),
        Some(Node::RootRepo) => "root repo, not scanned".into(),
        Some(Node::DepthLimit) => "not scanned (depth limit)".into(),
        Some(Node::Failed(e)) => format!("not scanned: {e}"),
        None => String::new(),
    }
}

/// One table row, and whether it is up to date: those are counted, not printed.
struct Row {
    cells: Vec<String>,
    current: bool,
}

/// A section header and the rows that need something done; the header says how many were up to
/// date, so a quiet section still shows it was checked.
fn section(header: &str, columns: Option<Vec<String>>, rows: Vec<Row>, indent: usize) -> Vec<String> {
    let hidden = rows.iter().filter(|r| r.current).count();
    let shown: Vec<Vec<String>> = rows.into_iter().filter(|r| !r.current).map(|r| r.cells).collect();
    let note = match (shown.is_empty(), hidden) {
        (_, 0) => String::new(),
        (true, n) => format!("  all {n} up to date"),
        (false, n) => format!("  (+{n} up to date)"),
    };
    let body = if shown.is_empty() { Vec::new() } else { columns.into_iter().chain(shown).collect() };
    std::iter::once(format!("{}{header}{note}", " ".repeat(indent))).chain(table(&body, indent + 2)).collect()
}

fn flake_rows(ctx: &Context, tree: &Tree, lock: &str, inputs: &[FlakeInput]) -> Vec<Row> {
    inputs
        .iter()
        .map(|input| match &input.source {
            InputSource::GitHub { repo, rev, last_modified, reference } => {
                let (_, status) = staleness(ctx, &lookups::compare_url(repo, rev, reference.as_deref()));
                let locked = format!("{} {}", short(rev), last_modified.map(format_date).unwrap_or_default()).trim_end().to_string();
                let via = Via::Input { lock: lock.to_string(), name: input.name.clone() };
                let current = status == "up to date";
                Row { cells: vec![input.name.clone(), repo.to_string(), reference.clone().unwrap_or_else(|| "(default)".into()),
                    locked, status, child_note(&tree.children, &via)], current }
            }
            InputSource::Follows(path) => Row { cells: vec![input.name.clone(), format!("follows {}", path.join("/"))], current: true },
            InputSource::Other(kind) => Row {
                cells: vec![input.name.clone(), format!("({kind})"), String::new(), String::new(), "not checked".into()],
                current: false,
            },
        })
        .collect()
}

fn versions<'a>(ctx: &'a Context, name: &str) -> Result<&'a [CrateVersion], String> {
    match ctx.answers.crates.get(name) {
        Some(Ok(v)) => Ok(v),
        Some(Err(outcome)) => Err(unknown(outcome)),
        None => Err("unknown (not looked up)".into()),
    }
}

fn released(ctx: &Context, name: &str, version: &str) -> String {
    versions(ctx, name)
        .ok()
        .and_then(|vs| lookups::find_version(vs, version))
        .and_then(|v| v.created)
        .map_or_else(|| "date unknown".to_string(), |t| ago(ctx.now, t))
}

fn direct_row(ctx: &Context, dep: &DirectDep, changes: &Result<Vec<Change>, String>) -> Row {
    let moved = changes.as_ref().ok().and_then(|cs| {
        cs.iter().find_map(|c| match c {
            Change::Update { name, from, to } if *name == dep.name && *from == dep.locked => Some((to.clone(), false)),
            Change::Downgrade { name, from, to } if *name == dep.name && *from == dep.locked => Some((to.clone(), true)),
            _ => None,
        })
    });
    let takes = match (&moved, changes) {
        (_, Err(_)) => "?".to_string(),
        (Some((to, false)), _) => format!("{to} ({})", released(ctx, &dep.name, to)),
        (Some((to, true)), _) => format!("{to} (downgrade)"),
        (None, _) => "-".to_string(),
    };
    let bump = match versions(ctx, &dep.name) {
        Err(reason) => reason,
        Ok(vs) => {
            let locked = semver::Version::parse(&dep.locked).ok();
            let include_pre = locked.as_ref().is_some_and(|v| !v.pre.is_empty());
            let baseline = moved.as_ref().and_then(|(to, _)| semver::Version::parse(to).ok()).max(locked);
            match (lookups::newest(vs, include_pre), baseline) {
                (Some(newest), Some(base)) if newest.num > base => {
                    format!("{} ({})", newest.num, newest.created.map_or_else(|| "date unknown".into(), |t| ago(ctx.now, t)))
                }
                _ => "-".to_string(),
            }
        }
    };
    let current = takes == "-" && bump == "-";
    Row { cells: vec![dep.name.clone(), dep.locked.clone(), takes, bump], current }
}

fn transitive_lines(ctx: &Context, info: &CargoLockInfo, changes: &[Change], indent: usize) -> Vec<String> {
    let direct: BTreeSet<&str> = info.direct.iter().map(|d| d.name.as_str()).collect();
    let others: Vec<&Change> = changes.iter().filter(|c| !direct.contains(c.name())).collect();
    if others.is_empty() {
        return Vec::new();
    }
    let count = |f: fn(&Change) -> bool| others.iter().filter(|c| f(c)).count();
    let parts: Vec<String> = [
        (count(|c| matches!(c, Change::Update { .. })), "update"),
        (count(|c| matches!(c, Change::Downgrade { .. })), "downgrade"),
        (count(|c| matches!(c, Change::Add { .. })), "add"),
        (count(|c| matches!(c, Change::Remove { .. })), "remove"),
    ]
    .iter()
    .filter(|(n, _)| *n > 0)
    .map(|(n, verb)| format!("{verb} {n}"))
    .collect();
    let held = count(|c| matches!(c, Change::Unchanged { .. }));
    let pad = " ".repeat(indent);
    let mut summary = if parts.is_empty() {
        format!("{pad}transitive:")
    } else {
        format!("{pad}transitive: `cargo update` would {}", parts.join(", "))
    };
    if held > 0 {
        summary.push_str(&format!("{}{held} held back (a newer release it will not take)", if parts.is_empty() { " " } else { "; " }));
    }
    if !ctx.transitive {
        summary.push_str("  (--transitive lists them)");
        return vec![summary];
    }
    let mut rows: Vec<Vec<String>> = others
        .iter()
        .map(|c| match c {
            Change::Update { name, from, to } | Change::Downgrade { name, from, to } => {
                vec![name.clone(), format!("{from} -> {to}"), released(ctx, name, to)]
            }
            Change::Add { name, version } => vec![name.clone(), format!("added {version}"), String::new()],
            Change::Remove { name, version } => vec![name.clone(), format!("removed {version}"), String::new()],
            Change::Unchanged { name, at, available } => {
                vec![name.clone(), format!("{at}, held back"), format!("{available} available ({})", released(ctx, name, available))]
            }
        })
        .collect();
    rows.sort();
    std::iter::once(summary).chain(table(&rows, indent + 2)).collect()
}

fn shorten(text: &str, max: usize) -> String {
    if text.chars().count() <= max { text.to_string() } else { format!("{}...", text.chars().take(max - 3).collect::<String>()) }
}

/// cargo audit's findings, one row per crate version and kind: heapless 0.7.17 alone carries
/// nine unsound advisories with one fix, which read better as one line.
fn advisory_rows(findings: &[Finding], changes: &Result<Vec<Change>, String>) -> Vec<Vec<String>> {
    let mut grouped: BTreeMap<(&Kind, &str, &str), Vec<&Finding>> = BTreeMap::new();
    for f in findings {
        grouped.entry((&f.kind, &f.name, &f.version)).or_default().push(f);
    }
    grouped
        .into_iter()
        .map(|((kind, name, version), group)| {
            let ids: Vec<&str> = group.iter().filter_map(|f| f.id.as_deref()).collect();
            let id = match ids.as_slice() {
                [] => "-".to_string(),
                [one] => one.to_string(),
                [first, rest @ ..] => format!("{first} +{} more", rest.len()),
            };
            let title = match group.as_slice() {
                [one] => one.title.as_deref().map(|t| shorten(t, 60)).unwrap_or_default(),
                many => format!("{} advisories", many.len()),
            };
            vec![kind.label().to_string(), format!("{name} {version}"), id, title, audit::remedy(group[0], changes)]
        })
        .collect()
}

fn cargo_lines(ctx: &Context, rel: &str, info: &Result<CargoLockInfo, String>, run: &CargoRun, indent: usize) -> Vec<String> {
    let pad = " ".repeat(indent);
    let info = match info {
        Ok(info) => info,
        Err(e) => return vec![format!("{pad}CARGO  {rel}"), format!("{pad}  could not read: {e}")],
    };
    let members = if info.members.len() > 1 { format!("  (workspace: {})", info.members.join(", ")) } else { String::new() };
    let columns = vec!["crate".into(), "locked".into(), "cargo update takes".into(), "needs a Cargo.toml bump".into()];
    let rows = info.direct.iter().map(|d| direct_row(ctx, d, &run.changes)).collect();
    let mut lines = section(&format!("CARGO  {rel}{members}"), Some(columns), rows, indent);
    if !info.unresolved.is_empty() {
        lines.push(format!("{pad}  not found in Cargo.lock: {}", info.unresolved.join(", ")));
    }
    if !info.git_deps.is_empty() {
        lines.push(format!("{pad}  git dependencies, not checked: {}", info.git_deps.join(", ")));
    }
    match &run.changes {
        Ok(changes) => lines.extend(transitive_lines(ctx, info, changes, indent + 2)),
        Err(e) => lines.push(format!("{pad}  {e}")),
    }
    match &run.audit {
        Ok(findings) if findings.is_empty() => {}
        Ok(findings) => {
            lines.push(format!("{pad}  ADVISORIES  (cargo audit)"));
            lines.extend(table(&advisory_rows(findings, &run.changes), indent + 4));
        }
        Err(e) => lines.push(format!("{pad}  {e}")),
    }
    lines
}

fn pin_rows(ctx: &Context, tree: &Tree) -> Vec<Row> {
    tree.findings
        .pins
        .iter()
        .map(|pin| {
            let (pinned_date, status) = staleness(ctx, &lookups::compare_url(&pin.repo, &pin.rev, None));
            let via = Via::Pin { file: pin.file.clone(), line: pin.line };
            let current = status == "up to date";
            Row {
                cells: vec![format!("{}:{}", pin.file, pin.line), pin.repo.to_string(),
                    format!("{} {}", short(&pin.rev), pinned_date.map(format_date).unwrap_or_default()).trim_end().to_string(), status,
                    child_note(&tree.children, &via)],
                current,
            }
        })
        .collect()
}

/// One action at one version (action, ref, version comment), and every file that uses it so.
type ActionKey = (String, String, Option<String>);

fn action_rows(ctx: &Context, uses: &[ActionUse]) -> Vec<Row> {
    let mut grouped: BTreeMap<ActionKey, (&ActionUse, BTreeSet<String>)> = BTreeMap::new();
    for u in uses {
        grouped
            .entry((u.action.clone(), u.reference.clone(), u.comment.clone()))
            .or_insert_with(|| (u, BTreeSet::new()))
            .1
            .insert(u.file.clone());
    }
    grouped
        .values()
        .map(|(u, files)| {
            let current = u.current_version().map_or_else(|| format!("{} (no version comment)", short(&u.reference)), str::to_string);
            let (latest, status) = match github(ctx, &lookups::release_url(&u.repo)) {
                Ok(body) => match lookups::parse_release(body) {
                    Some(release) => {
                        let when = release.published.map(|t| format!(" ({})", ago(ctx.now, t))).unwrap_or_default();
                        let status = u.current_version().map_or("compare by hand", |cur| match compare_tags(cur, &release.tag) {
                            TagRelation::Same => "up to date",
                            TagRelation::Tracks => "up to date (moving tag)",
                            TagRelation::Older => "behind",
                            TagRelation::Newer => "newer than the latest release",
                            TagRelation::Unknown => "compare by hand",
                        });
                        (format!("latest {}{when}", release.tag), status.to_string())
                    }
                    None => (String::new(), "unknown (unexpected GitHub answer)".into()),
                },
                Err(reason) if reason == unknown(&Outcome::NotFound) => (String::new(), "no releases published".into()),
                Err(reason) => (String::new(), reason),
            };
            let up_to_date = status.starts_with("up to date");
            Row { cells: vec![u.action.clone(), current, latest, status, files.iter().cloned().collect::<Vec<_>>().join(", ")],
                current: up_to_date }
        })
        .collect()
}

fn tree_lines(ctx: &Context, tree: &Tree, depth: usize, via: Option<&str>, out: &mut Vec<String>) {
    let pad = " ".repeat(depth * 2);
    let indent = depth * 2 + 2;
    let via = via.map(|v| format!("   ({v})")).unwrap_or_default();
    out.push(String::new());
    out.push(format!("{pad}== {}{via}", label(&tree.repo, tree.rev.as_deref())));
    let before = out.len();
    for (lock, inputs) in &tree.findings.flake_locks {
        match inputs {
            Ok(inputs) => out.extend(section(&format!("FLAKE INPUTS  {lock}"), None, flake_rows(ctx, tree, lock, inputs), indent)),
            Err(e) => out.push(format!("{pad}  FLAKE INPUTS  {lock}: could not read: {e}")),
        }
    }
    for ((rel, info), run) in tree.findings.cargo.iter().zip(&tree.cargo_runs) {
        out.extend(cargo_lines(ctx, rel, info, run, indent));
    }
    if !tree.findings.pins.is_empty() {
        out.extend(section("PINS", None, pin_rows(ctx, tree), indent));
    }
    if !tree.findings.actions.is_empty() {
        out.extend(section("ACTIONS", None, action_rows(ctx, &tree.findings.actions), indent));
    }
    if out.len() == before {
        out.push(format!("{pad}  no pins, lockfiles or actions found"));
    }
    for child in &tree.children {
        if let Node::Scanned(sub) = &child.node {
            let via = match &child.via {
                Via::Input { name, .. } => format!("flake input {name}"),
                Via::Pin { file, line } => format!("pinned in {file}:{line}"),
            };
            tree_lines(ctx, sub, depth + 1, Some(&via), out);
        }
    }
}

pub fn summary(stats: &Stats) -> String {
    let remaining = match (stats.github_blocked, stats.github_remaining) {
        (Some(Some(reset)), _) => format!(", quota used up until {}", format_time(reset)),
        (Some(None), _) => ", quota used up".to_string(),
        (None, Some(left)) => format!(", {left} left this hour"),
        (None, None) => String::new(),
    };
    format!("GitHub API: {} calls ({} from cache{remaining}); crates.io: {} lookups ({} from cache)",
        stats.github_calls, stats.github_cached, stats.crates_calls, stats.crates_cached)
}

pub fn render(ctx: &Context, root: &Tree, root_repo: &RepoId, owners: &[String], stats: &Stats) -> String {
    let mut out = vec![
        format!("dep-report  {}", format_datetime(ctx.now)),
        format!("root: {}   repositories entered: owners {}", label(root_repo, None), owners.join(", ")),
    ];
    tree_lines(ctx, root, 0, None, &mut out);
    out.push(String::new());
    out.push(summary(stats));
    out.join("\n") + "\n"
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pins::TarballPin;
    use crate::scan::Findings;
    use std::path::PathBuf;

    const NOW: i64 = 1_795_275_707; // 2026-11-21 15:41:47 UTC
    const DAY: i64 = crate::date::DAY;

    fn iso(t: i64) -> String {
        format!("{}T{}:00Z", format_date(t), &format_time(t)[..5])
    }

    /// A GitHub compare answer: the pinned commit's date and the dates of the commits it lacks.
    fn compare(base_date: i64, ahead: u64, new: &[i64]) -> Outcome {
        let commits: Vec<String> = new
            .iter()
            .enumerate()
            .map(|(i, t)| format!(r#"{{"sha":"n{i}","commit":{{"committer":{{"date":"{}"}}}}}}"#, iso(*t)))
            .collect();
        Outcome::Ok(format!(r#"{{"status":"{}","ahead_by":{ahead},"base_commit":{{"sha":"base","commit":{{"committer":{{"date":"{}"}}}}}},"commits":[{}]}}"#,
            if ahead == 0 { "identical" } else { "ahead" }, iso(base_date), commits.join(",")))
    }

    fn finding(kind: Kind, id: Option<&str>, name: &str, version: &str, patched: Option<&[&str]>) -> Finding {
        Finding { kind, id: id.map(str::to_string), name: name.into(), version: version.into(),
            title: id.map(|_| "Race in Interval".to_string()), patched: patched.map(|p| p.iter().map(|s| s.to_string()).collect()) }
    }

    fn versions(list: &[(&str, i64, bool)]) -> Result<Vec<CrateVersion>, Outcome> {
        Ok(list.iter().map(|(n, t, y)| CrateVersion { num: semver::Version::parse(n).unwrap(), created: Some(*t), yanked: *y }).collect())
    }

    #[test]
    fn renders_the_layout() {
        let e2ee = RepoId::new("sashee", "e2ee-store").unwrap();
        let checkout = RepoId::new("actions", "checkout").unwrap();
        let nixpkgs = RepoId::new("NixOS", "nixpkgs").unwrap();
        let root = RepoId::new("sashee", "nixos-test").unwrap();
        let pinned = "e".repeat(40);
        let day0 = crate::date::days_from_civil(2026, 11, 7) * DAY;
        let findings = Findings {
            flake_locks: vec![("flake.lock".into(), Ok(vec![
                FlakeInput {
                    name: "nixpkgs".into(),
                    source: InputSource::GitHub { repo: nixpkgs.clone(), rev: "a".repeat(40), last_modified: Some(day0),
                        reference: Some("nixos-26.05".into()) },
                },
                FlakeInput {
                    name: "e2ee".into(),
                    source: InputSource::GitHub { repo: e2ee.clone(), rev: "c".repeat(40), last_modified: Some(day0), reference: None },
                },
            ]))],
            cargo: vec![("packages/x/Cargo.lock".into(), Ok(CargoLockInfo {
                manifest: PathBuf::from("/nix/store/x/Cargo.toml"),
                members: vec!["x".into()],
                direct: vec![DirectDep { name: "prost".into(), locked: "0.14.4".into() },
                    DirectDep { name: "serde".into(), locked: "1.0.229".into() },
                    DirectDep { name: "tokio".into(), locked: "1.54.0".into() }],
                unresolved: vec![],
                git_deps: vec![],
            }))],
            pins: vec![TarballPin { file: "nix/e2ee-store.nix".into(), line: 7, repo: e2ee.clone(), rev: pinned.clone(), sha256: None },
                TarballPin { file: "nix/iroh-ssh.nix".into(), line: 7, repo: root.clone(), rev: "1".repeat(40), sha256: None }],
            actions: crate::actions::find(".github/workflows/ci.yml", &format!("      - uses: actions/checkout@{} # v6.0.2\n", "d".repeat(40))),
        };
        let tree = Tree {
            repo: root.clone(),
            rev: None,
            findings,
            cargo_runs: vec![CargoRun {
                changes: Ok(vec![
                    Change::Update { name: "tokio".into(), from: "1.54.0".into(), to: "1.54.1".into() },
                    Change::Update { name: "bytes".into(), from: "1.12.1".into(), to: "1.12.2".into() },
                    Change::Remove { name: "once_cell".into(), version: "1.21.4".into() },
                ]),
                audit: Ok(vec![
                    finding(Kind::Vulnerability, Some("RUSTSEC-2026-0384"), "tokio", "1.54.0", Some(&[">=1.54.1"])),
                    finding(Kind::Unsound, Some("RUSTSEC-2026-0574"), "heapless", "0.7.17", Some(&[">=0.9.4"])),
                    finding(Kind::Unsound, Some("RUSTSEC-2026-0575"), "heapless", "0.7.17", Some(&[">=0.9.4"])),
                    finding(Kind::Yanked, None, "tokio", "1.54.0", None),
                ]),
            }],
            children: vec![Child { via: Via::Pin { file: "nix/e2ee-store.nix".into(), line: 7 }, node: Node::SeeAbove },
                Child { via: Via::Pin { file: "nix/iroh-ssh.nix".into(), line: 7 }, node: Node::RootRepo }],
        };
        let answers = Answers {
            github: BTreeMap::from([
                // A backport older than the pin, then the first commit really missing from it.
                (lookups::compare_url(&nixpkgs, &"a".repeat(40), Some("nixos-26.05")),
                    compare(day0, 312, &[day0 - 10 * DAY, NOW - 4 * DAY - 3600, NOW - DAY])),
                // Pinned a month ago, branch moved an hour ago: behind 0 days, not 31.
                (lookups::compare_url(&e2ee, &pinned, None), compare(day0 - 17 * DAY, 1, &[NOW - 3600])),
                (lookups::compare_url(&root, &"1".repeat(40), None), Outcome::RateLimited { reset: Some(NOW + 600) }),
                (lookups::compare_url(&e2ee, &"c".repeat(40), None), compare(day0, 0, &[])),
                (lookups::release_url(&checkout), Outcome::Ok(format!(r#"{{"tag_name":"v6.1.0","published_at":"{}T00:00:00Z"}}"#,
                    format_date(NOW - 9 * DAY)))),
            ]),
            crates: BTreeMap::from([
                ("tokio".to_string(), versions(&[("1.54.0", NOW - 30 * DAY, true), ("1.54.1", NOW - 2 * DAY, false)])),
                ("prost".to_string(), versions(&[("0.14.4", NOW - 60 * DAY, false), ("0.15.0", NOW - 15 * DAY, false)])),
                ("serde".to_string(), versions(&[("1.0.229", NOW - 60 * DAY, false)])),
            ]),
        };
        let ctx = Context { answers: &answers, now: NOW, transitive: false };
        let text = render(&ctx, &tree, &tree.repo, &["sashee".into()], &Stats { github_calls: 4, github_remaining: Some(52), ..Stats::default() });
        let expected = "\
dep-report  2026-11-21 15:41 UTC
root: sashee/nixos-test (working tree)   repositories entered: owners sashee

== sashee/nixos-test (working tree)
  FLAKE INPUTS  flake.lock  (+1 up to date)
    nixpkgs  NixOS/nixpkgs  nixos-26.05  aaaaaaa 2026-11-07  behind 4 days, 312 commits
  CARGO  packages/x/Cargo.lock  (+1 up to date)
    crate  locked  cargo update takes   needs a Cargo.toml bump
    prost  0.14.4  -                    0.15.0 (15 days ago)
    tokio  1.54.0  1.54.1 (2 days ago)  -
    transitive: `cargo update` would update 1, remove 1  (--transitive lists them)
    ADVISORIES  (cargo audit)
      vulnerability  tokio 1.54.0     RUSTSEC-2026-0384          Race in Interval  `cargo update` fixes it (1.54.1)
      unsound        heapless 0.7.17  RUSTSEC-2026-0574 +1 more  2 advisories      fixed in >=0.9.4; `cargo update` cannot reach it
      yanked         tokio 1.54.0     -                                            `cargo update` fixes it (1.54.1)
  PINS
    nix/e2ee-store.nix:7  sashee/e2ee-store  eeeeeee 2026-10-21  behind 0 days, 1 commit                      see above
    nix/iroh-ssh.nix:7    sashee/nixos-test  1111111             unknown (rate limited, resets at 15:51 UTC)  root repo, not scanned
  ACTIONS
    actions/checkout  v6.0.2  latest v6.1.0 (9 days ago)  behind  .github/workflows/ci.yml

GitHub API: 4 calls (0 from cache, 52 left this hour); crates.io: 0 lookups (0 from cache)
";
        assert_eq!(text, expected, "\n{text}");
    }

    #[test]
    fn table_alignment() {
        let rows = vec![vec!["a".into(), "bb".into(), "c".into()], vec!["ddd".into(), "e".into()]];
        assert_eq!(table(&rows, 2), ["  a    bb  c", "  ddd  e"]);
    }
}
