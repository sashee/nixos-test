{ lib, rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "rough-time";
  version = "0.1.0";

  src = lib.sourceByRegex ./. [
    "Cargo\\.(toml|lock)"
    "src(/.*)?"
  ];

  cargoLock.lockFile = ./Cargo.lock;

  meta = {
    description = "Establish a rough system clock at boot from an authenticated NTS timestamp, resolving the server over DoH";
    license = with lib.licenses; [ mit asl20 ];
    mainProgram = "rough-time";
  };
}
