# Parse lib/captive-portals.txt into { "<name>" = [ "<addr>" ... ]; }.
#
# dnscrypt-proxy consumes the text file directly (modules/doh.nix passes it as
# captive_portals.map_file), so this is only for tests that need to assert what the map
# hands out. They used to hardcode the addresses, which meant that when
# detectportal.firefox.com moved CDN in July 2026 the tests kept happily asserting the
# dead address -- they were pinning the bug rather than catching it. Deriving from the
# file means an entry can only be updated in one place.
#
# Plain `builtins.readFile` of a source file, so this is not import-from-derivation:
# evaluation stays buildless.
{ lib }:

let
  dataLines = lib.filter (
    l:
    let
      t = lib.trim l;
    in
    t != "" && !(lib.hasPrefix "#" t)
  ) (lib.splitString "\n" (builtins.readFile ./captive-portals.txt));

  # "name   a, b, c" -> { name = [ "a" "b" "c" ]; }
  parseLine =
    l:
    let
      m = builtins.match "([^[:space:]]+)[[:space:]]+(.*)" (lib.trim l);
    in
    assert lib.assertMsg (m != null) "captive-portals.txt: cannot parse line: ${l}";
    {
      ${builtins.elemAt m 0} = map lib.trim (lib.splitString "," (builtins.elemAt m 1));
    };

  byName = lib.foldl' (acc: l: acc // parseLine l) { } dataLines;

  addrsOf =
    name:
    assert lib.assertMsg (byName ? ${name}) "captive-portals.txt: no entry for ${name}";
    byName.${name};

  isIpv6 = addr: lib.hasInfix ":" addr;
in
rec {
  inherit byName;

  # Every address of one family. A test that impersonates a name must own ALL of them,
  # not just one: the client resolves the name through the map and gets the whole set, so
  # any address left unclaimed routes to the test's gateway node, which does not forward
  # -- a blackhole that costs curl (and NetworkManager's connectivity check) a ~130s TCP
  # timeout before it falls back to the next address. detectportal.firefox.com has four
  # per family since the 2026-07-27 Fastly move, so this stopped being hypothetical.
  ipv4sOf =
    name:
    let
      v4 = lib.filter (a: !isIpv6 a) (addrsOf name);
    in
    assert lib.assertMsg (v4 != [ ]) "captive-portals.txt: ${name} has no IPv4 address";
    v4;

  ipv6sOf =
    name:
    let
      v6 = lib.filter isIpv6 (addrsOf name);
    in
    assert lib.assertMsg (v6 != [ ]) "captive-portals.txt: ${name} has no IPv6 address";
    v6;

  # First address of each family, for assertions that only need one representative answer
  # (e.g. a `dig | grep` sanity gate). First rather than arbitrary so the choice is stable
  # across edits to the rest of the line. Do NOT use these to decide what a node binds --
  # see ipv4sOf/ipv6sOf above.
  ipv4Of = name: builtins.head (ipv4sOf name);
  ipv6Of = name: builtins.head (ipv6sOf name);
}
