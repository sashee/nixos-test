## Dependency checker

* depends on the [local collector](../monitoring/local-collector.md) and sends the measurements to it
* a systemd unit that runs every day

### Checking dependencies

* starts from https://github.com/sashee/nixos-test
* discovers all flake dependencies (even transitively) that has the same repository user as the starter repo
* in each of these repos, discovers all Cargo-based projects
* collects outdated dependencies
    * for each flake lock, check if there is a new version of the dependency
        * run nix flake update and compare the current flake.lock with the generated one
        * for each dependency that has a newer commit:
            * find the oldest commit that is missing => this is the time how outdated the dependency is
    * for each Cargo project, run:
        * cargo outdated
        * cargo audit

### Measurements

* the metrics are in the `dependencies` namespace, so each measurement is `dependencies.<name>` and sub measurements are `dependencies.<name>.<sub>`

* resource attributes:
    * service.name: "dependency-checker"
    * host.name / boot_id
    * top_level: the repository that is the root
* scope attributes:
    * name: "dependency-checker"
    * version: crate version

#### dependency_report

* one record per poll cycle

* body:
    * flake_max_outdated: the number of days the most outdated flake dependency is behind
    * num_rust_security_advisories: the number of rust advisories in total in all checked projects
    * num_rust_compatible_updates: the number of compatible rust updates in total in all checked projects
    * num_rust_incompatible_updates: the number of incompatible rust updates in total in all checked projects

#### outdated_flake

* one record per outdated flake dependency

* body:
    * repo: which repo the dependency is declared
    * dependency
    * current_commit
    * available_commit
    * current_commit_time
    * available_commit_time
    * outdated_since: the time of the oldest available commit

#### outdated_rust_dependency

* one record per outdated rust dependency

* body:
    * repo: which repo the dependency is declared
    * dependency
    * current_version
    * available_version
    * outdated_since: the time of the oldest available version

#### rust_advisory

* one record per rust advisory

* body:
    * repo: which repo the dependency is declared
    * dependency
    * type: vulnerability | unmaintained | unsound | yanked
    * advisory
    * title
    * date
    * severity
