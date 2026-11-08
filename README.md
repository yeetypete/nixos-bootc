# nixos-bootc

Boot NixOS from sealed [bootc](https://github.com/bootc-dev/bootc) images.

nixos-bootc builds your NixOS system into a sealed bootc image, which bootc
installs, updates and boots with its
[composefs backend](https://bootc.dev/bootc/bootc-composefs.html).
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
- Installs, updates and rollback are handled by bootc.
- NixOS systems are represented as OCI images. Existing tooling and
  infrastructure for container images, such as registries, signing and
  transports, can all be leveraged.

> [!WARNING]
> This NixOS module is experimental and is still a work in progress.

## How it works

At build time, the module:

1. Builds the system's closure as a bootc image.
2. Computes the image's digest.
3. Builds a UKI whose kernel command line holds the digest.
4. Seals the image by adding the UKI to `/boot`, optionally signed for Secure
   Boot. The result is `system.build.bootcImage`, an OCI image layout.

`bootc install` then deploys the image to a disk. At boot, systemd-boot starts
the UKI. In the initrd, `bootc-root-setup.service` mounts the image matching
the UKI's digest as the root filesystem, overlaid with a tmpfs. The physical
root is mounted read-only at `/sysroot`. This is where bootc adds new images,
and where `/var` preserves application state across boots and updates.

```txt
ESP
└── EFI/
    ├── BOOT/BOOTX64.EFI           systemd-boot
    └── Linux/bootc/bootc_composefs-<digest>.efi  UKI, with composefs.digest= in kernel command line
root partition (e.g. ext4 with fs-verity enabled)  mounted at /sysroot
├── composefs/                     the images and their files
└── state/
    ├── deploy/<digest>/           per-image state: /etc (unused by default), var -> ../../os/default/var
    └── os/default/var/            /var, shared by all images
```

## Usage

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.nixos-bootc.url = "github:yeetypete/nixos-bootc";
  inputs.nixos-bootc.inputs.nixpkgs.follows = "nixpkgs";

  outputs =
    { nixpkgs, nixos-bootc, ... }:
    {
      nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
        modules = [
          nixos-bootc.nixosModules.default
          { boot.bootc.enable = true; }
          ./configuration.nix
        ];
      };
    };
}
```

Build the sealed image as an OCI image layout:

```sh
nix build .#nixosConfigurations.myhost.config.system.build.bootcImage
```

See [`examples/sealed-root.nix`](examples/sealed-root.nix) for a minimal
working configuration.

Install it on a disk with the image's bootc. The host needs
`/etc/containers/policy.json`, e.g. from `virtualisation.containers.enable`.

```sh
sudo nix run .#nixosConfigurations.myhost.config.boot.bootc.package -- \
  install to-disk --source-imgref oci:./result:latest --composefs-backend \
  --filesystem ext4 --bootloader systemd --generic-image --wipe /dev/sdX
```

For later updates, push a new image to a registry and switch to it on the
installed system:

```sh
skopeo copy oci:./result:latest docker://registry.example.com/os:latest
bootc switch registry.example.com/os:latest
```

## Secure Boot

The UKI and systemd-boot can be signed for Secure Boot without the private key
in the build, using `boot.bootc.secureBoot`. See
[`nixos/tests/bootc/secure-boot.nix`](nixos/tests/bootc/secure-boot.nix) for an
example. TODO: document this.

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
- [x] Transient root over the image with persistent `/var`.
- [x] VM test booting a deployed disk.
- [x] Offline Secure Boot signing of the UKI and systemd-boot.
- [ ] Enroll Microsoft's certificates along with the db certificate.
- [ ] Automatic rollback: bootc does not support [boot counting](https://systemd.io/AUTOMATIC_BOOT_ASSESSMENT/) with the composefs backend yet.
- [ ] Create flashable disk images with [`image.repart`](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/image/repart.nix).
- [ ] TPM-bound encryption of the root partition.
- [ ] Immutable `/etc` with `system.etc.overlay` setting.
- [ ] Fully read-only root without a transient overlay.
- [ ] Upstream to nixpkgs?

## Development

```sh
nix fmt          # format
nix flake check  # build and run VM tests
nix run .#vm     # boot the Secure Boot VM and open a root shell
nix run .#dive   # inspect the example image's layers with dive
```

## License

`nixos-bootc` is released under the [MIT License](LICENSE).
