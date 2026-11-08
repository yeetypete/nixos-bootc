# Install the system's sealed image with bootc, boot the disk, then switch to
# an update and roll back.
{
  lib,
  nodes,
  machineConfig,
  installAndBoot,
  subtests,
  ...
}:
{
  imports = [ ./common.nix ];

  name = "bootc";

  nodes.machine = {
    imports = [ machineConfig ];
    # Share the update image from the host.
    virtualisation.sharedDirectories.update = {
      source = "${nodes.update.system.build.bootcImage}";
      target = "/run/update";
    };
  };
  # A second version of the system. Its image is used to test `bootc switch`.
  # It is never booted.
  nodes.update = {
    imports = [ machineConfig ];
    system.image.version = lib.mkForce "2";
  };

  testScript = ''
    ${installAndBoot}

    ${subtests}

    def booted_image() -> tuple[str, str]:
      version = machine.succeed(". /etc/os-release && echo $IMAGE_VERSION").strip()
      return bootc_booted()["composefs"]["verity"], version

    with subtest("bootc switches to an update and rolls back"):
      machine.succeed("touch /var/before-update")
      first, version = booted_image()
      t.assertEqual(version, "1")
      machine.succeed("mkdir -p /run/update && mount -t virtiofs -o ro update /run/update")
      machine.succeed("bootc switch --transport oci /run/update:latest >&2")
      machine.shutdown()
      machine.wait_for_unit("multi-user.target")
      second, version = booted_image()
      t.assertEqual(version, "2")
      t.assertNotEqual(first, second)
      machine.succeed("test -e /var/before-update")
      machine.succeed("bootc rollback >&2")
      machine.shutdown()
      machine.wait_for_unit("multi-user.target")
      t.assertEqual(booted_image(), (first, "1"))
  '';
}
