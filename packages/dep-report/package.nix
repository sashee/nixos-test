{ lib, rustPlatform, bubblewrap, cargo, rustc, cargo-audit }:

rustPlatform.buildRustPackage {
  pname = "dep-report";
  version = "0.1.0";

  src = lib.sourceByRegex ./. [
    "Cargo\\.(toml|lock)"
    "src(/.*)?"
  ];

  cargoLock.lockFile = ./Cargo.lock;

  # Baked into the binary (option_env! in src/main.rs) rather than looked up on PATH, so a run
  # always uses the sandbox and the Cargo it was built against. Cargo is this nixpkgs' own: its
  # resolver holds crates back for the toolchain's Rust version, and this rustc is the one the
  # packages here are built with. Nix is deliberately NOT baked in: the binary uses the caller's,
  # which has to match the running daemon and store. cargo-audit reports RustSec advisories for
  # every lockfile; its advisory database is fetched at run time into the cache.
  env = {
    DEP_REPORT_BWRAP = "${bubblewrap}/bin/bwrap";
    DEP_REPORT_CARGO = "${cargo}/bin/cargo";
    DEP_REPORT_RUSTC = "${rustc}/bin/rustc";
    DEP_REPORT_CARGO_AUDIT = "${cargo-audit}/bin/cargo-audit";
  };

  meta = {
    description = "Report how stale every dependency is across this repository and the repositories it pins";
    license = with lib.licenses; [ mit asl20 ];
    mainProgram = "dep-report";
  };
}
