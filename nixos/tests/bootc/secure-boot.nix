# Boot the sealed image with Secure Boot enforced. Secure Boot keys
# are enrolled by systemd-boot on first boot.
{
  hostPkgs,
  machineConfig,
  installAndBoot,
  subtests,
  ...
}:
let
  keys = hostPkgs.callPackage ./secure-boot-keys.nix { };

  # Placeholder for an external signer.
  sign =
    config: name:
    hostPkgs.runCommand "${name}.sig" { nativeBuildInputs = [ hostPkgs.openssl ]; } ''
      openssl dgst -sha256 -sign ${keys}/db.key -out $out \
        ${config.system.build.bootcSignedData.${name}}
    '';
in
{
  imports = [ ./common.nix ];

  name = "bootc-secure-boot";

  nodes.machine =
    { config, ... }:
    {
      imports = [ machineConfig ];

      boot.bootc.secureBoot = {
        enable = true;
        certificate = "${keys}/db.pem";
        enrollKeys = "${keys}/auto";
        signatures = {
          uki = sign config "uki";
          systemd-boot = sign config "systemd-boot";
        };
      };
    };

  testScript = ''
    ${installAndBoot}

    with subtest("The system booted with Secure Boot enabled"):
      t.assertIn("Secure Boot: enabled (user)", machine.succeed("bootctl status"))

    ${subtests}
  '';
}
