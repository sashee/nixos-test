# Golden test for the pure-Nix DNS stamp encoder (lib/doh-stamp-encode.nix).
#
# Eval-only: fails with `throw` during evaluation rather than at build time, so a wrong
# stamp never reaches a VM test or a deploy. No import-from-derivation, so this stays
# usable from a pure `nix flake check`.
#
# `golden` below is a frozen corpus, not a copy of the current provider list: these are the
# components and stamps lib/doh-stamps.nix held before the components became the source of
# truth, and they are known-good -- the rpi5 and both laptops resolved DNS through exactly
# these stamps for months. Byte-exact reproduction from the components is what proves the
# encoder, and that proof does not expire when a provider is added, dropped or replaced.
# So the corpus is fed to `mkDohStamp` directly and never re-derived from `dohStamps`;
# adding a provider needs no new literal here.
#
# The live list is still checked, but only where the two overlap: a name in both must still
# encode to the same bytes, which catches an address or hostname edited under an existing
# provider. Whether the key set as a whole is intact belongs to tests/doh-endpoints.nix,
# which pins `stamps` against `endpoints` -- the property `server_names` actually depends on.
#
# This also covers the props trap for free: props=4 encodes as the `AgQAAAAAAAAA` prefix,
# and emitting 0 instead would produce `AgAAAAAAAAAA` and fail here. That matters because
# modules/doh.nix sets require_nofilter = true, which filters the server pool on props bit
# 2 -- a zero there would silently drop every upstream and leave the host with no DNS.
{ pkgs, dohStamps }:

let
  lib = pkgs.lib;
  enc = import ../lib/doh-stamp-encode.nix { inherit lib; };

  # `addr` is what the client dials, so v6 arrives bracketed -- the same shape
  # lib/doh-stamps.nix's `entriesFor` produces.
  golden = {
    cloudflare-ipv4 = {
      hostname = "cloudflare-dns.com";
      addr = "1.1.1.1";
      stamp = "sdns://AgQAAAAAAAAABzEuMS4xLjEAEmNsb3VkZmxhcmUtZG5zLmNvbQovZG5zLXF1ZXJ5";
    };
    cloudflare-ipv6 = {
      hostname = "cloudflare-dns.com";
      addr = "[2606:4700:4700::1111]";
      stamp = "sdns://AgQAAAAAAAAAFlsyNjA2OjQ3MDA6NDcwMDo6MTExMV0AEmNsb3VkZmxhcmUtZG5zLmNvbQovZG5zLXF1ZXJ5";
    };
    mullvad-ipv4 = {
      hostname = "base.dns.mullvad.net";
      addr = "194.242.2.2";
      stamp = "sdns://AgQAAAAAAAAACzE5NC4yNDIuMi4yABRiYXNlLmRucy5tdWxsdmFkLm5ldAovZG5zLXF1ZXJ5";
    };
    mullvad-ipv6 = {
      hostname = "base.dns.mullvad.net";
      addr = "[2a07:e340::2]";
      stamp = "sdns://AgQAAAAAAAAADlsyYTA3OmUzNDA6OjJdABRiYXNlLmRucy5tdWxsdmFkLm5ldAovZG5zLXF1ZXJ5";
    };
    quad9-ipv4 = {
      hostname = "dns10.quad9.net";
      addr = "9.9.9.10";
      stamp = "sdns://AgQAAAAAAAAACDkuOS45LjEwAA9kbnMxMC5xdWFkOS5uZXQKL2Rucy1xdWVyeQ";
    };
    quad9-ipv6 = {
      hostname = "dns10.quad9.net";
      addr = "[2620:fe::10]";
      stamp = "sdns://AgQAAAAAAAAADVsyNjIwOmZlOjoxMF0AD2RuczEwLnF1YWQ5Lm5ldAovZG5zLXF1ZXJ5";
    };
    google-ipv4 = {
      hostname = "dns.google";
      addr = "8.8.8.8";
      stamp = "sdns://AgQAAAAAAAAABzguOC44LjgACmRucy5nb29nbGUKL2Rucy1xdWVyeQ";
    };
    google-ipv6 = {
      hostname = "dns.google";
      addr = "[2001:4860:4860::8888]";
      stamp = "sdns://AgQAAAAAAAAAFlsyMDAxOjQ4NjA6NDg2MDo6ODg4OF0ACmRucy5nb29nbGUKL2Rucy1xdWVyeQ";
    };
  };

  goldenNames = builtins.attrNames golden;

  # The encoder proof: components in, known-good bytes out, with nothing from the live list
  # involved.
  encoderDrift = lib.concatMap (
    n:
    let
      e = golden.${n};
      got = enc.mkDohStamp { inherit (e) addr hostname; };
    in
    lib.optional (got != e.stamp) "${n}:\n    want ${e.stamp}\n     got ${got}"
  ) goldenNames;

  generated = lib.mapAttrs (_: v: v.stamp) dohStamps.stamps;

  # Where the corpus and the deployed list still name the same endpoint, they must agree.
  # An endpoint the corpus does not know is a new provider, which is fine and needs no
  # literal; a disagreement is an edited address or hostname under a name that already
  # shipped, which is not.
  liveDrift = lib.concatMap (
    n:
    let
      got = generated.${n};
    in
    lib.optional (got != golden.${n}.stamp)
      "${n} in lib/doh-stamps.nix no longer encodes to the stamp that shipped under that name:\n    was ${golden.${n}.stamp}\n    now ${got}"
  ) (lib.filter (n: generated ? ${n}) goldenNames);

  # base64url tail handling: the three remainder cases (0, 1 and 2 bytes over a multiple
  # of 3) take different code paths, and the stamps above do not necessarily cover all of
  # them. [0] also pins the NUL-safety property the whole design rests on -- a zero byte
  # must survive encoding, which it only does because it never becomes part of a Nix string.
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

  errors = encoderDrift ++ liveDrift ++ b64Drift;
in
if errors != [ ] then
  throw ''
    doh stamp encoder produced unexpected output.

    ${lib.concatStringsSep "\n  " errors}

    The `golden` corpus above is frozen known-good output and is not to be adjusted to
    match a new encoder result -- a mismatch there means the encoder changed. A mismatch
    against lib/doh-stamps.nix means an endpoint that already shipped was edited in place;
    if that is deliberate, drop the stale name from `golden` in the same commit and say why
    -- and re-verify DNS still resolves on a real host, because a bad props value disables
    every server rather than erroring.
  ''
else
  pkgs.runCommand "doh-stamp-encode-golden" { } ''
    echo "${toString (builtins.length goldenNames)} golden stamps + ${toString (builtins.length b64Vectors)} base64url vectors verified" > $out
  ''
