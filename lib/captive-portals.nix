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

  isIpv6 = addr: lib.hasInfix ":" addr;

  byFamily = lib.mapAttrs (
    _: addrs: {
      ipv4 = lib.filter (a: !isIpv6 a) addrs;
      ipv6 = lib.filter isIpv6 addrs;
    }
  ) byName;

  familyOf =
    name:
    assert lib.assertMsg (byFamily ? ${name}) "captive-portals.txt: no entry for ${name}";
    byFamily.${name};
in
rec {
  inherit byName;

  # The whole map split by address family, with NO assertion that either family is present:
  # several entries are single-family (www.msftconnecttest.com has no AAAA,
  # ipv6.msftconnecttest.com no A). For callers that sweep every entry, i.e.
  # tests/doh-captive.nix. A caller that requires a family to exist wants ipv4sOf/ipv6sOf
  # below instead -- those still fail the build rather than silently asserting nothing.
  inherit byFamily;

  # Every address of one family. A test that impersonates a name must own ALL of them,
  # not just one: the client resolves the name through the map and gets the whole set, so
  # any address left unclaimed routes to the test's gateway node, which does not forward
  # -- a blackhole that costs curl (and NetworkManager's connectivity check) a ~130s TCP
  # timeout before it falls back to the next address. detectportal.firefox.com has four
  # per family since the 2026-07-27 Fastly move, so this stopped being hypothetical.
  ipv4sOf =
    name:
    let
      v4 = (familyOf name).ipv4;
    in
    assert lib.assertMsg (v4 != [ ]) "captive-portals.txt: ${name} has no IPv4 address";
    v4;

  ipv6sOf =
    name:
    let
      v6 = (familyOf name).ipv6;
    in
    assert lib.assertMsg (v6 != [ ]) "captive-portals.txt: ${name} has no IPv6 address";
    v6;

  # There is deliberately no `firstAddressOf` helper. tests/doh-captive.nix used to assert
  # `builtins.head` of each entry, which meant it passed while the map served one of the
  # four detectportal addresses -- and since it is the only place dnscrypt-proxy's reading
  # of the .txt is compared against this parser's, that hid the whole class of
  # dropped-address bugs. A caller that genuinely wants one representative answer (the dig
  # sanity gate in tests/nm-captive-portal*.nix, which then curls the name properly) should
  # take the head at the call site, where it is visible.
}
