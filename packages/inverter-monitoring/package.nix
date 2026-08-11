{ lib, rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "inverter-monitoring";
  version = "0.1.0";

  src = lib.sourceByRegex ./. [
    "Cargo\\.(toml|lock)"
    "src(/.*)?"
  ];

  cargoLock.lockFile = ./Cargo.lock;

  meta = {
    description = "Poll a Voltronic-protocol solar inverter over USB serial and report it to a local monitoring-platform receiver";
    license = with lib.licenses; [ mit asl20 ];
    mainProgram = "inverter-monitoring";
  };
}
