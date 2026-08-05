# The NTS servers the two time VM tests impersonate, chosen from lib/nts-servers.nix by the
# role each one plays rather than named by hand.
#
# tests/nts-sync.nix and tests/time-correction.nix cannot use arbitrary hostnames: the module
# asserts that every entry of common.timeSync.servers is described by lib/nts-servers.nix
# (because time-correction needs the operator to know whether two answers are one source or
# two), and time-correction's `--only` flag names that file's *attribute keys*. So the tests
# were spelling both out -- four hostnames and eleven `--only` literals -- and a rename there
# passed evaluation and failed twenty minutes later as an opaque NTS timeout.
#
# What the tests actually need is structural, and that is what this picks:
#
#   good, stale         two providers under DIFFERENT operators. The quorum rule counts
#                       operators, not hostnames, so a pair sharing one could never be two
#                       votes and the disagreement subtests would be testing nothing.
#   redirectKe,         two providers sharing ONE operator. The redirect subtest establishes
#   redirectNtp         keys as the first name and is redirected to the second; they have to
#                       be one organisation for that to be the real-world shape it models
#                       (nts.netnod.se does this, and today's pair is ptb1/ptb2).
#
# Selection is by sorted attribute name throughout, so the same list always yields the same
# roles and a test failure is reproducible. If the list can no longer fill a role this throws
# and names the role: an unbuildable fixture should say so at eval time, not surface as a
# server that never answers.
{ lib, ntsServers }:

let
  # { key; hostname; operator; } -- `key` is what --only takes, `hostname` is what chrony and
  # the certificates take.
  entries = map (key: ntsServers.providers.${key} // { inherit key; }) (
    builtins.attrNames ntsServers.providers
  );

  keysOf = map (e: e.key);

  # First operator with two or more providers, in first-appearance order.
  sharedOperator =
    let
      withTwo = lib.filter (
        o: builtins.length (lib.filter (e: e.operator == o) entries) >= 2
      ) (lib.unique (map (e: e.operator) entries));
    in
    if withTwo == [ ] then null else builtins.head withTwo;

  redirectPair =
    if sharedOperator == null then
      [ ]
    else
      lib.take 2 (lib.filter (e: e.operator == sharedOperator) entries);

  # good/stale come from what the redirect pair did not take, so the three impersonated nodes
  # are three distinct servers and no subtest is accidentally pointing two roles at one name.
  rest = lib.filter (e: !(lib.elem e.key (keysOf redirectPair))) entries;
  good = if rest == [ ] then null else builtins.head rest;
  staleCandidates = if good == null then [ ] else lib.filter (e: e.operator != good.operator) rest;
  stale = if staleCandidates == [ ] then null else builtins.head staleCandidates;

  errors =
    lib.optional (redirectPair == [ ]) ''
      no two servers share an operator, so the NTS-KE redirect subtest cannot be built: it
      needs one organisation answering key establishment under one name and timestamping
      under another. Operators present: ${toString ntsServers.operators}.''
    ++ lib.optional (good == null) ''
      no server left for the `good` role after the redirect pair took ${toString (keysOf redirectPair)}.''
    ++ lib.optional (good != null && stale == null) ''
      no server under an operator other than ${good.operator} (the `good` role) is left for the
      `stale` role, so the two would count as one vote and the quorum subtests would pass for
      the wrong reason.'';
in
if errors != [ ] then
  throw ''
    tests/nts-fixtures.nix cannot assign its roles from lib/nts-servers.nix.

    ${lib.concatStringsSep "\n\n    " errors}

    Either restore a list that can fill these roles or rewrite the subtests that depend on
    them -- do not point two roles at one server, which is how the quorum tests stop testing
    the quorum.
  ''
else
{
  inherit good stale;
  redirectKe = builtins.elemAt redirectPair 0;
  redirectNtp = builtins.elemAt redirectPair 1;
}
