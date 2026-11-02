# Throwaway Secure Boot keys for tests. Made as in loader.conf(5).
{
  runCommand,
  openssl,
  sbsigntool,
  systemd,
}:
runCommand "secure-boot-test-keys"
  {
    nativeBuildInputs = [
      openssl
      sbsigntool
      systemd
    ];
  }
  ''
    mkdir -p $out/auto
    cd $out
    uuid=$(systemd-id128 new --uuid)
    for key in PK KEK db; do
      openssl req -new -x509 -nodes -days 3650 -subj "/CN=nixos-composefs test ''${key}/" \
        -keyout "''${key}.key" -out "''${key}.pem"
      openssl x509 -outform DER -in "''${key}.pem" -out "''${key}.der"
      sbsiglist --owner "''${uuid}" --type x509 --output "''${key}.esl" "''${key}.der"
    done
    attr=NON_VOLATILE,RUNTIME_ACCESS,BOOTSERVICE_ACCESS,TIME_BASED_AUTHENTICATED_WRITE_ACCESS
    sbvarsign --attr "''${attr}" --key PK.key --cert PK.pem --output auto/PK.auth PK PK.esl
    sbvarsign --attr "''${attr}" --key PK.key --cert PK.pem --output auto/KEK.auth KEK KEK.esl
    sbvarsign --attr "''${attr}" --key KEK.key --cert KEK.pem --output auto/db.auth db db.esl
  ''
