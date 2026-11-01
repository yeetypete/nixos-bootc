{
  lib,
  rustPlatform,
  fetchCrate,
  pkg-config,
  openssl,
  versionCheckHook,
  nix-update-script,
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "composefs-setup-root";
  version = "0.9.4";

  # Upstream does not include a lock file.
  src = fetchCrate {
    inherit (finalAttrs) pname version;
    hash = "sha256-+gumyLEESNlz2/URtrPAbEdpgdTkTXCcWA+yjnoKeRs=";
  };

  cargoHash = "sha256-WE4etJ9Jr6/qoygx0rDCjgQbOdsvU/NvjHL2EwByJkE=";

  # Mount sysroot, etc and var into the transient overlay.
  # TODO: Upstream this.
  patches = [ ./transient-root.patch ];

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];

  nativeInstallCheckInputs = [ versionCheckHook ];
  doInstallCheck = true;

  passthru.updateScript = nix-update-script { };

  meta = {
    description = "Initramfs setup tool for composefs";
    homepage = "https://github.com/containers/composefs-rs";
    changelog = "https://github.com/containers/composefs-rs/releases/tag/v${finalAttrs.version}";
    license = with lib.licenses; [
      mit
      asl20
    ];
    mainProgram = "composefs-setup-root";
    platforms = lib.platforms.linux;
  };
})
