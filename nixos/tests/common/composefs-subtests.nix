# Python subtests for a machine booted from composefs-disk.nix.
{ lib, machine }:
let
  inherit (machine) boot system;
  inherit (machine.nixpkgs.hostPlatform) efiArch;

  # The UKI's name without the boot counter, e.g. nixos_1.efi for nixos_1+3.efi.
  blessedUkiFile =
    lib.replaceStrings [ "+${toString boot.uki.tries}" ] [ "" ]
      system.boot.loader.ukiFile;
in
''
  import json
  from pathlib import Path

  with subtest("The system is running"):
    _, state = machine.execute("systemctl is-system-running --wait")
    t.assertEqual(state.strip(), "running")

  with subtest("The root is a transient overlay of the composefs image"):
    digest = Path("${system.build.composefsDigest}").read_text().strip()
    t.assertIn(f"composefs.digest=v1-${lib.removePrefix "fsverity-" boot.composefs.algorithm}:{digest}", machine.succeed("cat /proc/cmdline"))
    t.assertEqual(machine.succeed("findmnt --noheadings --output FSTYPE,SOURCE /").split(), ["overlay", "transient"])

  with subtest("The UKI name matches the booted entry"):
    t.assertIn("Current Entry: ${blessedUkiFile}", machine.succeed("bootctl status"))

  with subtest("A successful boot removes the UKI's boot counter"):
    machine.wait_for_unit("systemd-bless-boot.service")
    machine.succeed("test -e /boot/EFI/Linux/${blessedUkiFile}")
    machine.fail("test -e /boot/EFI/Linux/${system.boot.loader.ukiFile}")

  with subtest("The ESP is mounted at /boot"):
    t.assertEqual(machine.succeed("bootctl --print-esp-path").strip(), "/boot")

  with subtest("The deployed image is labelled with its version"):
    config = json.loads(machine.succeed("cfsctl --repo /sysroot/composefs oci inspect --config nixos"))
    t.assertEqual(config["config"]["Labels"]["org.opencontainers.image.version"], "${system.image.version}")

  with subtest("The deployed image contains the UKI and systemd-boot"):
    dump = machine.succeed("cfsctl --repo /sysroot/composefs oci dump nixos")
    t.assertIn("/boot/EFI/Linux/${system.boot.loader.ukiFile} ", dump)
    t.assertIn("/boot/EFI/systemd/systemd-boot${efiArch}.efi ", dump)

  with subtest("The physical root with the repository is at /sysroot"):
    machine.succeed("test -d /sysroot/composefs/images")

  with subtest("/var persists, the rest of the root is transient"):
    t.assertIn("/state/os/default/var", machine.succeed("findmnt --noheadings --output SOURCE /var"))
    machine.succeed("touch /var/persistent /etc/transient")
    machine.shutdown()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("test -e /var/persistent")
    machine.fail("test -e /etc/transient")
''
