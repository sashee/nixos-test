# Eval-only guard on lib/doh-stamps.nix `providers` as seen by modules/time-sync.nix -- the
# `--doh NAME=HOSTNAME@ADDR[,ADDR]` arguments the correction service is handed.
#
# tests/doh-endpoints.nix guards the sibling `endpoints` attrset, and deliberately never parses
# an address: everything downstream of it is a `sdns://` stamp, where an unparseable address
# fails visibly at dnscrypt-proxy startup. `providers` now has a second consumer with different
# rules, and its failures are quiet:
#
#   * modules/time-sync.nix reads `p.v4` unconditionally, so a provider offering only IPv6 is a
#     bare `attribute 'v4' missing` from inside a nixpkgs internal rather than anything that
#     names the file at fault;
#   * a malformed address reaches the binary verbatim and is rejected only at runtime, which
#     means time-correction.service failing on every host, once an hour, forever -- and on the
#     RTC-less Pi that is the difference between a clock and no clock;
#   * BRACKETING is the sharp one. `endpoints` brackets its IPv6 addresses because a stamp is a
#     dial target; `providers` must not, because Rust's `IpAddr` rejects `[...]`. Someone
#     "fixing" providers to match the bracketing rule that endpoints genuinely has would break
#     every IPv6 endpoint for time-correction while dnscrypt-proxy kept working over IPv4 --
#     exactly the invisible-on-a-v4-host failure tests/doh-endpoints.nix:7-9 exists to prevent,
#     reproduced one layer up;
#   * `=`, `@` and `,` are the spec's own separators, so one appearing in a name, hostname or
#     address silently reshapes the argument into a different provider than intended.
#
# The address checks are shape checks, not an RFC-complete parser: they are calibrated to
# reject what `IpAddr::from_str` rejects (brackets, whitespace, empty, wrong family, leading
# zeros) rather than to accept exactly what it accepts.
#
# Fails with `throw` during evaluation rather than at build time, and reads a source file
# rather than a derivation, so this stays usable from a pure `nix flake check`.
{ pkgs, dohStamps }:

let
  lib = pkgs.lib;

  providers = dohStamps.providers;
  names = builtins.attrNames providers;

  chars = lib.stringToCharacters;
  allOf = pred: s: s != "" && lib.all pred (chars s);
  digit = c: lib.elem c (chars "0123456789");
  hex = c: lib.elem c (chars "0123456789abcdefABCDEF");

  # Leading zeros are rejected on purpose: `IpAddr::from_str` rejects them too, and elsewhere
  # they are read as octal, so "010.1.1.1" is exactly the kind of entry that means two
  # different addresses to two different readers.
  octetOk = s: allOf digit s && (s == "0" || !(lib.hasPrefix "0" s)) && lib.toInt s <= 255;
  ipv4Ok =
    a:
    let
      parts = lib.splitString "." a;
    in
    builtins.length parts == 4 && lib.all octetOk parts;

  # An empty group is how `::` shows up after splitting, so it is allowed; everything else must
  # be one to four hex digits.
  groupOk = g: g == "" || (lib.stringLength g <= 4 && allOf hex g);
  ipv6Ok =
    a:
    let
      parts = lib.splitString ":" a;
    in
    lib.hasInfix ":" a
    && builtins.length parts >= 3
    && builtins.length parts <= 9
    && lib.all groupOk parts;

  bracketed = a: lib.hasPrefix "[" a || lib.hasSuffix "]" a;
  # The three characters the spec is delimited by, plus whitespace, which survives Nix string
  # interpolation and reaches the binary intact.
  clean = s: !(lib.any (c: lib.hasInfix c s) [ "=" "@" "," " " "\t" "\n" ]);

  addressDrift =
    name: label: family: a:
    lib.optional (bracketed a)
      "${name}: ${label} ${a} is bracketed; endpoints brackets its addresses because a stamp is a dial target, providers must not because IpAddr rejects it"
    ++ lib.optional (!(clean a)) "${name}: ${label} ${a} contains a separator or whitespace"
    ++ lib.optional (family == "ipv4" && !(ipv4Ok a)) "${name}: ${label} ${a} is not a plain IPv4 literal"
    ++ lib.optional (family == "ipv6" && !(ipv6Ok a)) "${name}: ${label} ${a} is not a plain IPv6 literal";

  providerDrift = lib.concatMap (
    name:
    let
      p = providers.${name};
    in
    lib.optional (!(p ? v4))
      "${name}: no v4 address; modules/time-sync.nix reads p.v4 unconditionally, so this is an unnamed eval error rather than a message"
    ++ lib.optional (!(p ? hostname) || p.hostname == "") "${name}: missing or empty hostname"
    ++ lib.optional (!(clean name)) "${name}: provider name contains a separator or whitespace"
    ++ lib.optional (p ? hostname && !(clean p.hostname)) "${name}: hostname ${p.hostname} contains a separator or whitespace"
    ++ lib.optionals (p ? v4) (addressDrift name "v4" "ipv4" p.v4)
    ++ lib.optionals (p ? v6) (addressDrift name "v6" "ipv6" p.v6)
  ) names;

  # The generated argument, reconstructed and taken apart again. Everything above checks the
  # inputs; this checks the thing actually handed to the binary, so a change to how
  # modules/time-sync.nix assembles the string is caught by the same guard as a change to the
  # data it assembles from.
  specDrift = lib.concatMap (
    name:
    let
      p = providers.${name};
      addresses = [ p.v4 ] ++ lib.optional (p ? v6) p.v6;
      spec = "${name}=${p.hostname}@${lib.concatStringsSep "," addresses}";
      halves = lib.splitString "=" spec;
      afterName = lib.concatStringsSep "=" (builtins.tail halves);
      atParts = lib.splitString "@" afterName;
      parsed = {
        name = builtins.head halves;
        hostname = builtins.head atParts;
        addresses = lib.splitString "," (lib.concatStringsSep "@" (builtins.tail atParts));
      };
    in
    lib.optional (!(p ? v4)) "${name}: cannot build a spec without a v4 address"
    ++ lib.optionals (p ? v4) (
      lib.optional (parsed.name != name || parsed.hostname != p.hostname || parsed.addresses != addresses)
        "${name}: the generated spec ${spec} does not read back as the values it was built from (got ${parsed.name} / ${parsed.hostname} / ${toString parsed.addresses})"
    )
  ) names;

  countDrift = lib.optional (
    builtins.length names < 2
  ) "only ${toString (builtins.length names)} provider(s) (${toString names}): the correction service samples two and requires both to agree, so fewer than two can never set a clock";

  errors = providerDrift ++ specDrift ++ countDrift;
in
if errors != [ ] then
  throw ''
    lib/doh-stamps.nix providers are malformed for modules/time-sync.nix.

    ${lib.concatStringsSep "\n  " errors}

    These become the --doh arguments of time-correction.service on every host. A bad entry
    does not fail the build: it fails on every run of the service, on the one host that has no
    other way to learn what time it is, and it keeps failing until someone fixes the entry.
  ''
else
  pkgs.runCommand "doh-providers-check" { } ''
    echo "${toString (builtins.length names)} DoH providers usable as time-correction sources" > $out
  ''
