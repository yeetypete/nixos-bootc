{
  config,
  lib,
  ...
}:

let
  cfg = config.boot.composefs;
in
{
  options.boot.composefs = {
    enable = lib.mkEnableOption "booting from a sealed composefs image";
  };

  config = lib.mkIf cfg.enable { };
}
