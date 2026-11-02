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
4. Seals the image by adding the UKI and systemd-boot to `/boot`, optionally
   signed for Secure Boot. The result is `system.build.composefsImage`, an OCI
   image layout.

At boot, systemd-boot starts the UKI. In the initrd,
[composefs-setup-root](pkgs/composefs-setup-root) mounts the image matching the
UKI's digest as the root filesystem, overlaid with a tmpfs. The partition
holding the composefs repository is mounted at `/sysroot`. This is where
updates add new images, and where `/var` preserves application state across
boots and updates.

```txt
ESP
└── EFI/
    ├── BOOT/BOOTX64.EFI           systemd-boot
    └── Linux/nixos_<version>.efi  UKI, with composefs.digest= in kernel command line
root partition (e.g. ext4 with fs-verity enabled)  mounted at /sysroot
├── composefs/                     composefs repository containing the images and their files
└── state/
    ├── deploy/<digest>/           per-image /etc and /var state (unused by default)
    └── os/default/var/            /var, shared by all images
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

## Secure Boot

The UKI and systemd-boot can be signed for Secure Boot without the private key
in the build. The build prepares the data to sign, and attaches signatures
made outside of Nix with
[systemd-sbsign](https://www.freedesktop.org/software/systemd/man/latest/systemd-sbsign.html):

1. Enable Secure Boot, setting the paths to the db certificate and to where
   the signatures will be after signing (step 3):

   ```nix
   boot.composefs.secureBoot = {
     enable = true;
     certificate = ./secureboot/db.pem;
     signatures = {
       uki = ./secureboot/uki.sig;
       systemd-boot = ./secureboot/systemd-boot.sig;
     };
   };
   ```

2. Build the data to sign:

   ```sh
   nix build .#nixosConfigurations.robot.config.system.build.composefsSignedData
   ```

3. Sign it, e.g. with an HSM, a cloud KMS or OpenSSL:

   ```sh
   openssl dgst -sha256 -sign db.key -out secureboot/uki.sig result/uki
   openssl dgst -sha256 -sign db.key -out secureboot/systemd-boot.sig result/systemd-boot
   ```

4. Build the image. The signatures are first verified and then attached to the binaries.

Notes:

- `db.key` is the private key. It is only needed for signing and stays outside
  of Nix.
- The db certificate must be enrolled in the firmware, e.g. by systemd-boot
  (see
  [loader.conf(5)](https://www.freedesktop.org/software/systemd/man/latest/loader.conf.html)).

> [!WARNING]
> Enrolling your keys replaces existing keys in the UEFI firmware. Without
> Microsoft's certificates, firmware of hardware such as graphics cards may no
> longer load. This can soft-brick a device.

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
- [x] Offline Secure Boot signing of the UKI and systemd-boot.
- [ ] Enroll Microsoft's certificates along with the db certificate.
- [ ] Rust update client: deploy images, boot counting with [systemd-boot](https://systemd.io/AUTOMATIC_BOOT_ASSESSMENT/), rollback.
- [ ] Create flashable disk images with [`image.repart`](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/image/repart.nix).
- [ ] TPM-bound encryption of the root partition.
- [ ] Immutable `/etc` with `system.etc.overlay` setting.
- [ ] Fully read-only root without a transient overlay.
- [ ] Upstream [composefs-setup-root bugfix](https://github.com/yeetypete/composefs-rs/commit/122fad2b8da6faaa57b7c8a4fc2ffc902ff72500).
- [ ] Upstream to nixpkgs?

## Development

```sh
nix fmt          # format
nix flake check  # build and run VM tests
```

## License

`nixos-composefs` is released under the [MIT License](LICENSE).
