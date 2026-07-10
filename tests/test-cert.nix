# Mint a self-contained test CA + leaf certificate for a set of SANs, for VM
# tests that impersonate a TLS service. Each call produces an independent CA;
# nodes trust it via `security.pki.certificateFiles = [ result.caFile ]`.
#
#   mkCert = import ./test-cert.nix { inherit pkgs; };
#   certs = mkCert { name = "iroh-relay"; sans = [ "use1-1.relay.n0.iroh.link" ]; };
#   # -> { caFile, certFile, keyFile }
{ pkgs }:

{ name, sans }:

let
  lib = pkgs.lib;
  sanSection = lib.concatStringsSep "\n" (lib.imap1 (i: d: "DNS.${toString i} = ${d}") sans);
  certs = pkgs.runCommand "${name}-certs" {
    nativeBuildInputs = [ pkgs.openssl ];
  } ''
    mkdir -p $out
    cat > ca.cnf <<'EOF'
    [ req ]
    distinguished_name = dn
    x509_extensions = v3_ca
    prompt = no
    [ dn ]
    CN = ${name} test CA
    [ v3_ca ]
    basicConstraints = critical, CA:true
    keyUsage = critical, keyCertSign, cRLSign
    EOF
    openssl req -x509 -newkey rsa:2048 -nodes -days 36500 -keyout $out/ca-key.pem -out $out/ca.pem -config ca.cnf -sha256

    cat > leaf.cnf <<'EOF'
    [ req ]
    distinguished_name = dn
    req_extensions = v3_req
    prompt = no
    [ dn ]
    CN = ${builtins.head sans}
    [ v3_req ]
    basicConstraints = CA:false
    keyUsage = critical, digitalSignature, keyEncipherment
    extendedKeyUsage = serverAuth
    subjectAltName = @alt
    [ alt ]
    ${sanSection}
    EOF
    openssl req -newkey rsa:2048 -nodes -keyout $out/leaf-key.pem -out leaf.csr -config leaf.cnf -sha256
    openssl x509 -req -in leaf.csr -CA $out/ca.pem -CAkey $out/ca-key.pem -CAcreateserial \
      -out $out/leaf.pem -days 36500 -extensions v3_req -extfile leaf.cnf -sha256
  '';
in
{
  caFile = "${certs}/ca.pem";
  certFile = "${certs}/leaf.pem";
  keyFile = "${certs}/leaf-key.pem";
}
