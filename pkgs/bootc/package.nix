{
  lib,
  bootc,
  fetchFromGitHub,
  rustPlatform,
  makeWrapper,
  dosfstools,
  e2fsprogs,
  podman,
  skopeo,
  systemd,
  util-linux,
  withPre615 ? true,
}:

bootc.overrideAttrs (
  finalAttrs: previousAttrs: {
    # TODO: Switch to the next tagged release.
    version = "1.17.4-unstable-2026-11-06";

    src = fetchFromGitHub {
      owner = "bootc-dev";
      repo = "bootc";
      rev = "00574d53bd49525cf1f6a58aa0ac259eaef443b3";
      hash = "sha256-xuAhJunCU7uOPVmvplAVYkfWF40nlB6vQYqCETG9X2k=";
    };
    cargoDeps = rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) src;
      hash = "sha256-IyiYtqiopvIinkQs0pUanAUj7vwqD4duRxMghYSbxAU=";
    };
    # nixpkgs' patch for 1.6.0 is already in this version.
    patches = [ ];

    cargoBuildNoDefaultFeatures = true;
    cargoBuildFeatures = [ "install-to-disk" ] ++ lib.optional withPre615 "pre-6.15";
    cargoBuildFlags = previousAttrs.cargoBuildFlags ++ [
      "-p"
      "bootc-initramfs-setup"
    ];
    # The tests build the default features, which need SELinux.
    doCheck = false;
    doInstallCheck = false;

    outputs = [
      "out"
      "initramfs"
    ];
    nativeBuildInputs = previousAttrs.nativeBuildInputs ++ [ makeWrapper ];

    postInstall = (previousAttrs.postInstall or "") + ''
      moveToOutput bin/bootc-initramfs-setup "$initramfs"
      install -D -m 0644 -t $initramfs/lib/systemd/system crates/initramfs/bootc-root-setup.service
      substituteInPlace $initramfs/lib/systemd/system/bootc-root-setup.service \
        --replace-fail /usr/lib/bootc/initramfs-setup $initramfs/bin/bootc-initramfs-setup

      # Install systemd units the composefs backend uses.
      install -D -m 0644 -t $out/lib/systemd/system \
        systemd/bootc-finalize-staged.service \
        systemd/bootc-finalize-staged-hold.service
      substituteInPlace $out/lib/systemd/system/*.service \
        --replace-fail /usr/bin/bootc $out/bin/bootc
    '';

    postFixup = (previousAttrs.postFixup or "") + ''
      wrapProgram $out/bin/bootc --prefix PATH : ${
        lib.makeBinPath [
          dosfstools
          e2fsprogs
          podman
          skopeo
          systemd
          util-linux
        ]
      }
    '';
  }
)
