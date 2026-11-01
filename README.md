# nixos-composefs

Boot NixOS from sealed composefs images.

nixos-composefs builds your NixOS system into a sealed image and mounts it as
its root filesystem with [composefs](https://github.com/containers/composefs-rs).
Combined with
[fs-verity](https://www.kernel.org/doc/html/latest/filesystems/fsverity.html)
and a digest embedded in the UKI, this provides cryptographic verification of
the entire filesystem tree.

Advantages over
[`image.repart.verityStore`](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/image/repart-verity-store.nix)
([dm-verity](https://docs.kernel.org/admin-guide/device-mapper/verity.html)):

- No fixed partition layout: image sizes and the number of images kept can
  be changed after partitioning, limited only by free disk space.
- Deduplication: files with identical content across images share a single
  copy on disk and in the page cache.
- Switch or roll back to any number of generations, not only the previous
  one.
- NixOS systems are represented as standard OCI images. Existing tooling and
  infrastructure for container images, such as registries, signing and
  transports, can all be leveraged.

> [!WARNING]
> This NixOS module is experimental and is still a work in progress.

## How it works

At build time, the module:

1. Builds the system's closure as an OCI image.
2. Computes its composefs digest.
3. Builds a UKI whose kernel command line holds the digest.
4. Seals the image by adding the UKI to `/boot`. The result is
   `system.build.composefsImage`, an OCI image layout.

At boot, systemd-boot starts the UKI. In the initrd,
[composefs-setup-root](pkgs/composefs-setup-root) mounts the image matching the
UKI's digest as the root filesystem, overlaid with a tmpfs. The partition
holding the composefs repository is mounted at `/sysroot`. This is where
updates add new images, and where `/var` preserves application state across
boots and updates.

```txt
ESP
└── EFI/
    ├── BOOT/BOOTX64.EFI      systemd-boot
    └── Linux/nixos.efi       UKI, with composefs.digest= in kernel command line
root partition (e.g. ext4 with fs-verity enabled)
├── composefs/                composefs repository containing the images and their files
└── state/
    ├── deploy/<digest>/      per-image /etc and /var state (unused by default)
    └── os/default/var/       /var, shared by all images
```

## Usage

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.nixos-composefs.url = "github:yeetypete/nixos-composefs";
  inputs.nixos-composefs.inputs.nixpkgs.follows = "nixpkgs";

  outputs =
    { nixpkgs, nixos-composefs, ... }:
    {
      nixosConfigurations.robot = nixpkgs.lib.nixosSystem {
        modules = [
          nixos-composefs.nixosModules.default
          { boot.composefs.enable = true; }
          ./configuration.nix
        ];
      };
    };
}
```

Build the sealed image as an OCI image layout:

```sh
nix build .#nixosConfigurations.robot.config.system.build.composefsImage
```

See [`examples/sealed-root.nix`](examples/sealed-root.nix) for a minimal
working configuration.

## Notes about state

All state outside of `/var` (including `/etc`) is reset or recreated on every
boot. Not all NixOS modules store their state in `/var` by default. Some need
to be configured to do this, for example:

- SSH host keys:

  ```nix
  services.openssh.hostKeys = [
    {
      path = "/var/lib/ssh/ssh_host_ed25519_key";
      type = "ed25519";
    }
  ];
  ```

- The machine ID, which otherwise would be regenerated on every boot. If the
  firmware reports a unique product UUID, you may set:

  ```nix
  boot.kernelParams = [ "systemd.machine_id=firmware" ];
  ```

- User passwords. [userborn](https://github.com/nikstur/userborn) should be
  used to keep password files in `/var`:

  ```nix
  services.userborn = {
    enable = true;
    passwordFilesLocation = "/var/lib/nixos";
  };
  ```

Alternatively, [preservation](https://github.com/nix-community/preservation)
or [impermanence](https://github.com/nix-community/impermanence) can persist
such paths from a directory in `/var`. TODO: Test this.

## Roadmap

- [x] Sealed image, digest and UKI.
- [x] Transient root over the composefs image with persistent `/var`.
- [x] VM test booting a deployed disk.
- [ ] Rust update client: deploy images, boot counting with [systemd-boot](https://systemd.io/AUTOMATIC_BOOT_ASSESSMENT/), rollback.
- [ ] Create flashable disk images with [`image.repart`](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/image/repart.nix).
- [ ] TPM-bound encryption of the root partition.
- [ ] Immutable `/etc` with `system.etc.overlay` setting.
- [ ] Fully read-only root without a transient overlay.
- [ ] Hook for Secure Boot signing.
- [ ] Upstream [composefs-setup-root bugfix](https://github.com/yeetypete/composefs-rs/commit/122fad2b8da6faaa57b7c8a4fc2ffc902ff72500).
- [ ] Upstream to nixpkgs?

## Development

```sh
nix fmt          # format
nix flake check  # build and run VM tests
```

## License

`nixos-composefs` is released under the [MIT License](LICENSE).
