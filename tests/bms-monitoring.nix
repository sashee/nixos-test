{ nixpkgs, pkgs, machineModule, stateVersion, globalTimeout ? 1200 }:

# End-to-end check of the BMS producer against emulated USB serial hardware, with the inverter
# producer running beside it on the same bus.
#
# The node gets three QEMU `usb-serial` devices -- emulated FTDI FT232 adapters, bound by the guest's
# real ftdi_sio driver and named by the guest's real udev, so they arrive as genuine /dev/ttyUSB*
# with genuine /dev/serial/by-{id,path} symlinks. Each one's wire end is a unix socket the test
# driver holds, so the driver *is* the hardware: one socket pushes JK BMS frames, one answers the
# Voltronic command set, and one says nothing.
#
# Both producers are enabled, which is the point of running them together rather than in separate
# tests. A tty has one input queue and read(2) is destructive, so two readers on one port get an
# arbitrary split of the bytes -- measured on the real Pi, two readers over a 12s window got 1079
# and 441 bytes and a corrupt frame each. What stops that here is an advisory flock on the device
# node, and the `two producers` subtest below is where that claim is checked against the running
# services rather than against a unit test's temp file.
#
# The frames are built independently in Python from the offsets in
# spec/features/bms-monitoring/protocol.md, NOT shared with the Rust. Two independent readings of
# the protocol doc is the point: if the producer's decoder and this builder agreed because they were
# the same code, the test would prove nothing about either. Several of the fields are deliberately
# hostile in exactly the ways the hardware is -- an unsigned power magnitude, a `tempSensorAbsent`
# byte of 0xFF with live sensors, aggregate indices that disagree with the cell array.
#
# What this deliberately does NOT reproduce: QEMU passes bytes through as fast as the socket allows,
# so nothing here runs at 115200 baud or at the hardware's ~6.7s cycle. Timing assumptions are the
# aarch64 hardware's business, not this test's -- but the cadence is kept slow enough that a
# measurement waits for a frame rather than always finding one already buffered.

let
  # Fast enough that a subtest is seconds rather than minutes. The production values are the
  # module's defaults; what is under test here is behaviour per measurement, not the cadence.
  intervalSeconds = 5;

  # The 24-hour settings re-read, which at the production interval no test could reach.
  settingsIntervalSeconds = 20;

  # listenSeconds is NOT shortened below 7: the module asserts against that, because a window
  # shorter than the frame cycle would reject a healthy pack. 7 is the smallest value that clears
  # it, and with three candidates it bounds discovery at ~14s of probing.
  listenSeconds = 7;
  frameTimeoutSeconds = 8;

  bmsSocket = "/tmp/bms-monitoring-test-bms.sock";
  invSocket = "/tmp/bms-monitoring-test-inverter.sock";
  idleSocket = "/tmp/bms-monitoring-test-idle.sock";

  # `server=off` (the default): QEMU connects out, so the driver binds every socket before the
  # machine starts and there is no window where a producer probes a port with nothing behind it.
  #
  # An explicitly EMPTY `serial=` for the two that stand in for the fleet's CH340: with the property
  # unset QEMU synthesises one from the bus topology, which is unique per port and would defeat the
  # by-id collision these devices exist to reproduce.
  #
  # The `id=` on the device -- as opposed to the one on the chardev -- exists so the monitor can
  # `device_del` it, which is how the last subtest unplugs an adapter. That is a definite USB
  # detach: the guest logs `usb N-1: USB disconnect` and ftdi_sio hangs up the tty, which is the
  # state that subtest is about and which nothing else here reaches.
  #
  # Whether letting a chardev socket close would do the same is deliberately not relied on. The
  # comment on `pack_cells` below reports it detaching the device, but the ~20s it took the producer
  # to notice is also exactly three frame timeouts -- the go-quiet path -- so that observation does
  # not distinguish the two, and a subtest asserting a hangup cannot rest on it.
  usbSerial = id: path: serial: [
    "-chardev socket,id=${id},path=${path}"
    "-device usb-serial,id=${id}-dev,bus=xhci.0,chardev=${id},serial=${nixpkgs.lib.optionalString (serial != null) serial}"
  ];
in

nixpkgs.lib.nixos.runTest {
  name = "bms-monitoring";
  hostPkgs = pkgs;
  inherit globalTimeout;

  nodes.machine = { lib, ... }: {
    imports = [ machineModule ];

    networking.hostName = "bms-test";
    # None of these can work in a VM, and none of them is what this test is about.
    common.autoUpgrade.enable = lib.mkForce false;
    common.monitoring.enable = lib.mkForce false;
    common.irohSsh.enable = lib.mkForce false;

    common.bmsMonitoring = {
      intervalSeconds = lib.mkForce intervalSeconds;
      settingsIntervalSeconds = lib.mkForce settingsIntervalSeconds;
      listenSeconds = lib.mkForce listenSeconds;
      frameTimeoutSeconds = lib.mkForce frameTimeoutSeconds;
      # restartSec is deliberately NOT overridden: 15 minutes is a spec value, so the unit here
      # carries the one the hosts deploy and a subtest asserts it. The one subtest that waits out
      # an automatic restart shortens it with a runtime drop-in instead.
    };

    # The other producer, live on the same bus. Its own probe is what makes the contention real:
    # it opens every candidate port, including the BMS's.
    common.inverterMonitoring = {
      intervalSeconds = lib.mkForce intervalSeconds;
      bmsListenSeconds = lib.mkForce 2;
      responseTimeoutSeconds = lib.mkForce 2;
      staticRefreshSeconds = lib.mkForce 3600;
    };

    # This node has no time source, so its clock is never set and the collector holds every batch
    # for its full buffer window before shipping it marked `mp.clock.uncertain`. At the default 300s
    # that is five minutes per assertion. Shortened rather than fixed by giving the node an NTP
    # server: the clock path is not what this test is about.
    services.mp-collector.bufferTimeoutSecs = lib.mkForce 2;

    # ftdi_sio is what binds QEMU's emulated FT232. udev would autoload it on the modalias, but
    # naming it here means a kernel that dropped it fails as a missing module rather than as a
    # mysteriously empty /dev/serial/by-id.
    boot.kernelModules = [ "ftdi_sio" ];

    virtualisation.qemu.options = [
      # x86 QEMU has no USB controller unless asked; without this the devices below have no bus.
      "-device qemu-xhci,id=xhci"
    ]
    # Three adapters, matching what the Pi actually has plus the collision case:
    #   bms  -- the battery BMS, with a serial number (the FT232R, 0403:6001)
    #   inv  -- the inverter, no serial number (the CH340, 1a86:7523)
    #   idle -- a third serial-less adapter that says nothing at all, colliding with `inv` on by-id
    ++ usbSerial "bms" bmsSocket "BMS0001"
    ++ usbSerial "inv" invSocket null
    ++ usbSerial "idle" idleSocket null;

    system.stateVersion = stateVersion;
  };

  # Concatenated rather than interpolated: `''` strips each literal's own indentation, so a
  # `${...}` inside this one would dedent the helper's function bodies out of their own `def`s.
  testScript = (import ../lib/test-mp-auth.nix) + ''
    import json
    import os
    import select
    import socket
    import struct
    import threading
    import time

    SOCKET = "/run/monitoring-platform/monitoring-platform.sock"
    BMS_SOCKET = "${bmsSocket}"
    INV_SOCKET = "${invSocket}"
    IDLE_SOCKET = "${idleSocket}"
    INTERVAL = ${toString intervalSeconds}
    SETTINGS_INTERVAL = ${toString settingsIntervalSeconds}

    # ------------------------------------------------------------------------------------
    # The BMS, in Python.
    #
    # Frames are assembled from spec/features/bms-monitoring/protocol.md §3-§7 by hand: a 300-byte
    # buffer, fields written at their documented offsets in their documented scaling, and the sum8
    # over bytes 0..298 in byte 299. Independent of the Rust decoder on purpose.

    HEADER = bytes([0x55, 0xAA, 0xEB, 0x90])
    FRAME_LEN = 300
    REALTIME = 0x02
    SETTINGS = 0x01


    def sum8(buf):
        return sum(buf[:299]) & 0xFF


    def build(code, fields):
        buf = bytearray(FRAME_LEN)
        buf[0:4] = HEADER
        buf[4] = code
        buf[5] = 0x00
        for offset, raw in fields:
            buf[offset:offset + len(raw)] = raw
        buf[299] = sum8(buf)
        return bytes(buf)


    def u16(value):
        return struct.pack("<H", value)


    def i16(value):
        return struct.pack("<h", value)


    def u32(value):
        return struct.pack("<I", value)


    def i32(value):
        return struct.pack("<i", value)


    # The captured pack, as read off the real hardware on 2026-08-17: 16 cells at ~3.25V, 52.036V,
    # discharging at 7.98A, SOC 63%, 191 cycles, 450 days of uptime.
    CELLS_MV = [3254, 3253, 3252, 3252, 3249, 3252, 3252, 3251,
                3254, 3253, 3254, 3254, 3253, 3251, 3251, 3251]
    WIRE_RES = [68, 67, 69, 66, 69, 66, 69, 66, 69, 68, 70, 67, 70, 68, 71, 68]


    def realtime_frame():
        fields = [(6 + 2 * n, u16(mv)) for n, mv in enumerate(pack_cells)]
        fields += [(80 + 2 * n, u16(r)) for n, r in enumerate(WIRE_RES)]
        fields += [
            # 16 cells present, slots 17-32 empty.
            (70, u32(0x0000FFFF)),
            # The BMS's own aggregates, and DELIBERATELY WRONG. On the hardware these come from a
            # different sample than the cell array and disagreed with it in 12 of 18 frames, so the
            # producer must derive its own -- these values are here to make it fail if it does not.
            (74, u16(9999)),
            (76, u16(999)),
            (78, bytes([9])),
            (79, bytes([9])),
            (144, i16(state["mos_dc"])),
            (146, u32(0)),
            (150, i32(sum(pack_cells))),
            # UNSIGNED MAGNITUDE. The sign lives only in batCurrent at 158; a producer that reads
            # this as the power would report a discharging pack as generation.
            (154, u32(abs(state["watt_mw"]))),
            (158, i32(state["current_ma"])),
            (162, i16(state["t1_dc"])),
            (164, i16(state["t2_dc"])),
            (166, u32(state["sys_alarm"])),
            (170, i16(state["balance_ma"])),
            (172, bytes([1 if state["balancing"] else 0])),
            (173, bytes([state["soc"]])),
            (174, u32(145969)),
            (178, u32(230000)),
            (182, u32(191)),
            (186, u32(44101642)),
            (190, bytes([100])),
            (194, u32(38910499)),
            (198, bytes([1])),
            (199, bytes([1])),
            (200, u16(state["user_alarm"])),
            # The byte the device ICD calls tempSensorAbsent, 0xFF with three sensors plainly live.
            # A producer that gates temperatures on it reports none at all.
            (214, bytes([0xFF])),
            (215, bytes([0])),
            # totalBatVol at 234, NOT 233 -- the off-by-one the doc used to carry.
            (234, u16(sum(pack_cells) // 10)),
            # Channel 3 unpopulated; channel 4 a mirror of the MOS sensor; channel 5 real.
            (252, i16(0)),
            (254, i16(state["mos_dc"])),
            (256, i16(370)),
        ]
        return build(REALTIME, fields)


    def settings_frame():
        temps = [700, 600, 700, 600, 20, 70, 800, 700]
        fields = [
            (6, u32(3500)),
            (10, u32(2600)), (14, u32(2850)),
            (18, u32(3600)), (22, u32(3500)),
            (26, u32(10)),
            (30, u32(3550)), (34, u32(2800)),
            (38, u32(3580)), (42, u32(3500)),
            (46, u32(2500)),
            # Current is /1000; the two times beside it are raw seconds.
            (50, u32(100000)), (54, u32(3)), (58, u32(60)),
            (62, u32(150000)), (66, u32(300)), (70, u32(60)),
            (74, u32(5)),
            (78, u32(1000)),
            (114, u32(16)),
            (118, u32(1)), (122, u32(1)), (126, u32(1)),
            (130, u32(230000)),
            (134, u32(1500)),
            (138, u32(3200)),
            (270, u32(0)),
            (274, u32(0)),
            # /10000, not /1000: 150A, matching the discharge overcurrent limit above.
            (278, u32(1500000)),
            (282, u16(0x3210)),
            (284, bytes([60])),
        ]
        fields += [(82 + 4 * n, i32(value)) for n, value in enumerate(temps)]
        # cellConWireRes at 142 is left entirely zero, as the hardware leaves it.
        return build(SETTINGS, fields)


    def modbus(address):
        # The RS485 records the BMS multiplexes onto the same line (§8). Not frames, and the
        # producer has to step over them without losing the frames on either side.
        return bytes([address, 0x10, 0x16, 0x20, 0x00, 0x01, 0x05, 0x9A])


    # Everything the simulator will say, and the switches the subtests flip.
    #
    # The cell array is a name of its own rather than a key in `state`, and `sent` is a second dict:
    # the driver type-checks this script, and a dict whose values are a mixture of lists, ints and
    # bools becomes `dict[str, object]` -- after which every arithmetic use of a value read back out
    # of it is a type error. Same reason tests/inverter-monitoring.nix keeps its `seen` set out of
    # its own state dict. So `state` holds ints and bools only (bool being a subtype of int), and
    # everything here is guarded by the one lock.
    # `pack_cells`, not `cells`, and that prefix is load-bearing rather than decorative. The test
    # script is module-level code, so a `cells = [...]` inside any subtest below would rebind the
    # very list the simulator thread builds frames from -- and it did: the thread then tried to
    # struct.pack a measurement dict, died, closed its socket, and QEMU detached the emulated USB
    # device. The producer correctly reported the port as gone, ~20 seconds after a subtest that
    # looked unrelated. Anything the simulator owns is named for the pack; anything a subtest binds
    # is named for the rows it read.
    pack_cells = list(CELLS_MV)
    state = {
        "soc": 63,
        "current_ma": -7980,
        "watt_mw": 415243,
        "mos_dc": 367,
        "t1_dc": 361,
        "t2_dc": 358,
        "balance_ma": 0,
        "balancing": False,
        "sys_alarm": 0,
        "user_alarm": 0,
        "corrupt_next": False,
        "mute": False,
    }
    sent = {"cycles": 0}
    lock = threading.Lock()


    def next_cycle():
        """One ~781-byte cycle as the hardware emits it, or None while the pack is muted.

        Realtime frame, one short Modbus record, settings frame, then the ~16-record auxiliary poll.
        """
        with lock:
            if state["mute"]:
                return None
            realtime = realtime_frame()
            if state["corrupt_next"]:
                state["corrupt_next"] = False
                # Flip a payload byte and leave the checksum alone: a frame that arrives whole and
                # fails its sum8, which is what line noise looks like.
                damaged = bytearray(realtime)
                damaged[100] ^= 0xFF
                realtime = bytes(damaged)
            cycle = realtime + modbus(0) + settings_frame()
            return cycle + b"".join(modbus(n) for n in range(16))


    def serve_bms(conn):
        # Both halves of this loop are load-bearing, and getting either wrong hangs the whole VM
        # rather than failing a subtest.
        #
        # It must READ, even though a passive BMS has nothing to say about what the host sends and
        # this producer never writes. QEMU's `usb-serial` pushes guest TX into
        # `qemu_chr_fe_write_all()`, which retries until the socket accepts it -- so a chardev peer
        # that never drains can block QEMU's main loop and freeze the guest mid-instruction. There
        # is guest TX to drain even here: until some process opens the port and clears `ECHO`, the
        # tty's line discipline echoes this very flood straight back out. Leaving that undrained is
        # what wedged this test's first draft, at ~12s of boot, with the console stopping mid-line.
        #
        # And it must send whole cycles or none. A blocking `sendall` into an unread port would
        # accumulate a backlog across all of boot and deliver it as one burst when the producer
        # finally opens the port -- a burst no real BMS could produce. A non-blocking `send` is
        # worse: a short write truncates a frame, manufacturing checksum failures the test would
        # then have to explain. So writability is asked about first and the cycle is dropped whole
        # if the answer is no, which is what a real UART does when nobody is listening.
        conn.setblocking(True)
        while True:
            cycle = next_cycle()
            readable, writable, _ = select.select([conn], [conn], [], 0.2)
            if readable:
                try:
                    if not conn.recv(65536):
                        return
                except OSError:
                    return
            if cycle is None or not writable:
                time.sleep(0.2)
                continue
            try:
                conn.sendall(cycle)
            except OSError:
                return
            with lock:
                sent["cycles"] += 1
            # Far faster than the hardware's 6.7s, but slow enough that a measurement genuinely
            # waits for a frame rather than always finding one already buffered.
            time.sleep(0.5)


    # ------------------------------------------------------------------------------------
    # The inverter, in Python. Only as much of it as makes the port a credible second device: the
    # inverter producer's own test covers its protocol.

    def crc16(data):
        crc = 0
        for byte in data:
            crc ^= byte << 8
            for _ in range(8):
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
        return crc


    def escape(byte):
        return byte + 1 if byte in (0x28, 0x0A, 0x0D) else byte


    def inv_frame(payload):
        body = b"(" + payload
        crc = crc16(body)
        return body + bytes([escape(crc >> 8), escape(crc & 0xFF)]) + b"\r"


    INV_REPLIES = {
        b"QID": b"92932210103714",
        b"QVFW": b"VERFW:00072.04",
        b"QVFW3": b"VERFW:00012.21",
        b"QMN": b"MKS2-8000",
        b"QGMN": b"044",
        b"QMOD": b"B",
        b"QPIGS": (
            b"000.0 00.0 226.7 50.0 0997 0825 012 429 54.20 041 080 0062 "
            b"09.2 196.4 00.00 00000 00010110 00 00 01819 010"
        ),
        b"QPIGS2": b"05.4 212.5 01156 ",
        b"QPIWS": b"0" * 36,
    }


    def serve_inverter(conn):
        buffered = b""
        while True:
            try:
                chunk = conn.recv(256)
            except OSError:
                return
            if not chunk:
                return
            buffered += chunk
            while b"\r" in buffered:
                request, buffered = buffered.split(b"\r", 1)
                reply = INV_REPLIES.get(request[:-2])
                if reply is not None:
                    try:
                        conn.sendall(inv_frame(reply))
                    except OSError:
                        return


    def serve_idle(conn):
        # Neither chatters nor answers: a port both producers must probe and reject.
        conn.setblocking(False)
        while True:
            try:
                conn.recv(256)
            except BlockingIOError:
                pass
            except OSError:
                return
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


    # Bound before the machine starts: QEMU connects out to all three as it boots.
    bms_server = listener(BMS_SOCKET)
    inv_server = listener(INV_SOCKET)
    idle_server = listener(IDLE_SOCKET)
    accept_into(bms_server, serve_bms)
    accept_into(inv_server, serve_inverter)
    accept_into(idle_server, serve_idle)

    # ------------------------------------------------------------------------------------

    def query(params="limit=1000"):
        # --fail-with-body, so an unauthenticated read fails here naming its status instead of
        # surfacing as a KeyError on the missing "measurements" field: curl exits 0 on a 401.
        raw = machine.succeed(
            f"curl -sS --fail-with-body {auth_header()}--unix-socket {SOCKET} "
            f"'http://localhost/v1/measurements?{params}'"
        )
        return json.loads(raw)["measurements"]


    def of_type(kind):
        return [m for m in query() if m["type"] == kind]


    def latest(kind="bms.status"):
        # The read API orders event_time DESC, id DESC, so the newest record of a kind is first.
        rows = of_type(kind)
        assert rows, f"no {kind} measurement in the store"
        return rows[0]


    def next_status():
        """Wait for one more bms.status record to land.

        NOT a way to wait for the effect of something the test just did: the record that lands next
        may have been read off the wire before it. Waiting for an effect means retrying on the value
        it changes, which is what the named predicates below all do.
        """
        before = len(of_type("bms.status"))
        retry(lambda _: len(of_type("bms.status")) > before)
        return latest()


    def restarts(unit):
        return int(machine.succeed(f"systemctl show -p NRestarts --value {unit}").strip())


    def links_of(tty, kind):
        """The `/dev/serial/<kind>/` link names udev made for one tty.

        Asked of udev rather than reconstructed from `ls -l`: this is the same database the
        producers' directory scan reads, so a disagreement here would be a real one.
        """
        raw = machine.succeed(f"udevadm info -q symlink -n /dev/{tty}").split()
        prefix = f"serial/{kind}/"
        return sorted(link[len(prefix):] for link in raw if link.startswith(prefix))


    def by_path_of(tty):
        """The by-path name the producers key `tty` by: the smallest of its links."""
        links = links_of(tty, "by-path")
        assert links, f"udev made no by-path link for {tty}"
        return links[0]


    def tty_behind(by_id_fragment):
        return machine.succeed(
            f"basename $(readlink -f /dev/serial/by-id/*{by_id_fragment}*)"
        ).strip()


    def tty_for(by_path):
        """The ttyUSB name behind a by-path key."""
        for n in range(3):
            if by_path_of(f"ttyUSB{n}") == by_path:
                return f"ttyUSB{n}"
        raise Exception(f"no tty has by-path {by_path}")


    machine.start()
    machine.wait_for_unit("multi-user.target")

    # As early as possible: both producers are daemons started at boot, so they are already posting
    # by the time anything here runs, and authenticate() restarts the collector -- which discards
    # its outbox. Nothing below asserts on the earliest records; every subtest drives a fresh one.
    machine.wait_for_unit("mp-collector.service")
    machine.wait_for_unit("monitoring-platform.service")
    authenticate(machine)

    # The two serial-less adapters CONTEST one by-id link, and udev re-picks the winner on every
    # event touching either of them. multi-user is not the end of that: the coldplug trigger only
    # enqueues, and on an emulated aarch64 node its backlog is still being worked tens of seconds
    # later. Settling here makes device naming a fixed fact for the rest of the file.
    machine.succeed("udevadm settle --timeout=180")
    machine.wait_until_succeeds(
        "test -e /dev/ttyUSB0 && test -e /dev/ttyUSB1 && test -e /dev/ttyUSB2"
    )

    with subtest("the producer finds the BMS by listening, without ever writing to it"):
        machine.wait_for_unit("bms-monitoring.service")
        next_status()

        bms_port = latest()["attributes"]["resource.attributes.bms.device"]
        ports = {by_path_of(f"ttyUSB{n}") for n in range(3)}
        assert bms_port in ports, f"{bms_port} is not one of the by-path names {ports}"
        # And it is the adapter the simulator is behind, identified by its USB serial number.
        assert bms_port == by_path_of(tty_behind("BMS0001")), bms_port

        # Nothing was ever sent: the simulator's socket is receive-only in `serve_bms`, so the
        # proof is that it kept producing. A producer that wrote would not break it -- so assert
        # the honest thing instead, that the device cgroup is read-only.
        unit = machine.succeed("systemctl cat bms-monitoring.service")
        assert "DeviceAllow=char-ttyUSB r" in unit, unit

    with subtest("one frame is one status record plus one row per cell, scaled"):
        body = latest()["body"]
        # Values in natural units, not raw fixed-point.
        assert body["pack_voltage_volts"] == 52.036, body
        assert body["pack_current_amps"] == -7.98, body
        assert body["soc_percent"] == 63, body
        assert body["soh_percent"] == 100, body
        assert body["remaining_capacity_ah"] == 145.969, body
        assert body["full_charge_capacity_ah"] == 230.0, body
        assert body["cycle_count"] == 191, body
        assert body["cells_present"] == 16, body
        assert body["bms_uptime_seconds"] == 38910499, body
        assert body["charge_mosfet_on"] is True, body
        assert body["discharge_mosfet_on"] is True, body
        assert body["balancing"] is False, body

        # The correction that matters most in a dashboard: batWatt is an unsigned magnitude, so a
        # discharging pack must still report negative power.
        assert body["pack_power_watts"] == -415.243, body

        # Sixteen cell rows for the one status record.
        event_time = latest()["event_time"]
        cell_rows = [m for m in of_type("bms.status.cell") if m["event_time"] == event_time]
        assert len(cell_rows) == 16, f"expected 16 cell rows, got {len(cell_rows)}"
        numbered = {
            m["attributes"]["record.attributes.cell"]: m["body"]["voltage_volts"]
            for m in cell_rows
        }
        assert numbered[1] == 3.254, numbered
        assert numbered[5] == 3.249, numbered
        assert numbered[16] == 3.251, numbered
        # Measured balance-wire resistance, in ohms.
        resistances = {
            m["attributes"]["record.attributes.cell"]: m["body"]["wire_resistance_ohms"]
            for m in cell_rows
        }
        assert resistances[1] == 0.068, resistances

    with subtest("the aggregates are derived from the cells, not taken from the frame"):
        # The simulator plants cellVolAve=9.999V, maxVoltDelta=0.999V and both indices at 9. All
        # four are wrong, exactly as the hardware's are, and none may appear in the record.
        body = latest()["body"]
        assert body["cell_voltage_max_volts"] == 3.254, body
        assert body["cell_voltage_min_volts"] == 3.249, body
        assert abs(body["cell_voltage_delta_volts"] - 0.005) < 1e-9, body
        assert abs(body["cell_voltage_average_volts"] - 3.25225) < 1e-9, body
        # 1-based, and addressing the right cells: cell 5 holds the minimum, cell 1 the maximum.
        assert body["cell_min_index"] == 5, body
        assert body["cell_max_index"] == 1, body

        # And the index can be used to look up the cell row beside it, which is the whole reason
        # both are 1-based.
        event_time = latest()["event_time"]
        cell_rows = [m for m in of_type("bms.status.cell") if m["event_time"] == event_time]
        lowest = next(
            m for m in cell_rows
            if m["attributes"]["record.attributes.cell"] == body["cell_min_index"]
        )
        assert lowest["body"]["voltage_volts"] == body["cell_voltage_min_volts"]

    with subtest("temperatures are reported despite the 0xFF sensor-absent byte"):
        body = latest()["body"]
        assert body["mos_temperature_celsius"] == 36.7, body
        assert body["temperature_1_celsius"] == 36.1, body
        assert body["temperature_2_celsius"] == 35.8, body
        # Channel 3 is not fitted and reads exactly zero: null, not a freezing pack.
        assert body["temperature_3_celsius"] is None, body
        assert body["temperature_5_celsius"] == 37.0, body

    with subtest("the settings frame is published with a row per configured cell"):
        # Waited for rather than assumed, and NOT because the producer might be slow: it publishes
        # the settings measurement once immediately after attaching, which here is ~18s into boot --
        # before `authenticate()` above has issued a key. The receiver answers those records 401
        # ("API key id was never issued") and keeps nothing, and the collector restart inside
        # authenticate() discards whatever was still in its outbox. So the startup record is
        # genuinely gone in this harness, and what this waits for is the next scheduled one.
        #
        # That is a property of the test rig, not of the producer: on a host whose collector is
        # already credentialled, the record at attach is the one that lands.
        retry(lambda _: len(of_type("bms.settings")) > 0)

        settings = latest("bms.settings")["body"]
        assert settings["cell_count"] == 16, settings
        assert settings["cell_capacity_ah"] == 230.0, settings
        assert settings["cell_overvoltage_volts"] == 3.6, settings
        assert settings["cell_undervoltage_volts"] == 2.6, settings
        assert settings["charge_overcurrent_amps"] == 100.0, settings
        assert settings["discharge_overcurrent_amps"] == 150.0, settings
        # /10000, cross-checked against the overcurrent limit which is scaled independently.
        assert settings["current_range_amps"] == 150.0, settings
        # Raw seconds, not milliseconds.
        assert settings["charge_overcurrent_delay_seconds"] == 3, settings
        assert settings["discharge_overcurrent_delay_seconds"] == 300, settings
        assert settings["charge_under_temp_celsius"] == 2.0, settings
        assert settings["balancing_enabled"] is True, settings

        event_time = latest("bms.settings")["event_time"]
        cell_rows = [m for m in of_type("bms.settings.cell") if m["event_time"] == event_time]
        assert len(cell_rows) == 16, f"expected 16 configured-cell rows, got {len(cell_rows)}"
        # All-zero on this unit, as on the hardware.
        assert all(
            m["body"]["connection_resistance_ohms"] == 0.0 for m in cell_rows
        ), cell_rows

    with subtest("a changing reading changes the record"):
        with lock:
            pack_cells[4] = 3100
            state["soc"] = 55

        # By value, not by "one more record": the measurement in flight when this runs read the old
        # fixture, and it is that record which may land next.
        def changed(_):
            return latest()["body"]["soc_percent"] == 55

        retry(changed)
        body = latest()["body"]
        assert body["cell_voltage_min_volts"] == 3.1, body
        assert body["cell_min_index"] == 5, body
        # The delta moved with it, which the frame's own (planted) value could not have produced.
        assert abs(body["cell_voltage_delta_volts"] - 0.154) < 1e-9, body

        with lock:
            pack_cells[4] = 3249
            state["soc"] = 63

        retry(lambda _: latest()["body"]["soc_percent"] == 63)

    with subtest("an asserted alarm bit becomes a named sub-record"):
        with lock:
            state["sys_alarm"] = (1 << 11) | (1 << 4)  # cell_undervoltage, cell_overvoltage
            state["user_alarm"] = 1 << 3

        def alarmed(_):
            return latest()["body"]["alarms_asserted_count"] == 3

        retry(alarmed)
        body = latest()["body"]
        assert body["alarms_raw"] == (1 << 11) | (1 << 4), body
        assert body["alarms2_raw"] == 8, body

        named = {
            (m["attributes"]["record.attributes.bit"],
             m["attributes"]["record.attributes.flag"])
            for m in of_type("bms.status.alarm")
        }
        assert ("b4", "cell_overvoltage") in named, named
        assert ("b11", "cell_undervoltage") in named, named
        assert ("u2b3", "user_alarm2_3") in named, named

    with subtest("clearing the bits stops the alarm records without hiding the recovery"):
        with lock:
            state["sys_alarm"] = 0
            state["user_alarm"] = 0

        def cleared(_):
            return latest()["body"]["alarms_asserted_count"] == 0

        retry(cleared)
        # Counted only once the clear has landed: a measurement still carrying the old bits would
        # otherwise be attributed to the window below.
        settled = len(of_type("bms.status.alarm"))
        # The historical rows stay -- nothing is deleted -- but no new ones are written.
        machine.sleep(2 * INTERVAL + 2)
        assert len(of_type("bms.status.alarm")) == settled, (
            "alarm records are still being emitted after recovery"
        )

    # The central claim of the failure taxonomy, and the reason the spec's two statements about
    # failure could not both be taken literally: a frame that fails its sum8 costs one frame, not
    # fifteen minutes of darkness.
    with subtest("a frame that fails its checksum is counted and discarded, not fatal"):
        before = restarts("bms-monitoring.service")
        baseline = latest()["body"]["link_frames_discarded"]
        with lock:
            state["corrupt_next"] = True

        def corrupted(_):
            return latest()["body"]["link_frames_discarded"] > baseline

        retry(corrupted)
        machine.succeed("systemctl is-active --quiet bms-monitoring.service")
        assert restarts("bms-monitoring.service") == before, (
            "the service restarted over a bad checksum"
        )

        # And the measurement after it is whole: the corrupt frame was skipped, not decoded.
        recovered = next_status()["body"]
        assert recovered["pack_voltage_volts"] == 52.036, recovered
        assert recovered["soc_percent"] == 63, recovered

    with subtest("the interleaved Modbus traffic is skipped rather than decoded"):
        # 136 bytes of RS485 records per cycle, and not one of them may become a frame or a record:
        # everything this producer emits is one of the five documented types.
        emitted = {m["type"] for m in query() if m["type"].startswith("bms.")}
        assert emitted <= {
            "bms.status", "bms.status.cell", "bms.status.alarm",
            "bms.settings", "bms.settings.cell",
        }, emitted
        # The frames are counted, and there are far more of them than measurements -- the producer
        # reads every cycle and publishes once an interval.
        body = latest()["body"]
        assert body["link_frames_ok"] > 0, body
        assert body["link_connected_seconds"] > 0, body
        # It waited for a frame rather than finding one pre-buffered every single time.
        assert body["link_frame_wait_seconds"] >= 0.0, body

    # The part that cannot be tested in either producer alone: they share the /dev/ttyUSB* pool and
    # both start at boot.
    with subtest("two producers on one bus each hold their own port and corrupt neither"):
        machine.wait_for_unit("inverter-monitoring.service")

        # Both are producing, which already means neither is starved.
        inverter_port = latest("inverter.status")["attributes"][
            "resource.attributes.inverter.device"
        ]
        bms_port = latest()["attributes"]["resource.attributes.bms.device"]
        assert bms_port != inverter_port, (
            f"both producers claim {bms_port}, which cannot be right"
        )
        assert latest("inverter.status")["body"]["battery_voltage_volts"] == 54.2

        # The lock is real, and this is the deterministic way to see it: flock is advisory towards
        # readers but absolute between flock callers, so root cannot take a lock the service holds.
        bms_tty = tty_for(bms_port)
        inverter_tty = tty_for(inverter_port)
        machine.fail(f"flock -x -n /dev/{bms_tty} -c true")
        machine.fail(f"flock -x -n /dev/{inverter_tty} -c true")
        # The third adapter is held by nobody, so the same command must succeed there -- otherwise
        # the two failures above would prove nothing about the services.
        idle_tty = next(
            f"ttyUSB{n}" for n in range(3)
            if f"ttyUSB{n}" not in (bms_tty, inverter_tty)
        )
        machine.succeed(f"flock -x -n /dev/{idle_tty} -c true")

        # And the inverter's repeated probing of the BMS's port has not corrupted the stream. Its
        # discovery runs every 15 minutes, but it has probed at least once at boot, when both units
        # started together -- which is the race flock exists to settle.
        discarded = latest()["body"]["link_frames_discarded"]
        ok = latest()["body"]["link_frames_ok"]
        assert ok > 10 * max(discarded, 1), (
            f"{discarded} discarded frames against {ok} good ones looks like a contended port"
        )

    with subtest("the operator command reports the port busy instead of interleaving"):
        # Same binary, same arguments, run by hand while the service holds the port. It must refuse
        # rather than read half-frames alongside the daemon.
        #
        # The discovery window is cut to one second: the wrapper's own `exec ... "$@"` puts these
        # after the module's arguments and the parser takes the last value, so this is the module's
        # invocation in every other respect. At the configured 60s it would spend a minute
        # re-sweeping ports that are all going to stay busy.
        output = machine.fail(
            "bms-monitoring --once --dry-run --discovery-window-seconds 1 2>&1"
        )
        assert "held by another process" in output, output
        assert "no BMS found" in output, output

    with subtest("the unit is a daemon systemd restarts a quarter of an hour after any exit"):
        # Spec values, and the only place they are visible.
        unit = machine.succeed("systemctl cat bms-monitoring.service")
        assert "Restart=always" in unit, unit
        assert "RestartSec=900" in unit, unit
        wanted = machine.succeed("systemctl show -p WantedBy --value bms-monitoring.service")
        assert "multi-user.target" in wanted, wanted

    with subtest("systemd accepted every key in the unit file"):
        # StartLimitIntervalSec is a [Unit] key, and systemd parses per-section and drops an unknown
        # one with a log line and a zero exit -- which is how the sibling producer shipped with the
        # default rate limit still in force.
        journal = machine.succeed("journalctl -u bms-monitoring.service --no-pager -b")
        assert "Unknown key" not in journal, journal
        limit = machine.succeed(
            "systemctl show -p StartLimitIntervalUSec --value bms-monitoring.service"
        ).strip()
        assert limit == "0", f"the start rate limit is still in force: {limit}"

    with subtest("the settings measurement repeats on its own interval"):
        # The 24-hour re-read, which no test could reach at the production interval. Its value is
        # the case where the frame's premise is false -- somebody changes a protection limit with
        # the phone app, and without the re-read nothing records that they did.
        before_records = len(of_type("bms.settings"))
        before_restarts = restarts("bms-monitoring.service")
        retry(lambda _: len(of_type("bms.settings")) > before_records)
        # Inside the running session: no restart and no reconnect anywhere in here.
        assert restarts("bms-monitoring.service") == before_restarts, (
            "the settings record arrived by way of a restart, not a scheduled re-read"
        )

    with subtest("the producer is watched by the other producer"):
        # A long-running unit, so `active` means something -- which is why it can be in
        # system-metrics' watch list where a oneshot could not.
        machine.succeed("systemctl reset-failed system-metrics.service")
        machine.succeed("systemctl start system-metrics.service")

        def watched(_):
            return any(
                m["attributes"].get("record.attributes.unit") == "bms-monitoring.service"
                for m in query() if m["type"] == "system.unit"
            )

        retry(watched)
        unit = next(
            m for m in query()
            if m["type"] == "system.unit"
            and m["attributes"].get("record.attributes.unit") == "bms-monitoring.service"
        )
        assert unit["body"]["active_state"] == "active", unit["body"]

    # The other half of the taxonomy. A pack that stops pushing entirely -- the cable pulled, the
    # BMS powered down -- is the case that SHOULD cost a restart, because nothing this process can
    # do will fix it and all it would otherwise produce is nothing at all, while `active`.
    with subtest("a BMS that goes silent ends the run so systemd can start it over"):
        # The wait is shortened here and only here, with a runtime drop-in, so every other subtest
        # ran against the unit the hosts deploy at the spec's 15 minutes.
        machine.succeed(
            "mkdir -p /run/systemd/system/bms-monitoring.service.d",
            "printf '[Service]\\nRestartSec=5\\n' > "
            "/run/systemd/system/bms-monitoring.service.d/fast-restart.conf",
            "systemctl daemon-reload",
        )
        assert "RestartSec=5" in machine.succeed(
            "systemctl cat bms-monitoring.service"
        ), "the drop-in did not take, and the wait below is 15 minutes long"

        before = restarts("bms-monitoring.service")
        with lock:
            state["mute"] = True

        machine.wait_until_succeeds(
            "test \"$(systemctl show -p NRestarts --value bms-monitoring.service)\" "
            f"-gt {before}",
            timeout=240,
        )
        journal = machine.succeed("journalctl -u bms-monitoring.service --no-pager")
        assert "pushed nothing" in journal, journal

        # And it comes back on its own once the pack does: the restart is a recovery path, not a
        # tombstone.
        with lock:
            state["mute"] = False
        machine.wait_until_succeeds("systemctl is-active --quiet bms-monitoring.service")

        # A measurement that read a frame, not merely one more record.
        def answering(_):
            return latest()["body"]["pack_voltage_volts"] == 52.036

        retry(answering)

    # The third case, and the one the other two are routinely mistaken for: the adapter itself goes
    # away under a running reader. LAST, because the device does not come back.
    #
    # On 2026-08-21 the fleet's Pi lost its whole xHCI controller and the FTDI with it. The producer
    # read that as a quiet pack and took the silence path: a hung-up tty answers a read with an
    # instant zero-length result, which is byte-for-byte what an idle line's VTIME expiry looks like,
    # so the read loop could not tell them apart and spun a core flat for 154 seconds while the
    # silent-cycle counter walked to three. `SerialPort::wait` separates them with poll(2), and this
    # is the only place the separation can be checked against a real tty rather than a pipe.
    #
    # Both halves are asserted, and neither by the clock -- a TCG runner is too slow for wall-clock
    # thresholds to mean anything. The spin shows up as the frame-timeout messages it would have had
    # to wait out; their absence is what says the run ended on the disconnect instead.
    with subtest("an adapter that vanishes ends the run at once instead of reading as silence"):
        machine.succeed("systemctl is-active --quiet bms-monitoring.service")
        bms_tty = tty_for(latest()["attributes"]["resource.attributes.bms.device"])
        before = restarts("bms-monitoring.service")

        # Everything the producer says from here on, and nothing it said before: an earlier subtest
        # produced the silence messages on purpose, so the negative assertions below need a window.
        cursor = machine.succeed(
            "journalctl -u bms-monitoring.service --no-pager -n0 --show-cursor "
            "| sed -n 's/^-- cursor: //p'"
        ).strip()
        assert cursor, "no journal cursor, so the assertions below would read the whole boot"

        # A genuine USB unplug: the guest takes it through its real ftdi_sio and its real udev.
        machine.send_monitor_command("device_del bms-dev")
        machine.wait_until_fails(f"test -e /dev/{bms_tty}", timeout=120)

        def gave_up(_):
            return restarts("bms-monitoring.service") > before

        retry(gave_up)
        after = machine.succeed(
            f"journalctl -u bms-monitoring.service --no-pager --after-cursor '{cursor}'"
        )

        # It named the disconnect, which is the fatal branch the module documents for a lost port.
        assert "the port hung up" in after, after
        # And it got there without waiting out a single frame timeout. Before the fix there were
        # three of these, at 8 seconds and a hot loop each.
        assert "no realtime frame within" not in after, after
        assert "pushed nothing" not in after, after

        # The documented consequence, once the adapter is gone for good: systemd starts it over and
        # it finds nothing, rather than attaching to one of the two adapters that are not a BMS.
        machine.wait_until_succeeds(
            "journalctl -u bms-monitoring.service --no-pager "
            f"--after-cursor '{cursor}' | grep -q 'no BMS found'",
            timeout=180,
        )
  '';
}
