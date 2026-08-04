{ lib, rustPlatform }:

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
