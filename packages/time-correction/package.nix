{ lib, rustPlatform }:

let
  # Cargo.toml depends on aes and cmac only to switch on `zeroize` in aes-siv's copies of them.
  # That reaches aes-siv only while both resolve to the one version aes-siv itself uses: if it
  # moves to a newer aes or cmac, Cargo keeps ours alongside, the feature lands on the copy
  # nothing calls, and the NTS key schedules stop being wiped with no error or warning. So fail
  # evaluation instead. Cargo.lock names a dependency without its version exactly when only one
  # version of it is locked.
  packages = (lib.importTOML ./Cargo.lock).package;
  aesSiv = lib.findFirst (p: p.name == "aes-siv") { } packages;
  zeroizeReaches = name:
    lib.count (p: p.name == name) packages == 1
    && lib.elem name (aesSiv.dependencies or [ ]);
in
assert lib.assertMsg (lib.all zeroizeReaches [ "aes" "cmac" ]) ''
  time-correction: aes-siv no longer shares a single aes/cmac with Cargo.toml's direct
  dependencies, so their `zeroize` feature does not reach it. Move those versions to
  what aes-siv requires.
'';
rustPlatform.buildRustPackage {
  pname = "time-correction";
  version = "0.1.0";

  src = lib.sourceByRegex ./. [
    "Cargo\\.(toml|lock)"
    "src(/.*)?"
  ];

  cargoLock.lockFile = ./Cargo.lock;

  meta = {
    description = "Correct the system clock from an authenticated NTS timestamp, resolving the server over DoH";
    license = with lib.licenses; [ mit asl20 ];
    mainProgram = "time-correction";
  };
}
