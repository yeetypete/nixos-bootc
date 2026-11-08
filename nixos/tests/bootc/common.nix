{ nodes, ... }:
let
  inherit (nodes.machine) system;
in
{
  nodes.installer = {
    virtualisation = {
      emptyDiskImages = [ 8192 ];
      memorySize = 4096;
      containers.enable = true;
    };
    environment.systemPackages = [ nodes.machine.boot.bootc.package ];
  };

  _module.args = {
    machineConfig =
      { lib, ... }:
      {
        imports = [
          ../../modules/bootc.nix
          ../../../examples/sealed-root.nix
        ];

        virtualisation = {
          directBoot.enable = false;
          mountHostNixStore = false;
          useEFIBoot = true;
          fileSystems = lib.mkForce { };
        };
      };

    # Install the machine's sealed image on a disk with bootc, and boot it.
    installAndBoot = ''
      import os

      installer.start()
      installer.wait_for_unit("multi-user.target")
      installer.succeed(
        "bootc install to-disk"
        " --source-imgref oci:${system.build.bootcImage}:latest"
        " --target-imgref localhost/nixos:latest"
        " --composefs-backend --filesystem ext4 --bootloader systemd"
        " --generic-image /dev/vdb >&2",
      )
      installer.shutdown()
      os.environ["NIX_DISK_IMAGE"] = str(installer.state_dir / "empty0.qcow2")

      # With Secure Boot, systemd-boot enrolls the keys and reboots.
      machine.start(allow_reboot=True)
      machine.wait_for_unit("multi-user.target")
    '';

    subtests = ''
      import json
      from pathlib import Path
      from typing import Any

      def bootc_booted() -> dict[str, Any]:
        return json.loads(machine.succeed("bootc status --format json"))["status"]["booted"]

      with subtest("The system is running"):
        _, state = machine.execute("systemctl is-system-running --wait")
        t.assertEqual(state.strip(), "running", machine.succeed("systemctl --failed --no-legend"))

      with subtest("Root is a transient overlay of the composefs image"):
        digest = Path("${system.build.composefsDigest}").read_text().strip()
        t.assertIn(f"composefs.digest=v1-sha512-12:{digest}", machine.succeed("cat /proc/cmdline"))
        t.assertEqual(
          machine.succeed("findmnt --noheadings --output FSTYPE,SOURCE /").split(),
          ["overlay", f"transient:composefs={digest}"],
        )

      with subtest("bootc booted the UKI it installed"):
        booted = bootc_booted()
        t.assertEqual(booted["composefs"]["bootType"].lower(), "uki")
        t.assertEqual(booted["composefs"]["verity"], digest)
        machine.succeed(f"test -e /boot/EFI/Linux/bootc/bootc_composefs-{digest}.efi")

      with subtest("The deployed image is labelled with its version"):
        t.assertEqual(bootc_booted()["image"]["version"], "${system.image.version}")

      with subtest("The physical root with the repository is read-only at /sysroot"):
        machine.succeed("test -d /sysroot/composefs/images")
        t.assertIn("ro", machine.succeed("findmnt --noheadings --output OPTIONS /sysroot").strip().split(","))
        machine.fail("rm -rf /sysroot/state")
        machine.succeed("test -d /sysroot/state/deploy")

      with subtest("/var is persistent, the rest of the root is transient"):
        t.assertIn("/state/os/default/var", machine.succeed("findmnt --noheadings --output SOURCE /var"))
        machine.succeed("touch /var/persistent /etc/transient")
        machine.shutdown()
        machine.wait_for_unit("multi-user.target")
        machine.succeed("test -e /var/persistent")
        machine.fail("test -e /etc/transient")
    '';
  };
}
