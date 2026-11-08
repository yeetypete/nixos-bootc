# Boot the machine from the Secure Boot test and open a root shell in it.
{
  lib,
  hostPkgs,
  installAndBoot,
  ...
}:
{
  imports = [ ./secure-boot.nix ];

  name = lib.mkForce "bootc-shell";

  sshBackdoor.enable = true;

  testScript = lib.mkForce ''
    ${installAndBoot}

    import subprocess

    serial_stdout_off()

    subprocess.run([
      "${lib.getExe hostPkgs.openssh_gssapi}", f"vsock-mux/{machine.vsock_host}",
      "-o", "User=root",
      "-F", "${hostPkgs.systemd}/lib/systemd/ssh_config.d/20-systemd-ssh-proxy.conf",
    ])
  '';
}
