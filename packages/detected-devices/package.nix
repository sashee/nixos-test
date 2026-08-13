{ lib, rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "detected-devices";
  version = "0.1.0";

  src = lib.sourceByRegex ./. [
    "Cargo\\.(toml|lock)"
    "src(/.*)?"
  ];

  cargoLock.lockFile = ./Cargo.lock;

  meta = {
    description = "Report USB, WiFi and Bluetooth devices this host can see to a local monitoring-platform receiver";
    license = with lib.licenses; [ mit asl20 ];
    mainProgram = "detected-devices";
  };
}
