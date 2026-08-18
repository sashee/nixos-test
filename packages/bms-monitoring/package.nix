{ lib, rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "bms-monitoring";
  version = "0.1.0";

  src = lib.sourceByRegex ./. [
    "Cargo\\.(toml|lock)"
    "src(/.*)?"
  ];

  cargoLock.lockFile = ./Cargo.lock;

  meta = {
    description = "Passively read a JK BMS over USB serial and report it to a local monitoring-platform receiver";
    license = with lib.licenses; [ mit asl20 ];
    mainProgram = "bms-monitoring";
  };
}
