# Eval-only guard on the two things about ThingSpeak reporting that no VM test can see, because
# the VM test has to override exactly them to be testable at all.
#
#   * THE FIELD ORDER. A channel's fields are numbered, not named: the reporter sends
#     `field<N>=<value>` where N is the position in `common.thingspeak.measurements`, so the list
#     order is part of the wire format. Reorder it and every entry already in the channel keeps
#     the number it was sent under while new ones mean something else, with nothing in the data
#     to mark where the meaning changed -- and no error anywhere, because both orders are
#     perfectly valid configurations. tests/thingspeak.nix replaces this list with system-metrics
#     fields so it can drive records without emulating an inverter, so it has never seen the
#     production list at all.
#
#   * THE CLOCK GATE'S MARKER. modules/thingspeak.nix defaults it to the path
#     systemd-timesyncd writes, and enabling chrony forces timesyncd off -- so a host that did
#     not repoint it would condition the unit on a file nothing will ever create, and the
#     reporter would be skipped forever. Silent in the worst way: a skipped unit is not a failed
#     one, so the host stays green and the channel simply stops. The same trap
#     tests/time-sync-deployed.nix guards for the metrics producer, and it is per-host for the
#     same reason. The VM test creates the marker by hand, which is what lets it test the gate --
#     and also what makes it blind to the gate pointing at the wrong file.
#
# Also the endpoint, which is cheap to check and expensive to get wrong: the test node points
# `updateUrl` at a local recorder, and a host that inherited that would report nowhere while
# looking entirely healthy.
#
# Read from the rendered unit wherever the claim is about what systemd was told (the marker), and
# from the option where the option IS the artefact (the field order -- it is the wire format, and
# nothing downstream restates it). Fails with `throw` during evaluation, so this stays usable
# from a pure `nix flake check`.
{ pkgs, hosts }:

let
  lib = pkgs.lib;

  # The spec's list, spelled out rather than read back from the module's default. Reading the
  # default back would assert only that a value survived a round trip; this is the wire format,
  # and a change to it should have to be made twice -- here and in modules/thingspeak.nix -- with
  # this file's failure explaining what the second edit means.
  #
  # Order is `spec/rpi-features.md:77-85`, which is also the field numbering.
  expected = [
    { type = "bms.status"; field = "soc_percent"; }
    { type = "bms.status"; field = "pack_power_watts"; }
    { type = "bms.status"; field = "temperature_1_celsius"; }
    { type = "bms.status"; field = "pack_voltage_volts"; }
    { type = "inverter.status"; field = "pv1_charging_power_watts"; }
    { type = "inverter.status"; field = "pv2_charging_power_watts"; }
    { type = "inverter.status"; field = "output_active_power_watts"; }
    { type = "inverter.status"; field = "battery_voltage_volts"; }
  ];

  expectedUrl = "https://api.thingspeak.com/update";

  describe = m: "${m.type}.${m.field}";

  unitOf = host: name: hosts.${host}.config.systemd.units.${name}.text or null;

  trimmedLines = text: map lib.trim (lib.splitString "\n" (if text == null then "" else text));

  # --- the field order ------------------------------------------------------------------

  orderDrift =
    host:
    let
      actual = hosts.${host}.config.common.thingspeak.measurements;
      # Compared position by position rather than as a set, because a set comparison would pass
      # on exactly the change that matters: the same eight entries in a different order.
      pairs = lib.zipListsWith (want: got: { inherit want got; }) expected actual;
      mismatched = lib.filter (p: p.want.type != p.got.type || p.want.field != p.got.field) pairs;
      keys = map describe actual;
    in
    lib.optional (builtins.length actual != builtins.length expected)
      "${host}: sends ${toString (builtins.length actual)} fields, expected ${toString (builtins.length expected)}: ${toString keys}"
    ++ lib.imap1 (
      n: p:
      "${host}: field${toString n} is ${describe p.got}, expected ${describe p.want}"
    ) mismatched
    # A duplicate would send one reading twice under two numbers, wasting one of the eight
    # fields a channel has -- and reading, in the channel, as two independent series.
    ++ lib.optional (lib.length (lib.unique keys) != lib.length keys)
      "${host}: sends the same reading under more than one field number: ${toString keys}";

  # --- the endpoint ---------------------------------------------------------------------

  urlDrift =
    host:
    let
      url = hosts.${host}.config.common.thingspeak.updateUrl;
    in
    lib.optional (url != expectedUrl)
      "${host}: reports to ${url}, expected ${expectedUrl}";

  # --- the clock gate -------------------------------------------------------------------

  gateDrift =
    host:
    let
      cfg = hosts.${host}.config.common;
      want = "ConditionPathExists=${toString cfg.timeSync.syncedMarker}";
      text = unitOf host "thingspeak.service";
      conditions = lib.filter (l: lib.hasPrefix "ConditionPathExists=" l) (trimmedLines text);
    in
    if text == null then
      [ "${host}: common.thingspeak is enabled but there is no thingspeak.service" ]
    else
      lib.optional (!lib.elem want conditions)
        "${host}: thingspeak.service has ${toString conditions}, which does not include ${want} -- the gate must follow chrony's marker, since enabling chrony forces timesyncd off and its own marker never appears";

  reporting = lib.filter (h: hosts.${h}.config.common.thingspeak.enable) (builtins.attrNames hosts);
  quiet = lib.subtractLists reporting (builtins.attrNames hosts);

  errors = lib.concatMap (host: orderDrift host ++ urlDrift host ++ gateDrift host) reporting;
in
if errors != [ ] then
  throw ''
    The deployed ThingSpeak reporting does not match the spec.

    ${lib.concatStringsSep "\n  " errors}

    The field order is the wire format: a channel numbers its fields, so the position of an
    entry in common.thingspeak.measurements is what `field<N>` means. Reordering the list
    rewrites the meaning of every entry already in the channel, silently and irreversibly --
    ThingSpeak keeps what it was sent. Append; do not reorder. If a reorder really is intended,
    change this file too, and say in the commit what happens to the history.

    The clock gate must name chrony's marker. The module defaults to systemd-timesyncd's, and
    enabling chrony forces timesyncd off, so a host that does not repoint it conditions the
    reporter on a file nothing creates -- and a skipped unit is not a failed one, so the channel
    just stops with the host reporting itself healthy.
  ''
else
  pkgs.runCommand "thingspeak-deployed-check" { } ''
    echo "field order, endpoint and clock gate verified on: ${
      if reporting == [ ] then "NO HOST -- this check asserted nothing" else toString reporting
    }" > $out
    ${lib.optionalString (quiet != [ ]) ''
      echo "no ThingSpeak reporting deployed, so nothing to check: ${toString quiet}" >> $out
    ''}
  ''
