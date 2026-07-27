# Golden test for the pure-Nix DNS stamp encoder (lib/doh-stamp-encode.nix).
#
# Eval-only: fails with `throw` during evaluation rather than at build time, so a wrong
# stamp never reaches a VM test or a deploy. No import-from-derivation, so this stays
# usable from a pure `nix flake check`.
#
# The eight expected values below are the literals that lib/doh-stamps.nix held before the
# components became the source of truth. They are known-good -- the rpi5 and both laptops
# resolved DNS through exactly these stamps for months -- so byte-exact reproduction is
# what proves the encoder.
#
# This also covers the props trap for free: props=4 encodes as the `AgQAAAAAAAAA` prefix,
# and emitting 0 instead would produce `AgAAAAAAAAAA` and fail here. That matters because
# modules/doh.nix sets require_nofilter = true, which filters the server pool on props bit
# 2 -- a zero there would silently drop every upstream and leave the host with no DNS.
{ pkgs, dohStamps }:

let
  lib = pkgs.lib;
  enc = import ../lib/doh-stamp-encode.nix { inherit lib; };

  expected = {
    cloudflare-ipv4 = "sdns://AgQAAAAAAAAABzEuMS4xLjEAEmNsb3VkZmxhcmUtZG5zLmNvbQovZG5zLXF1ZXJ5";
    cloudflare-ipv6 = "sdns://AgQAAAAAAAAAFlsyNjA2OjQ3MDA6NDcwMDo6MTExMV0AEmNsb3VkZmxhcmUtZG5zLmNvbQovZG5zLXF1ZXJ5";
    mullvad-ipv4 = "sdns://AgQAAAAAAAAACzE5NC4yNDIuMi4yABRiYXNlLmRucy5tdWxsdmFkLm5ldAovZG5zLXF1ZXJ5";
    mullvad-ipv6 = "sdns://AgQAAAAAAAAADlsyYTA3OmUzNDA6OjJdABRiYXNlLmRucy5tdWxsdmFkLm5ldAovZG5zLXF1ZXJ5";
    quad9-ipv4 = "sdns://AgQAAAAAAAAACDkuOS45LjEwAA9kbnMxMC5xdWFkOS5uZXQKL2Rucy1xdWVyeQ";
    quad9-ipv6 = "sdns://AgQAAAAAAAAADVsyNjIwOmZlOjoxMF0AD2RuczEwLnF1YWQ5Lm5ldAovZG5zLXF1ZXJ5";
    google-ipv4 = "sdns://AgQAAAAAAAAABzguOC44LjgACmRucy5nb29nbGUKL2Rucy1xdWVyeQ";
    google-ipv6 = "sdns://AgQAAAAAAAAAFlsyMDAxOjQ4NjA6NDg2MDo6ODg4OF0ACmRucy5nb29nbGUKL2Rucy1xdWVyeQ";
  };

  generated = lib.mapAttrs (_: v: v.stamp) dohStamps.stamps;

  # dnscrypt-proxy's server_names is `builtins.attrNames`, so a renamed or dropped entry
  # silently changes which upstreams are eligible. Pin the whole key set, not just values.
  nameDrift =
    let
      got = builtins.attrNames generated;
      want = builtins.attrNames expected;
    in
    lib.optional (got != want) "stamp names drifted: got ${toString got}, want ${toString want}";

  stampDrift = lib.concatMap (
    n:
    let
      got = generated.${n} or "<missing>";
    in
    lib.optional (got != expected.${n}) "${n}:\n    want ${expected.${n}}\n     got ${got}"
  ) (builtins.attrNames expected);

  # base64url tail handling: the three remainder cases (0, 1 and 2 bytes over a multiple
  # of 3) take different code paths, and the eight stamps above do not necessarily cover
  # all of them. [0] also pins the NUL-safety property the whole design rests on -- a
  # zero byte must survive encoding, which it only does because it never becomes part of
  # a Nix string.
  b64Vectors = [
    { bytes = [ ]; want = ""; }
    { bytes = [ 102 ]; want = "Zg"; }                    # "f"
    { bytes = [ 102 111 ]; want = "Zm8"; }               # "fo"
    { bytes = [ 102 111 111 ]; want = "Zm9v"; }          # "foo"
    { bytes = [ 0 ]; want = "AA"; }                      # NUL survives
    { bytes = [ 0 0 0 ]; want = "AAAA"; }
    { bytes = [ 255 255 255 ]; want = "____"; }          # base64url alphabet, not "+/"
  ];

  b64Drift = lib.concatMap (
    v:
    let
      got = enc.base64urlUnpadded v.bytes;
    in
    lib.optional (got != v.want) "base64url ${toString v.bytes}: want ${v.want}, got ${got}"
  ) b64Vectors;

  errors = nameDrift ++ stampDrift ++ b64Drift;
in
if errors != [ ] then
  throw ''
    doh stamp encoder produced unexpected output.

    ${lib.concatStringsSep "\n  " errors}

    lib/doh-stamps.nix components must still encode to the stamps dnscrypt-proxy was
    verified against. If an upstream genuinely changed, update `expected` here in the
    same commit and say why -- and re-verify DNS still resolves on a real host, because
    a bad props value disables every server rather than erroring.
  ''
else
  pkgs.runCommand "doh-stamp-encode-golden" { } ''
    echo "8 stamps + ${toString (builtins.length b64Vectors)} base64url vectors verified" > $out
  ''
