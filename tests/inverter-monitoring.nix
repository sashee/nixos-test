{ nixpkgs, pkgs, machineModule, stateVersion, globalTimeout ? 900 }:

# End-to-end check of the inverter producer against emulated USB serial hardware.
#
# The node gets three QEMU `usb-serial` devices -- emulated FTDI FT232 adapters, bound by the
# guest's real ftdi_sio driver and named by the guest's real udev, so they arrive as genuine
# /dev/ttyUSB* with genuine /dev/serial/by-{id,path} symlinks. Each one's wire end is a unix
# socket the test driver holds, so the driver *is* the hardware: one socket answers the Voltronic
# command set, one chatters like the battery BMS, and one says nothing.
#
# Two of the three publish no USB serial number, which is what the fleet's actual inverter adapter
# does (a CH340, 1a86:7523, with an empty serial descriptor). udev then derives the same by-id
# name for both, and they collide onto one symlink -- so an implementation that enumerated that
# directory would find one candidate for two devices and could miss the inverter entirely. That is
# a real bug the first version of this producer had, and reproducing the descriptor shape is what
# turns it into a test.
#
# That is what makes the discovery half testable at all. Every other way of faking a serial port
# (a pty, a fixture directory) would skip the two things most likely to break in the field: that
# the port can be opened and configured for 2400 8N1 at all, and that the producer can tell an
# inverter from the other device on the same bus without a human pointing at it.
#
# What it deliberately does NOT reproduce: QEMU passes bytes through as fast as the socket
# allows, so nothing here runs at 2400 baud. Timing assumptions -- the ~460ms QPIGS frame, the
# response deadline -- are the aarch64 hardware's business, not this test's.
#
# The measurement path itself is the real deployed one, as in tests/system-metrics.nix: the
# producer posts to the on-host mp-collector, which forwards to the real receiver, and the
# assertions read the results back out of the receiver's query API.

let
  # Fast enough that a subtest is seconds rather than minutes, slow enough that the cycles are
  # distinguishable. The production values are the module's defaults; what is under test here is
  # behaviour per cycle, not the cadence.
  intervalSeconds = 5;

  # The identity re-read, which at the production hour no test could reach. Several poll cycles
  # rather than one, so the refresh is visibly a separate event from the cycle it follows.
  staticRefreshSeconds = 15;

  invSocket = "/tmp/inverter-monitoring-test-inverter.sock";
  bmsSocket = "/tmp/inverter-monitoring-test-bms.sock";
  idleSocket = "/tmp/inverter-monitoring-test-idle.sock";

  # `server=off` (the default): QEMU connects out, so the driver binds every socket before the
  # machine starts and there is no window where the guest probes a port with nothing behind it.
  # The alternative -- QEMU listening -- would have the producer fail discovery on the first
  # start and sit out a RestartSec before anyone could answer it.
  #
  # `serial` is null for the adapters that stand in for the fleet's CH340. A USB serial chip that
  # publishes no iSerialNumber makes udev derive the by-id name from vendor and product alone, so
  # every adapter of that model gets the SAME by-id name.
  #
  # It has to be an explicitly EMPTY `serial=`, not an omitted one: with the property unset QEMU
  # synthesises a serial from the bus topology (`1-0000:00:0a.0-3`), which is unique per port and
  # would quietly defeat the whole point of these two devices.
  #
  # The `id=` on the device -- as opposed to the one on the chardev -- exists so the monitor can
  # `device_del` it, which is how the last subtest unplugs an adapter. That is a definite USB
  # detach: the guest logs `usb N-1: USB disconnect` and ftdi_sio hangs up the tty, which is the
  # state that subtest is about and which muting the simulator does not reach.
  usbSerial = id: path: serial: [
    "-chardev socket,id=${id},path=${path}"
    "-device usb-serial,id=${id}-dev,bus=xhci.0,chardev=${id},serial=${nixpkgs.lib.optionalString (serial != null) serial}"
  ];
in

nixpkgs.lib.nixos.runTest {
  name = "inverter-monitoring";
  hostPkgs = pkgs;
  inherit globalTimeout;

  nodes.machine = { lib, ... }: {
    imports = [ machineModule ];

    networking.hostName = "inverter-test";
    # None of these can work in a VM, and none of them is what this test is about: auto-upgrade
    # needs /etc/nixos, monitoring and iroh-ssh need credentials.
    common.autoUpgrade.enable = lib.mkForce false;
    common.monitoring.enable = lib.mkForce false;
    common.irohSsh.enable = lib.mkForce false;

    # The sibling producer, off -- and this one is not about credentials. hosts/rpi5 enables it, so
    # without this it runs here too and competes for the same three adapters. That breaks the
    # premise of the `probed first` subtest below: it forces a probe order with the remembered-device
    # file, which only decides anything if this producer is the one deciding. With bms-monitoring
    # also sweeping, it holds each candidate's flock for its own listen window, and the inverter
    # skips the very port the subtest seeded -- so the run never reaches the `unsolicited` log line
    # it waits for.
    #
    # The contention between the two producers is not lost by switching it off here: it is the
    # subject of tests/bms-monitoring.nix, which runs both together and asserts each holds its own
    # port. This test stays about the inverter.
    common.bmsMonitoring.enable = lib.mkForce false;

    common.inverterMonitoring = {
      intervalSeconds = lib.mkForce intervalSeconds;
      # Paid once per candidate port, and there are three. The production 10s would put half a
      # minute of pure waiting in front of every subtest.
      bmsListenSeconds = lib.mkForce 2;
      # Nothing here runs at 2400 baud, so a frame arrives at once or not at all.
      responseTimeoutSeconds = lib.mkForce 2;
      staticRefreshSeconds = lib.mkForce staticRefreshSeconds;
      # restartSec is deliberately NOT overridden: 15 minutes is a spec value, so the unit here
      # carries the one the hosts deploy and the subtest below asserts it. The single subtest
      # that waits out an automatic restart shortens it with a runtime drop-in instead.
    };

    # This node has no time source, so its clock is never set and the collector holds every
    # batch for its full buffer window before shipping it marked `mp.clock.uncertain`. At the
    # default 300s that is five minutes per assertion, and the test times out long before it
    # finishes.
    #
    # Shortened rather than fixed by giving the node an NTP server: the clock path is not what
    # this test is about -- upstream's own suite covers the collector's buffering and step
    # detection, and tests/system-metrics.nix covers the deployed no-gate consequence. Here it
    # is purely latency between the producer posting and the receiver being readable.
    services.mp-collector.bufferTimeoutSecs = lib.mkForce 2;

    # ftdi_sio is what binds QEMU's emulated FT232. udev would autoload it on the modalias, but
    # naming it here means a kernel that dropped it fails as a missing module rather than as a
    # mysteriously empty /dev/serial/by-id.
    boot.kernelModules = [ "ftdi_sio" ];

    virtualisation.qemu.options = [
      # x86 QEMU has no USB controller unless asked; without this the devices below have no bus
      # to attach to and QEMU refuses to start.
      "-device qemu-xhci,id=xhci"
    ]
    # Three adapters, matching what the Pi actually has plus the case that broke the first
    # implementation:
    #   inv  -- the inverter, no serial number (the CH340, 1a86:7523)
    #   bms  -- the battery BMS, with a serial number (the FT232R, 0403:6001)
    #   idle -- a third serial-less adapter that says nothing at all. It collides with `inv` on
    #           by-id, so a producer that enumerated that directory would see ONE candidate for
    #           the two of them and could miss the inverter entirely.
    ++ usbSerial "inv" invSocket null
    ++ usbSerial "bms" bmsSocket "BMS0001"
    ++ usbSerial "idle" idleSocket null;

    system.stateVersion = stateVersion;
  };

  # Concatenated rather than interpolated: `''` strips each literal's own indentation, so a
  # `${...}` inside this one would dedent the helper's function bodies out of their own `def`s.
  testScript = (import ../lib/test-mp-auth.nix) + ''
    import json
    import os
    import socket
    import threading
    import time

    SOCKET = "/run/monitoring-platform/monitoring-platform.sock"
    INV_SOCKET = "${invSocket}"
    BMS_SOCKET = "${bmsSocket}"
    IDLE_SOCKET = "${idleSocket}"
    INTERVAL = ${toString intervalSeconds}

    # ------------------------------------------------------------------------------------
    # The inverter, in Python.
    #
    # The framing is re-implemented here rather than shared with the Rust: two independent
    # readings of spec/features/inverter-monitoring/protocol.md is the point. If the producer's
    # CRC and this one agreed because they were the same code, this test would prove nothing
    # about either.

    def crc16(data):
        crc = 0
        for byte in data:
            crc ^= byte << 8
            for _ in range(8):
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
        return crc


    def escape(byte):
        # '(' , LF and CR would collide with the framing, so the protocol bumps them.
        return byte + 1 if byte in (0x28, 0x0A, 0x0D) else byte


    def frame(payload):
        body = b"(" + payload
        crc = crc16(body)
        return body + bytes([escape(crc >> 8), escape(crc & 0xFF)]) + b"\r"


    def qpigs(battery="54.20", load="012"):
        text = (
            "000.0 00.0 226.7 50.0 0997 0825 %s 429 %s 041 080 0062 "
            "09.2 196.4 00.00 00000 00010110 00 00 01819 010" % (load, battery)
        )
        assert len(text) == 106, f"the fixture must stay 106 bytes, got {len(text)}"
        return text.encode()


    CLEAR = b"0" * 36

    # Everything the simulator will say, and the switches the subtests flip. One dict behind one
    # lock rather than a class: the test needs to change it from the driver thread and read it
    # back, and nothing else about it is interesting.
    state = {
        "qpigs": qpigs(),
        "qpiws": CLEAR,
        "mode": b"B",
        # The identity is a switch too, because "read once at connect" and "re-read on the
        # refresh" are indistinguishable while the answers never change.
        "serial": b"92932210103714",
        "nak_qpigs2": False,
        "corrupt_next_qpigs": False,
        "mute": False,
    }
    # Not in `state`: the driver type-checks this script, and a set sharing a dict with bytes
    # and bools loses its type.
    seen = set()
    lock = threading.Lock()


    def respond(command):
        with lock:
            # The unplugged-cable case: the port is still open, the device says nothing.
            if state["mute"]:
                return None
            if command == b"QID":
                return frame(state["serial"])
            if command == b"QVFW":
                return frame(b"VERFW:00072.04")
            if command == b"QVFW3":
                return frame(b"VERFW:00012.21")
            if command == b"QMN":
                return frame(b"MKS2-8000")
            if command == b"QGMN":
                return frame(b"044")
            if command == b"QMOD":
                return frame(state["mode"])
            if command == b"QPIGS":
                built = frame(state["qpigs"])
                if state["corrupt_next_qpigs"]:
                    state["corrupt_next_qpigs"] = False
                    # Flip a payload byte and leave the CRC alone: a frame that arrives whole
                    # and fails its checksum, which is what line noise looks like.
                    built = bytearray(built)
                    built[10] ^= 0xFF
                    built = bytes(built)
                return built
            if command == b"QPIGS2":
                return frame(b"NAK") if state["nak_qpigs2"] else frame(b"05.4 212.5 01156 ")
            if command == b"QPIWS":
                return frame(state["qpiws"])
        return None


    def serve_inverter(conn):
        buffered = b""
        while True:
            chunk = conn.recv(256)
            if not chunk:
                return
            buffered += chunk
            while b"\r" in buffered:
                request, buffered = buffered.split(b"\r", 1)
                # <ASCII command><CRC hi><CRC lo>; the producer's CRC is verified by its own
                # unit tests, so this only needs the name.
                command = request[:-2]
                with lock:
                    seen.add(command.decode(errors="replace"))
                reply = respond(command)
                if reply:
                    conn.sendall(reply)


    def serve_bms(conn):
        # Speaks without being asked, which is the entire definition of "not the inverter".
        conn.setblocking(False)
        while True:
            try:
                conn.sendall(b"\x55\xaa\x01\x02\x03\x04")
            except BlockingIOError:
                pass
            except OSError:
                return
            try:
                conn.recv(256)
            except (BlockingIOError, OSError):
                pass
            time.sleep(0.2)


    def listener(path):
        if os.path.exists(path):
            os.unlink(path)
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        server.listen(1)
        return server


    def accept_into(server, handler):
        def run():
            conn, _ = server.accept()
            try:
                handler(conn)
            except OSError:
                pass
        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        return thread


    def serve_idle(conn):
        # Neither chatters nor answers: a port that has to be probed and rejected on the QID
        # timeout rather than on unsolicited traffic.
        conn.setblocking(False)
        while True:
            try:
                conn.recv(256)
            except BlockingIOError:
                pass
            except OSError:
                return
            time.sleep(0.2)


    # Bound before the machine starts: QEMU connects out to all three of these as it boots.
    inverter_server = listener(INV_SOCKET)
    bms_server = listener(BMS_SOCKET)
    idle_server = listener(IDLE_SOCKET)
    accept_into(inverter_server, serve_inverter)
    accept_into(bms_server, serve_bms)
    accept_into(idle_server, serve_idle)

    # ------------------------------------------------------------------------------------

    def query(params="limit=2000"):
        # --fail-with-body, so an unauthenticated read fails here naming its status instead of
        # surfacing as a KeyError on the missing "measurements" field: curl exits 0 on a 401.
        raw = machine.succeed(
            f"curl -sS --fail-with-body {auth_header()}--unix-socket {SOCKET} "
            f"'http://localhost/v1/measurements?{params}'"
        )
        return json.loads(raw)["measurements"]


    def statuses():
        return [m for m in query() if m["type"] == "inverter.status"]


    def flags():
        return [m for m in query() if m["type"] == "inverter.status.flag"]


    def latest():
        # The read API orders event_time DESC, id DESC, so the newest status record is first.
        rows = statuses()
        assert rows, "no inverter.status measurement in the store"
        return rows[0]


    def next_status():
        """Wait for one more status record to land.

        NOT a way to wait for the effect of something the test just did. The row that lands next
        may have been read off the wire before it: the producer posts at the end of a cycle and
        the collector forwards on its own flush schedule, so at any moment there is a record in
        flight that predates whatever the test has just changed. Waiting for an effect means
        retrying on the value it changes -- `changed`, `cleared`, `corrupted` and `naked` below
        are all that shape.
        """
        before = len(statuses())
        retry(lambda _: len(statuses()) > before)
        return latest()


    def restarts():
        return int(machine.succeed(
            "systemctl show -p NRestarts --value inverter-monitoring.service"
        ).strip())


    def links_of(tty, kind):
        """The `/dev/serial/<kind>/` link names udev made for one tty.

        Asked of udev rather than reconstructed from `ls -l`: this is the same database the
        producer's directory scan is reading, so a disagreement here would be a real one rather
        than a shell-quoting artefact.
        """
        raw = machine.succeed(f"udevadm info -q symlink -n /dev/{tty}").split()
        prefix = f"serial/{kind}/"
        return sorted(link[len(prefix):] for link in raw if link.startswith(prefix))


    def by_path_of(tty):
        """The by-path name the producer keys `tty` by: the smallest of its links."""
        links = links_of(tty, "by-path")
        assert links, f"udev made no by-path link for {tty}"
        return links[0]


    def tty_behind(by_id_fragment):
        return machine.succeed(
            f"basename $(readlink -f /dev/serial/by-id/*{by_id_fragment}*)"
        ).strip()


    machine.start()
    machine.wait_for_unit("multi-user.target")

    # As early as possible, and earlier than the other two tests need it: this producer is a daemon
    # started at boot, not a oneshot the script drives, so it is already posting cycles by the time
    # anything here runs. authenticate() restarts the collector and a restart discards the outbox,
    # so every second between boot and this line is inverter records thrown away. Nothing below
    # asserts on the earliest ones -- every subtest drives a fresh cycle and waits for it -- but
    # doing this after `udevadm settle` would widen that window by the length of a coldplug
    # backlog, which on the emulated aarch64 node is tens of seconds.
    machine.wait_for_unit("mp-collector.service")
    machine.wait_for_unit("monitoring-platform.service")
    authenticate(machine)

    # The two serial-less adapters CONTEST one by-id link, and udev re-picks the winner on every
    # event touching either of them. multi-user is not the end of that: the coldplug trigger only
    # enqueues, and on an emulated aarch64 node its backlog is still being worked tens of seconds
    # after the target is up -- long enough that the producer, started at boot, reads the
    # directory mid-flight. Settling here is what makes "who owns the shared name" a fixed fact
    # for the rest of the file rather than one that moves between two reads of it.
    machine.succeed("udevadm settle --timeout=180")

    with subtest("two of the three adapters collide on one by-id name"):
        machine.wait_until_succeeds(
            "test -e /dev/ttyUSB0 && test -e /dev/ttyUSB1 && test -e /dev/ttyUSB2"
        )
        machine.wait_until_succeeds("test -d /dev/serial/by-path")

        # Three devices, three physical ports, three by-path names. This is the identity the
        # producer keys on, and it is unique by construction.
        by_path = {f"ttyUSB{n}": links_of(f"ttyUSB{n}", "by-path") for n in range(3)}
        distinct_ports = {by_path_of(f"ttyUSB{n}") for n in range(3)}
        assert len(distinct_ports) == 3, f"ports are not distinguishable: {by_path}"

        # But only TWO by-id names, because the two serial-less adapters generate the same one
        # and udev can only make that link once. A producer enumerating this directory would
        # find two candidates for three devices -- the bug this test exists for.
        #
        # The exact spelling differs from the Pi's: an EMPTY serial descriptor (what QEMU can
        # emulate) makes udev drop the separator, `usb-QEMU_QEMU_USB_SERIAL-if00-port0`, where
        # the CH340's ABSENT one leaves a trailing underscore, `usb-1a86_USB2.0-Ser_-...`. The
        # collision is identical; only the cosmetics differ, so nothing here matches on the
        # name's shape.
        by_id = machine.succeed("ls /dev/serial/by-id/").split()
        assert len(by_id) == 2, f"expected the collision to leave two by-id names, got {by_id}"
        assert any("BMS0001" in name for name in by_id), by_id
        shared_by_id = next(name for name in by_id if "BMS0001" not in name)

    with subtest("the producer finds the inverter despite the collision, and remembers it"):
        machine.wait_for_unit("inverter-monitoring.service")
        next_status()

        # Which socket it attached to is not a naming question: only the inverter's chardev
        # answers the command set, so having been asked for them at all is the proof.
        with lock:
            asked = set(seen)
        assert {"QID", "QPIGS", "QPIWS"} <= asked, asked

        inverter_port = latest()["attributes"]["resource.attributes.inverter.device"]
        assert inverter_port in distinct_ports, (
            f"{inverter_port} is not one of the by-path names {by_path}"
        )

        # Remembered by the port, byte for byte the same string that is reported.
        remembered = machine.succeed("cat /var/lib/inverter-monitoring/last-device").strip()
        assert remembered == inverter_port, f"remembered {remembered!r}, reported {inverter_port!r}"
        # Not a ttyUSB number, which is handed out in enumeration order and would point at a
        # different device after a reboot.
        assert "ttyUSB" not in remembered, remembered

    with subtest("the unit is a daemon systemd restarts a quarter of an hour after any exit"):
        # Spec values, and the only place they are visible: the producer is a daemon started at
        # boot, and every exit -- clean or not -- costs `RestartSec` before the next attempt.
        # Read off the rendered unit rather than from the option, because the claim is that
        # systemd was told. That is as far as the unit text can be trusted, though -- see the
        # subtest below, where a key systemd printed in `systemctl cat` was one it had ignored.
        unit = machine.succeed("systemctl cat inverter-monitoring.service")
        assert "Restart=always" in unit, unit
        assert "RestartSec=900" in unit, unit
        # Asked of systemd, not of the unit text: NixOS wires `wantedBy` as a symlink in
        # multi-user.target.wants rather than as an [Install] section, so the text says nothing
        # about what starts this at boot.
        wanted = machine.succeed(
            "systemctl show -p WantedBy --value inverter-monitoring.service"
        )
        assert "multi-user.target" in wanted, wanted

    with subtest("systemd accepted every key in the unit file"):
        # This is here because the first real deploy logged
        # "Unknown key 'StartLimitIntervalSec' in section [Service], ignoring" -- it is a [Unit]
        # key, and systemd parses per-section and drops an unknown one with a log line and a
        # zero exit. Nothing in the suite noticed, because the unit still started.
        journal = machine.succeed("journalctl -u inverter-monitoring.service --no-pager -b")
        assert "Unknown key" not in journal, journal

        # And the setting is not merely accepted but in force. Without it the default (5 starts
        # in 10s) parks the unit in `failed` after a run of fast exits, which is exactly the
        # case this service is built to survive.
        limit = machine.succeed(
            "systemctl show -p StartLimitIntervalUSec --value inverter-monitoring.service"
        ).strip()
        assert limit == "0", f"the start rate limit is still in force: {limit}"

    with subtest("the by-id name is reported when there is one, and never a borrowed one"):
        # Two devices claim `shared_by_id` and only one owns the symlink, so whether the
        # inverter has a by-id name at all depends on which of them won. Both outcomes are
        # correct; reporting the OTHER device's name would not be.
        #
        # Both sides of the comparison are reads of a link that settled before the first subtest
        # ran, and the producer resolves the name afresh on every cycle rather than remembering
        # it from connect -- so there is no window here for the two to have seen different owners.
        owner = machine.succeed(
            f"basename $(readlink -f /dev/serial/by-id/{shared_by_id})"
        ).strip()
        name = latest()["attributes"].get("resource.attributes.inverter.device_name")
        if by_path_of(owner) == inverter_port:
            assert name == shared_by_id, f"reported {name!r}, expected {shared_by_id!r}"
        else:
            # The link went to the other claimant. An absent attribute is the honest answer --
            # better than borrowing a name that resolves elsewhere.
            assert name is None, f"reported {name!r} for a device that owns no by-id link"

    with subtest("a chattering device is skipped even when it is probed first"):
        # The probe order is shuffled, so the run above may never have touched the BMS at all.
        # The remembered-device file is the one lever that makes the order deterministic: it is
        # always tried first, so seeding it with the BMS forces the case this subtest is about.
        bms_port = by_path_of(tty_behind("BMS0001"))
        assert bms_port and bms_port != inverter_port, (bms_port, inverter_port)
        machine.succeed(
            f"printf '%s\\n' {bms_port} > /var/lib/inverter-monitoring/last-device"
            # Written by root into a 0700 DynamicUser directory; without this the service could
            # read the hint but not replace it, and would log a failure to remember instead.
            " && chmod 666 /var/lib/inverter-monitoring/last-device"
        )
        seen_lines = int(machine.succeed(
            "journalctl -u inverter-monitoring.service --no-pager | wc -l"
        ).strip())
        machine.succeed("systemctl restart inverter-monitoring.service")
        machine.wait_for_unit("inverter-monitoring.service")

        # Waited for by what the restarted process itself says and does. A status record landing
        # after the restart proves nothing about which process produced it -- a cycle read off the
        # wire beforehand can still be in the collector's buffer, and on a slow node it routinely
        # is, which had this reading the journal before the new process had probed anything.
        machine.wait_until_succeeds(
            "journalctl -u inverter-monitoring.service --no-pager "
            f"| tail -n +{seen_lines + 1} | grep -q unsolicited"
        )
        machine.wait_until_succeeds(
            f"grep -qxF {inverter_port} /var/lib/inverter-monitoring/last-device"
        )

        fresh = machine.succeed(
            "journalctl -u inverter-monitoring.service --no-pager "
            f"| tail -n +{seen_lines + 1}"
        )
        # Rejected for the right reason -- it spoke first -- and never written to.
        assert "unsolicited" in fresh, fresh
        assert bms_port in fresh, fresh
        assert inverter_port in fresh, fresh
        device = latest()["attributes"]["resource.attributes.inverter.device"]
        assert device == inverter_port, f"attached to the wrong device: {device}"
        # And the bad hint is replaced rather than kept.
        remembered = machine.succeed("cat /var/lib/inverter-monitoring/last-device").strip()
        assert remembered == inverter_port, remembered

    with subtest("the unit's identity is read once and carried as resource attributes"):
        attributes = latest()["attributes"]
        assert attributes["resource.attributes.inverter.serial_number"] == "92932210103714"
        assert attributes["resource.attributes.inverter.model"] == "MKS2-8000"
        assert attributes["resource.attributes.inverter.model_code"] == "044"
        assert attributes["resource.attributes.inverter.firmware"] == "VERFW:00072.04"
        assert attributes["resource.attributes.inverter.firmware_panel"] == "VERFW:00012.21"
        assert attributes["resource.attributes.service.name"] == "inverter-monitoring"
        with lock:
            asked = set(seen)
        assert {"QID", "QVFW", "QVFW3", "QMN", "QGMN"} <= asked, asked

    with subtest("one cycle is one record carrying every field, scaled"):
        body = latest()["body"]
        # Values, not wire text: 54.20 volts is a number and 0997 VA is 997.
        assert body["battery_voltage_volts"] == 54.2, body
        assert body["output_apparent_power_va"] == 997, body
        assert body["output_active_power_watts"] == 825, body
        assert body["grid_voltage_volts"] == 0.0, body
        assert body["output_voltage_volts"] == 226.7, body
        assert body["heat_sink_temperature_celsius"] == 62, body
        assert body["pv1_charging_power_watts"] == 1819, body
        assert body["mode"] == "battery", body
        assert body["mode_code"] == "B", body
        # QPIGS2 answered, so the second string is real rather than null.
        assert body["pv2_voltage_volts"] == 212.5, body
        assert body["pv2_charging_power_watts"] == 1156, body
        # Device status bits, decoded left to right: 00010110 is load on, charging from SCC.
        assert body["load_on"] is True, body
        assert body["charging"] is True, body
        assert body["charging_scc"] is True, body
        assert body["charging_ac"] is False, body
        assert body["switch_on"] is True, body
        assert body["float_charge"] is False, body
        # A healthy unit: no warning bits, and therefore no flag records at all.
        assert body["warnings_asserted_count"] == 0, body
        assert body["warnings_raw"] == "0" * 36, body
        assert body["inverter_fault"] is False, body
        assert flags() == [], "a healthy unit must not emit flag records"

    with subtest("a changing reading changes the record"):
        with lock:
            state["qpigs"] = qpigs(battery="49.80", load="077")

        # By value, not by "one more record". The cycle in flight when this line runs read QPIGS
        # under the OLD fixture, and it is that record which lands next -- CI caught exactly
        # that, a row carrying 54.2 from the cycle whose wire read fell in the same instant as
        # this assignment. Which record carries the new value is not the claim; that it lands is.
        def changed(_):
            return latest()["body"]["battery_voltage_volts"] == 49.8

        retry(changed)
        body = latest()["body"]
        assert body["battery_voltage_volts"] == 49.8, body
        assert body["output_load_percent"] == 77, body

    with subtest("an asserted warning bit becomes a named flag record"):
        bits = bytearray(b"0" * 36)
        bits[5] = ord("1")   # line_fail
        bits[17] = ord("1")  # eeprom_fault
        with lock:
            state["qpiws"] = bytes(bits)

        def asserted(_):
            return latest()["body"]["warnings_asserted_count"] == 2

        retry(asserted)

        body = latest()["body"]
        assert body["warnings_asserted_count"] == 2, body
        assert body["warnings_raw"][5] == "1", body

        named = {
            (m["attributes"]["record.attributes.bit"],
             m["attributes"]["record.attributes.flag"])
            for m in flags()
        }
        assert ("a5", "line_fail") in named, named
        assert ("a17", "eeprom_fault") in named, named

    with subtest("clearing the bits stops the flag records without hiding the recovery"):
        with lock:
            state["qpiws"] = CLEAR

        def cleared(_):
            return latest()["body"]["warnings_asserted_count"] == 0

        retry(cleared)
        # Counted only once the clear has actually landed: a cycle still carrying the old bits
        # would otherwise be attributed to the window below.
        settled = len(flags())
        # The historical flag rows stay -- nothing is deleted -- but no new ones are written.
        machine.sleep(2 * INTERVAL + 2)
        assert len(flags()) == settled, "flag records are still being emitted after recovery"

    # The central claim of the failure taxonomy, and the reason the spec's two statements about
    # failure could not both be taken literally: a corrupt frame costs one field for one cycle,
    # not fifteen minutes of darkness.
    with subtest("a corrupt frame is counted and discarded, and the service does not restart"):
        before_restarts = restarts()
        baseline = latest()["body"]["link_discarded_frames"]
        with lock:
            state["corrupt_next_qpigs"] = True

        def corrupted(_):
            body = latest()["body"]
            return body["link_discarded_frames"] > baseline

        retry(corrupted)
        machine.succeed("systemctl is-active --quiet inverter-monitoring.service")
        assert restarts() == before_restarts, (
            f"the service restarted over a bad CRC ({before_restarts} -> {restarts()})"
        )

        # The cycle that lost QPIGS still reported: its keys are null, the ones from the other
        # three commands are not.
        candidates = [
            row for row in statuses()
            if row["body"]["link_discarded_frames"] > baseline
            and row["body"]["battery_voltage_volts"] is None
        ]
        assert candidates, "no cycle reported the QPIGS fields as null after the bad CRC"
        damaged = candidates[0]
        assert damaged["body"]["mode"] == "battery", damaged["body"]
        assert damaged["body"]["pv2_voltage_volts"] == 212.5, damaged["body"]
        assert damaged["body"]["warnings_asserted_count"] == 0, damaged["body"]

        # And the next cycle is whole again.
        recovered = next_status()["body"]
        assert recovered["battery_voltage_volts"] is not None, recovered

    with subtest("a NAK marks the command unsupported instead of failing the run"):
        before_restarts = restarts()
        with lock:
            state["nak_qpigs2"] = True
            seen.discard("QPIGS2")

        def naked(_):
            return latest()["body"]["link_unsupported_commands"] >= 1

        retry(naked)
        body = latest()["body"]
        # Only the second string goes null; the first is from QPIGS and is untouched.
        assert body["pv2_voltage_volts"] is None, body
        assert body["pv2_current_amps"] is None, body
        assert body["pv2_charging_power_watts"] is None, body
        assert body["pv1_voltage_volts"] == 196.4, body
        # A NAK is an answer, not a lost frame.
        assert body["link_unsupported_commands"] == 1, body
        assert restarts() == before_restarts, "the service restarted over a NAK"

        # Asked once and then never again: re-asking every minute would spend wire time on a
        # command the unit has already declined.
        with lock:
            seen.discard("QPIGS2")
        next_status()
        next_status()
        with lock:
            assert "QPIGS2" not in seen, "QPIGS2 was re-sent after a NAK"

    # The identity is read at connect, but not ONLY at connect: protocol.md says these answers
    # cannot change while the unit is powered, so the case this covers is the one where the
    # premise is false -- a unit swapped behind the same adapter, which without the refresh keeps
    # being reported under the old serial number until something restarts the service.
    with subtest("the identity is re-read on the static refresh, not pinned at connect"):
        assert latest()["attributes"][
            "resource.attributes.inverter.serial_number"
        ] == "92932210103714", "this subtest needs the original serial to still be reported"

        with lock:
            state["serial"] = b"92932210109999"
            # Cleared so its reappearance is proof of a re-read rather than a memory of the
            # read at connect.
            seen.discard("QID")

        def reidentified(_):
            return latest()["attributes"].get(
                "resource.attributes.inverter.serial_number"
            ) == "92932210109999"

        # No restart and no reconnect anywhere in here: the refresh happens inside the running
        # session, between two ordinary poll cycles.
        before_restarts = restarts()
        retry(reidentified)
        assert restarts() == before_restarts, "the identity changed by way of a restart"
        with lock:
            assert "QID" in seen, "the serial number changed without QID being re-sent"

        # The whole set is re-read, not just the command that happened to change, and the rest
        # of the identity survives it.
        attributes = latest()["attributes"]
        assert attributes["resource.attributes.inverter.model"] == "MKS2-8000", attributes
        assert attributes["resource.attributes.inverter.firmware"] == "VERFW:00072.04", attributes

    with subtest("the producer is watched by the other producer"):
        # A long-running unit, so `active` means something -- which is why this one can be in
        # system-metrics' watch list where system-metrics itself cannot.
        machine.succeed("systemctl reset-failed system-metrics.service")
        machine.succeed("systemctl start system-metrics.service")

        def watched(_):
            return any(
                m["attributes"].get("record.attributes.unit") == "inverter-monitoring.service"
                for m in query() if m["type"] == "system.unit"
            )

        retry(watched)
        unit = next(
            m for m in query()
            if m["type"] == "system.unit"
            and m["attributes"].get("record.attributes.unit") == "inverter-monitoring.service"
        )
        assert unit["body"]["active_state"] == "active", unit["body"]

    # The other half of the taxonomy. A unit that stops answering entirely -- the cable pulled,
    # the adapter wedged -- is the case that SHOULD cost a restart, because nothing this process
    # can do will fix it and all it would otherwise produce is all-null rows forever.
    with subtest("a unit that goes silent ends the run so systemd can start it over"):
        # The wait is shortened here and only here. A runtime drop-in rather than a config
        # override, so the unit every other subtest ran against -- and the one the assertion
        # near the top is about -- is the one the hosts deploy, at the spec's 15 minutes.
        machine.succeed(
            "mkdir -p /run/systemd/system/inverter-monitoring.service.d",
            "printf '[Service]\\nRestartSec=5\\n' > "
            "/run/systemd/system/inverter-monitoring.service.d/fast-restart.conf",
            # Applies to the next restart; it does not touch the running process.
            "systemctl daemon-reload",
        )
        assert "RestartSec=5" in machine.succeed(
            "systemctl cat inverter-monitoring.service"
        ), "the drop-in did not take, and the wait below is 15 minutes long"

        before_restarts = restarts()
        with lock:
            state["mute"] = True

        machine.wait_until_succeeds(
            "test \"$(systemctl show -p NRestarts --value inverter-monitoring.service)\" "
            f"-gt {before_restarts}",
            timeout=180,
        )
        journal = machine.succeed("journalctl -u inverter-monitoring.service --no-pager")
        assert "answered nothing" in journal, journal

        # And it comes back on its own once the unit does: the restart is a recovery path, not
        # a tombstone.
        with lock:
            state["mute"] = False
        machine.wait_until_succeeds("systemctl is-active --quiet inverter-monitoring.service")
        # A cycle that read something, not merely one more record: every cycle of the silence
        # above published too, with its fields null, so "one more record" would be satisfied by
        # the mute rather than by the recovery from it.
        def answering(_):
            return latest()["body"]["battery_voltage_volts"] is not None

        retry(answering)

    # The third case, and the one the mute above is routinely mistaken for: the adapter itself goes
    # away mid-cycle. LAST, because the device does not come back.
    #
    # A hung-up tty answers a *read* with an instant zero-length result, byte-for-byte what an
    # unanswered command looks like, which is how the sibling producer came to treat a vanished
    # adapter as a quiet one and spin on it for 154 seconds when the fleet's Pi lost its xHCI
    # controller on 2026-08-21.
    #
    # This producer reaches the same end by a different road, and the difference is worth writing
    # down because it is why the fix here is less visible than the sibling's: it WRITES before every
    # read, and a write to a hung-up tty fails EIO outright. So in the poll loop the command is what
    # notices, and that path was already fatal and already prompt -- which is what the assertions
    # below check, since it is what actually happens.
    #
    # The read path still matters here, in the two places no write precedes it: `listen()` during
    # discovery, which probes for unprompted chatter and has no early exit at all, and a `read_frame`
    # whose write was accepted before the device went. Neither is reachable from this harness --
    # discovery only runs at boot and after a restart, by which time the adapter is simply absent
    # rather than vanishing mid-read -- so both are covered by unit tests against a real hangup on a
    # real fd instead. See packages/inverter-monitoring/src/port.rs.
    #
    # Asserted semantically rather than by the clock: a spin would show up as the response timeouts
    # it had to wait out, so their absence is what says the run ended on the disconnect.
    with subtest("an adapter that vanishes ends the run at once instead of reading as a mute unit"):
        machine.succeed("systemctl is-active --quiet inverter-monitoring.service")
        device = latest()["attributes"]["resource.attributes.inverter.device"]
        inv_tty = next(f"ttyUSB{n}" for n in range(3) if by_path_of(f"ttyUSB{n}") == device)
        before_restarts = restarts()

        # Everything it says from here on, and nothing it said before: the mute subtest above
        # produced the silence messages on purpose, so the negative assertions need a window.
        cursor = machine.succeed(
            "journalctl -u inverter-monitoring.service --no-pager -n0 --show-cursor "
            "| sed -n 's/^-- cursor: //p'"
        ).strip()
        assert cursor, "no journal cursor, so the assertions below would read the whole boot"

        # A genuine USB unplug: the guest takes it through its real ftdi_sio and its real udev.
        machine.send_monitor_command("device_del inv-dev")
        machine.wait_until_fails(f"test -e /dev/{inv_tty}", timeout=120)

        def gave_up(_):
            return restarts() > before_restarts

        retry(gave_up)
        after = machine.succeed(
            "journalctl -u inverter-monitoring.service --no-pager "
            f"--after-cursor '{cursor}'"
        )

        # It ended on the port rather than on the protocol: a lost adapter is not something a retry
        # can mend, and the module documents a 15-minute wait as the answer. Either half of the
        # exchange may be the one that notices -- the write does, here -- so this asserts the
        # property both share rather than pinning the message of whichever wins the race.
        assert "Input/output error" in after or "the port hung up" in after, after
        # And it got there without waiting out a single response timeout or counting a silent cycle,
        # which is what it would have done had the disconnect read as a mute unit.
        assert "timed out after" not in after, after
        assert "answered nothing" not in after, after
  '';
}
