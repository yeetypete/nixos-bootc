{
  lib,
  rustPlatform,
  fetchCrate,
  pkg-config,
  installShellFiles,
  openssl,
  versionCheckHook,
  nix-update-script,
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "composefs-ctl";
  version = "0.9.4";

  # Upstream does not include a lock file.
  src = fetchCrate {
    inherit (finalAttrs) pname version;
    hash = "sha256-XDWWswGmILex7+po++VGaApUHdXUOptCbFIDB9IN7/Y=";
  };

  cargoHash = "sha256-rBcbfBBdbCp4WvhzPYEvL45v9oXybXawjfb7Y8c0PPQ=";

  nativeBuildInputs = [
    pkg-config
    installShellFiles
  ];
  buildInputs = [ openssl ];

  postInstall = ''
    installShellCompletion --cmd cfsctl --bash cfsctl.bash-completion
  '';

  nativeInstallCheckInputs = [ versionCheckHook ];
  doInstallCheck = true;

  passthru.updateScript = nix-update-script { };

  meta = {
    description = "Command-line utility for composefs";
    homepage = "https://github.com/containers/composefs-rs";
    changelog = "https://github.com/containers/composefs-rs/releases/tag/v${finalAttrs.version}";
    license = with lib.licenses; [
      mit
      asl20
    ];
    mainProgram = "cfsctl";
    platforms = lib.platforms.linux;
  };
})
