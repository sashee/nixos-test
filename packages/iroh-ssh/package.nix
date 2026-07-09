{ lib, rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "iroh-ssh";
  version = "0.1.0";

  src = lib.sourceByRegex ./. [
    "Cargo\\.(toml|lock)"
    "src(/.*)?"
  ];

  cargoLock.lockFile = ./Cargo.lock;

  meta = {
    description = "Expose the local sshd over an iroh endpoint; wire-compatible with dumbpipe";
    license = with lib.licenses; [ mit asl20 ];
    mainProgram = "iroh-ssh-connect";
  };
}
