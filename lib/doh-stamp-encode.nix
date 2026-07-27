# DNS Stamp encoder for DoH servers, in pure Nix (no IFD).
#
# dnscrypt-proxy's [static] section accepts only `sdns://` stamps, but a stamp for a
# DoH server carries nothing except an address, a hostname and a path -- so we keep the
# readable components as the source of truth (lib/doh-stamps.nix) and derive the stamps
# here. That way the probe in modules/connectivity-fallback.nix can reuse the address
# and hostname without decoding anything.
#
# Encoding, not decoding, is what makes this possible in pure Nix: a stamp's props
# field is 8 mostly-zero bytes, and a Nix string cannot hold NUL
# ("error: input string 'a\0b' cannot be represented as Nix string because it contains
# null bytes"). Here the zero bytes only ever live in a list of integers, and the
# base64 output is pure ASCII. Decoding would have to materialise those NULs, which is
# why the general-purpose Nix base64 libraries cannot round-trip a stamp.
#
# Wire format (https://dnscrypt.info/stamps-specifications), protocol 0x02 = DoH:
#
#   0x02 | props (u64 LE) | LP(addr) | VLP(hashes) | LP(hostname) | LP(path)
#
# where LP is a single length byte followed by that many bytes, and VLP is the same
# with the length's high bit set on every element except the last. We only emit a
# single empty hash (one 0x00 byte), matching every stamp this repo has ever used:
# certificate pinning is dnscrypt-proxy's job via the provider's own TLS chain.
{ lib }:

let
  # base64url, unpadded -- the alphabet DNS stamps use. Standard base64's "+/" would
  # produce stamps dnscrypt-proxy rejects.
  alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

  sextetToChar = i: builtins.substring i 1 alphabet;

  # String -> list of byte values. Only ever fed printable ASCII (addresses, hostnames,
  # paths). The check has to happen *before* mapping: lib.strings.charToInt is an attrset
  # lookup, so a non-ASCII byte fails with an unreadable `attribute '"\xef\xbf\xbd"'
  # missing` rather than anything actionable. [!-~] is 0x21-0x7e, i.e. printable ASCII
  # excluding space.
  stringToBytes =
    s:
    assert lib.assertMsg (builtins.match "[!-~]*" s
      != null) "doh-stamp-encode: field must be printable ASCII without spaces, got ${s}";
    map lib.strings.charToInt (lib.stringToCharacters s);

  # A length-prefixed field. Stamp length bytes are 7-bit (the high bit is the VLP
  # continuation flag), so 127 is the real ceiling.
  lengthPrefixed =
    s:
    let
      bytes = stringToBytes s;
      len = builtins.length bytes;
    in
    assert lib.assertMsg (len <= 127) "doh-stamp-encode: field too long (${toString len} > 127): ${s}";
    [ len ] ++ bytes;

  # base64 works on 3-byte groups; pad the tail with zeros, encode, then keep only the
  # sextets that carry real bits (2 for a 1-byte tail, 3 for a 2-byte tail) and emit no
  # "=" padding, which is what `sdns://` expects.
  base64urlUnpadded =
    bytes:
    let
      len = builtins.length bytes;
      fullGroups = len / 3;
      rem = len - fullGroups * 3;

      encodeGroup =
        i:
        let
          b0 = builtins.elemAt bytes (i * 3);
          b1 = builtins.elemAt bytes (i * 3 + 1);
          b2 = builtins.elemAt bytes (i * 3 + 2);
          n = b0 * 65536 + b1 * 256 + b2;
        in
        lib.concatMapStrings sextetToChar [
          (n / 262144)
          (lib.mod (n / 4096) 64)
          (lib.mod (n / 64) 64)
          (lib.mod n 64)
        ];

      tail =
        let
          b0 = builtins.elemAt bytes (fullGroups * 3);
          b1 = if rem == 2 then builtins.elemAt bytes (fullGroups * 3 + 1) else 0;
          n = b0 * 65536 + b1 * 256;
          sextets = [
            (n / 262144)
            (lib.mod (n / 4096) 64)
            (lib.mod (n / 64) 64)
          ];
        in
        lib.concatMapStrings sextetToChar (lib.take (rem + 1) sextets);
    in
    lib.concatStrings (builtins.genList encodeGroup fullGroups)
    + lib.optionalString (rem != 0) tail;
in
rec {
  # props bitfield. dnscrypt-proxy filters servers on these bits, so they are
  # load-bearing rather than documentation: modules/doh.nix sets
  # require_nofilter = true, and a server whose stamp omits bit 2 is silently dropped
  # from the pool. Dropping every server would leave the host with no DNS at all.
  propsDnssec = 1;
  propsNoLog = 2;
  propsNoFilter = 4;

  # The props value every stamp in this repo uses: "does not filter" only. Not
  # DNSSEC and not no-log, which is consistent with require_dnssec = false and
  # require_nolog = false in modules/doh.nix.
  defaultProps = propsNoFilter;

  # { addr, hostname, path, props } -> "sdns://..."
  #
  # `addr` is the literal the client dials, so IPv6 must arrive already bracketed
  # ("[2606:4700:4700::1111]"); see entriesFor in lib/doh-stamps.nix, which is the only
  # intended caller and does the bracketing.
  mkDohStamp =
    {
      addr,
      hostname,
      path ? "/dns-query",
      props ? defaultProps,
    }:
    let
      # u64 little-endian. Our props all fit in one byte; the remaining seven are the
      # NULs that make decoding in pure Nix impossible.
      propsBytes = [
        (lib.mod props 256)
        0
        0
        0
        0
        0
        0
        0
      ];
      bytes =
        [ 2 ] # protocol 0x02 = DoH
        ++ propsBytes
        ++ lengthPrefixed addr
        ++ [ 0 ] # VLP(hashes): a single zero-length hash
        ++ lengthPrefixed hostname
        ++ lengthPrefixed path;
    in
    "sdns://" + base64urlUnpadded bytes;

  # Exposed for the golden test in tests/doh-stamp-encode.nix.
  inherit base64urlUnpadded;
}
