# The NTS time sources chrony is pointed at, as readable components.
#
# Hostnames, not addresses -- unlike lib/doh-stamps.nix, which pins IPs because dnscrypt-proxy
# is what resolves names in the first place and cannot depend on itself. Two consumers read
# this list and neither wants addresses:
#
#   chronyd runs after the clock is already inside certificate validity, so a name resolves;
#   time-correction runs before that, and resolves these names itself through a DoH resolver
#     dialled at a pinned address -- which is why lib/doh-stamps.nix pins and this file does not.
#
# Pinning would not work here anyway, which is the substantive reason. Measured 2026-08-02:
# time.cloudflare.com is anycast across a few hundred sites, nts.netnod.se is a ten-way DNS
# round-robin across Swedish sites, and only the two PTB hosts are single unicast machines --
# one operator, so pinning them buys nothing. Hostnames also survive an operator renumbering,
# which for a time source is the likelier failure.
#
# One protocol wrinkle any client of this list must handle: an NTS server may answer key
# establishment itself and hand the timestamping to a different host and port, using records
# marked CRITICAL, which a client that does not understand them must abort on. nts.netnod.se
# does exactly that -- it redirects to 194.58.207.80:4123. chronyd handles it transparently;
# packages/time-correction implements it explicitly (see src/nts.rs).
#
# `operator` is carried explicitly rather than derived from the hostname. The spec requires
# multiple servers so a single lying or broken source can be outvoted, and that only holds if
# the sources fail independently -- ptbtime1 and ptbtime2 are two names for one operator, one
# organisation, one failure. Nothing in the hostnames says so, so the field does.
#
# Adding an entry: the name must NOT contain the substring "pool". nixpkgs' chrony module
# (services/networking/ntp/chrony.nix) emits a `pool` directive instead of `server` for any
# entry matching `hasInfix "pool"`, which silently changes what chronyd does with it --
# `ntppool1.time.nl` is a real NTS server that would trip exactly that. tests/nts-servers.nix
# rejects it at eval time.
{ lib }:

rec {
  # Verified 2026-08-02 from a development machine, NOT yet from the rpi5: all four completed
  # NTS-KE on tcp/4460 (TLS 1.3, ALPN ntske/1, AEAD 15, 8 cookies each), and all four returned
  # an authenticated timestamp over NTPv4 through the full time-correction path. Re-run
  # `time-correction --force --dry-run` on the Pi and record that here before relying on it
  # there; its egress is not this machine's.
  #
  # A server that is merely unreachable degrades quietly: chronyd drops to the remaining
  # sources and `minsources 2` keeps working until it cannot, and nothing reports it yet.
  providers = {
    cloudflare = {
      hostname = "time.cloudflare.com";
      operator = "cloudflare";
    };
    netnod = {
      hostname = "nts.netnod.se";
      operator = "netnod";
    };
    ptb1 = {
      hostname = "ptbtime1.ptb.de";
      operator = "ptb";
    };
    ptb2 = {
      hostname = "ptbtime2.ptb.de";
      operator = "ptb";
    };
  };

  # What services.chrony.servers wants: a plain list, sorted by attribute name so the
  # generated chrony.conf is stable across evaluations.
  hostnames = lib.mapAttrsToList (_: p: p.hostname) providers;

  operators = lib.unique (lib.mapAttrsToList (_: p: p.operator) providers);
}
