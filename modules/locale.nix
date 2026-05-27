{ config, lib, ... }:

{
  options.common.locale.default = lib.mkOption {
    type = lib.types.str;
    default = "en_US.UTF-8";
    description = "Default system locale.";
  };

  config.i18n.defaultLocale = config.common.locale.default;
}
