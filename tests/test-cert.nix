# Mint a self-contained test CA + leaf certificate for a set of SANs, for VM
# tests that impersonate a TLS service. Each call produces an independent CA;
# nodes trust it via `security.pki.certificateFiles = [ result.caFile ]`.
#
#   mkCert = import ./test-cert.nix { inherit pkgs; };
#   certs = mkCert { name = "iroh-relay"; sans = [ "use1-1.relay.n0.iroh.link" ]; };
#   # -> { caFile, certFile, keyFile }
#
# `notBefore` / `notAfter` pin the LEAF's validity window, as `[CC]YYMMDDHHMMSSZ`. Both
# default to null, which keeps the 100-year window every existing caller gets.
#
#   mkCert { name = "stale"; sans = [ "x" ]; notBefore = "20200101000000Z";
#            notAfter = "20210101000000Z"; }
#
# This exists so a test can present a certificate that is genuinely outside its validity
# window *while the server holding it keeps a correct clock*. That combination is what makes
# retroactive validation testable against a real daemon: making the server lie about the time
# instead would put it outside its own certificate and it would fail for the wrong reason.
# Only the leaf is parameterised -- webpki does not check a trust anchor's dates, and the CA
# being long-lived is what keeps the failure attributable to the leaf.
{ pkgs }:

{
  name,
  sans,
  notBefore ? null,
  notAfter ? null,
}:

let
  lib = pkgs.lib;
  sanSection = lib.concatStringsSep "\n" (lib.imap1 (i: d: "DNS.${toString i} = ${d}") sans);

  # `-not_after` overrides `-days`, so the two can be passed together, but keeping the default
  # path free of both flags means an unparameterised call produces the same bytes it always did.
  validityArgs =
    if notBefore == null && notAfter == null then
      "-days 36500"
    else
      lib.concatStringsSep " " (
        lib.optional (notBefore != null) "-not_before ${lib.escapeShellArg notBefore}"
        ++ lib.optional (notAfter != null) "-not_after ${lib.escapeShellArg notAfter}"
        # Still needed when only notBefore is pinned: without it openssl falls back to its own
        # 30-day default rather than this helper's 100 years.
        ++ lib.optional (notAfter == null) "-days 36500"
      );
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
      -out $out/leaf.pem ${validityArgs} -extensions v3_req -extfile leaf.cnf -sha256
  '';
in
{
  caFile = "${certs}/ca.pem";
  certFile = "${certs}/leaf.pem";
  keyFile = "${certs}/leaf-key.pem";
}
