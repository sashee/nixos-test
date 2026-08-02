# The NTS time sources chrony is pointed at, as readable components.
#
# Hostnames, not addresses -- unlike lib/doh-stamps.nix, which pins IPs because dnscrypt-proxy
# is what resolves names in the first place and cannot depend on itself. NTS has no such
# constraint: by the time chronyd runs, the rough-clock service has put the clock inside
# certificate validity and dnscrypt-proxy answers, so a name resolves. Hostnames also survive
# an operator renumbering, which for a time source is the likelier failure.
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
  # REACHABILITY UNVERIFIED -- confirm each of these answers NTS-KE on tcp/4460 from the rpi5
  # and record the date here before this lands on a host, the way lib/doh-stamps.nix does. A
  # server that is merely unreachable degrades quietly: chronyd drops to the remaining
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
