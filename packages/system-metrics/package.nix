{ lib, rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "system-metrics";
  version = "0.1.0";

  src = lib.sourceByRegex ./. [
    "Cargo\\.(toml|lock)"
    "src(/.*)?"
  ];

  cargoLock.lockFile = ./Cargo.lock;

  meta = {
    description = "Report CPU, memory, filesystem and NixOS generation measurements to a local monitoring-platform receiver";
    license = with lib.licenses; [ mit asl20 ];
    mainProgram = "system-metrics";
  };
}
