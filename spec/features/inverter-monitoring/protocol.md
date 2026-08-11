# Inverter serial protocol

## Physical layer

| Setting | Value |
| --- | --- |
| Baud rate | 2400 |
| Data bits | 8 |
| Parity | none |
| Stop bits | 1 |
| Flow control | none |

The device is half-duplex request/response: it never speaks unsolicited.

## Framing

Both directions use the same frame:

```
request:   <ASCII command> <CRC hi> <CRC lo> 0x0D
response:  0x28 '('  <ASCII payload>  <CRC hi> <CRC lo> 0x0D
```

- Responses always start with `(` (`0x28`) and end with `<CR>` (`0x0D`).
- The two CRC bytes sit immediately before the `<CR>`.
- The CRC is computed over **everything from the leading `(` up to but not including the
  CRC bytes** — i.e. `frame[0 .. -3]`. The `<CR>` is *not* covered.
- Payload = `frame[1 .. -3]`. Payload length is fixed per command (see each section), so
  total frame length is `payload_len + 4`.
- The payload is plain ASCII. Space-separated fields are fixed-width and zero-padded;
  never rely on splitting alone, and never `parseFloat` a field without checking its
  width — a width change means a firmware change you want to notice.

### CRC

CRC-16/XMODEM (poly `0x1021`, init `0x0000`, no reflection, no final XOR), transmitted
big-endian, **then** post-processed:

> Any CRC byte equal to `0x28` (`(`), `0x0A` (`LF`) or `0x0D` (`CR`) is incremented by one.

This substitution keeps CRC bytes from colliding with the framing bytes. It is a
Voltronic quirk, not part of standard XMODEM.

## Command summary

Request frames are constant — precomputed here so you never need to derive them at runtime.

| Command | Request frame (hex) | Payload len | Purpose | Volatility |
| --- | --- | --- | --- | --- |
| `QID` | `51 49 44 D6 EA 0D` | 14 | Serial number | static |
| `QVFW` | `51 56 46 57 62 99 0D` | 14 | Main CPU firmware | static |
| `QVFW3` | `51 56 46 57 33 D3 D4 0D` | 14 | Remote panel firmware | static |
| `QMN` | `51 4D 4E BB 64 0D` | 9 | Model name | static |
| `QGMN` | `51 47 4D 4E 49 29 0D` | 3 | General model code | static |
| `QMOD` | `51 4D 4F 44 49 C1 0D` | 1 | Operating mode | live |
| `QPIGS` | `51 50 49 47 53 B7 A9 0D` | 106 | General status / PV1 | live |
| `QPIGS2` | `51 50 49 47 53 32 68 2D 0D` | 17 | PV2 status | live |
| `QPIWS` | `51 50 49 57 53 B4 DA 0D` | 36 | Warning / fault bits | live |

The five `static` commands only need to be read once at startup (or on reconnect) — they
identify the unit and cannot change while it is powered. Poll only `QMOD`, `QPIGS`,
`QPIGS2` and `QPIWS` on an interval.

## Identity commands

### `QID` — serial number

```
→ 51 49 44 D6 EA 0D                                            QID<CRC><CR>
← 28 39 32 39 33 32 32 31 30 31 30 33 37 31 34 CE AE 0D         (92932210103714<CRC><CR>
```

### `QVFW` — main CPU firmware version

```
→ 51 56 46 57 62 99 0D                                         QVFW<CRC><CR>
← 28 56 45 52 46 57 3A 30 30 30 37 32 2E 30 34 8A B4 0D         (VERFW:00072.04<CRC><CR>
```

14-byte payload, fixed literal prefix `VERFW:` then `NNNNN.NN`:

| Offset | Len | Field | Value | Notes |
| --- | --- | --- | --- | --- |
| 0 | 6 | prefix | `VERFW:` | literal, no trailing space |
| 6 | 5 | firmware series | `00072` | hex digits `0-9A-F` per PDF; observed decimal |
| 11 | 1 | separator | `.` | |
| 12 | 2 | version | `04` | hex digits `0-9A-F` per PDF; observed decimal |

Treat the whole `00072.04` as an opaque version string. Do not parse it as a decimal
number — the PDF states the digits are hex, so `0A` is a legal value that would compare
wrongly as a float.

### `QVFW3` — remote panel CPU firmware version

```
→ 51 56 46 57 33 D3 D4 0D                                      QVFW3<CRC><CR>
← 28 56 45 52 46 57 3A 30 30 30 31 32 2E 32 31 71 F6 0D         (VERFW:00012.21<CRC><CR>
```

Identical layout to `QVFW` (14-byte payload, `VERFW:NNNNN.NN`), reporting the secondary
(remote display panel) CPU instead. On this unit: `00012.21`.

### `QMN` — model name

```
→ 51 4D 4E BB 64 0D                                            QMN<CRC><CR>
← 28 4D 4B 53 32 2D 38 30 30 30 B2 8D 0D                        (MKS2-8000<CRC><CR>
```

9-byte payload, free-form ASCII model string: `MKS2-8000`.

Payload length is **model-dependent**, not fixed at 9. A length-keyed frame reader must
locate the terminating `<CR>` and CRC-check rather than assume a size for this command.

### `QGMN` — general model code

```
→ 51 47 4D 4E 49 29 0D                                         QGMN<CRC><CR>
← 28 30 34 34 C8 AE 0D                                          (044<CRC><CR>
```

3-byte payload, ASCII digits: `044`. A numeric family code; treat as an opaque string
(leading zero is significant).

## Live status commands

### `QMOD` — operating mode

```
→ 51 4D 4F 44 49 C1 0D                                         QMOD<CRC><CR>
← 28 42 E7 C9 0D                                                (B<CRC><CR>
```

1-byte payload, single ASCII letter:

| Code | Mode |
| --- | --- |
| `P` | Power on |
| `S` | Standby |
| `L` | Line (grid) |
| `B` | Battery |
| `F` | Fault |
| `D` | Shutdown |
| `C` | Charge |
| `Y` | Bypass |
| `E` | ECO |

### `QPIGS` — general status parameters

```
→ 51 50 49 47 53 B7 A9 0D                                      QPIGS<CRC><CR>
← (000.0 00.0 226.7 50.0 0997 0825 012 429 54.20 041 080 0062 09.2 196.4 00.00 00000 00010110 00 00 01819 010<CRC><CR>
```

**Payload: exactly 106 bytes**, 21 space-separated fixed-width fields. Total frame 110 bytes.

| # | Offset | Format | Field (parser name) | Unit | Sample |
| --- | --- | --- | --- | --- | --- |
| 1 | 0 | `NNN.N` | `grid_voltage` | V | `000.0` |
| 2 | 6 | `NN.N` | `grid_frequency` | Hz | `00.0` |
| 3 | 11 | `NNN.N` | `ac_output_voltage` | V | `226.7` |
| 4 | 17 | `NN.N` | `ac_output_frequency` | Hz | `50.0` |
| 5 | 22 | `NNNN` | `ac_output_apparent_power` | VA | `0997` |
| 6 | 27 | `NNNN` | `ac_output_active_power` | W | `0825` |
| 7 | 32 | `NNN` | `output_load_percent` | % | `012` |
| 8 | 36 | `NNN` | `bus_voltage` | V | `429` |
| 9 | 40 | `NN.NN` | `battery_voltage` | V | `54.20` |
| 10 | 46 | `NNN` | `battery_charging_current` | A | `041` |
| 11 | 50 | `NNN` | `battery_capacity` | % | `080` |
| 12 | 54 | `NNNN` | `inverter_heat_sink_temperature` | °C | `0062` |
| 13 | 59 | `NN.N` | `pv_input_current1` | A | `09.2` |
| 14 | 64 | `NNN.N` | `pv_input_voltage1` | V | `196.4` |
| 15 | 70 | `NN.NN` | `battery_voltage_from_scc1` | V | `00.00` |
| 16 | 76 | `NNNNN` | `battery_discharge_current` | A | `00000` |
| 17 | 82 | 8 bits | device status 1 — see below | — | `00010110` |
| 18 | 91 | `NN` | `battery_voltage_from_fans_on` | 10 mV | `00` |
| 19 | 94 | `NN` | `eeprom_version` | — | `00` |
| 20 | 97 | `NNNNN` | `pv_charging_power1` | W | `01819` |
| 21 | 103 | 3 bits | device status 2 — see below | — | `010` |

Field 17 — device status 1, `b7`…`b0` in **left-to-right** payload order:

| Char idx | Bit | Field (parser name) | Meaning |
| --- | --- | --- | --- |
| 82 | b7 | `add_sbu_priority_version` | 1 = SBU priority version present |
| 83 | b6 | `configuration_status` | 1 = configuration changed |
| 84 | b5 | `scc_firmware_version` | 1 = SCC firmware updated |
| 85 | b4 | `load_status` | 1 = load on, 0 = load off |
| 86 | b3 | `battery_voltage_to_steady_while_charging` | |
| 87 | b2 | `charging_status` | charging active |
| 88 | b1 | `charging_status_scc_1` | SCC (solar) charging on |
| 89 | b0 | `charging_status_ac` | AC (utility) charging on |

`b2 b1 b0` combinations: `000` idle, `110` charging from SCC, `101` charging from AC,
`111` charging from both.

Field 21 — device status 2, `b10`…`b8` in left-to-right payload order:

| Char idx | Bit | Field (parser name) | Meaning |
| --- | --- | --- | --- |
| 103 | b10 | `flag_for_charging_to_flating_mode` | 1 = float charge stage |
| 104 | b9 | `switch_on` | |
| 105 | b8 | `device_status_2_reserved` | dustproof-installed flag on Axpert V; reserved here |

The parser name `device_status_2_reserved` is a misnomer kept for schema stability — the
PDF assigns b8 to "dustproof installed", which does not apply to this model.

**Width constraints to be aware of.** Fields 5 and 6 are 4 digits on this 8000 VA unit.
The PDF notes that units rated above 9999 VA widen them to 5 digits, which would shift
every subsequent offset and change the payload length. The current parser hardcodes 4
digits and would reject such a frame outright rather than mis-parse it — acceptable, but
it means this table is specific to ≤9999 VA models.

**The payload ends at field 21 on this device.** The PDF documents four further trailing
fields (`Y` solar-feed-to-grid status, `ZZ` country regulation, `AAAA` feed-in power,
`BB.B` grid input current) for a 122-byte payload. This firmware does not send them. The
parser anchors the pattern at 106 bytes, so a firmware update that adds them would be
rejected loudly instead of silently misread — verify on hardware before extending.

### `QPIGS2` — PV2 status parameters

```
→ 51 50 49 47 53 32 68 2D 0D                                   QPIGS2<CRC><CR>
← 28 30 35 2E 34 20 32 31 32 2E 35 20 30 31 31 35 36 20 45 E4 0D   (05.4 212.5 01156 <CRC><CR>
```

**Payload: exactly 17 bytes**, 3 fields plus a trailing space. Total frame 21 bytes.

| # | Offset | Format | Field (parser name) | Unit | Sample |
| --- | --- | --- | --- | --- | --- |
| 1 | 0 | `NN.N` | `pv_input_current2` | A | `05.4` |
| 2 | 5 | `NNN.N` | `pv_input_voltage2` | V | `212.5` |
| 3 | 11 | `NNNNN` | `pv_charging_power2` | W | `01156` |
| — | 16 | `' '` | trailing space | — | ` ` |

**The trailing space at offset 16 is real and is covered by the CRC.** The PDF describes a
16-byte payload with no trailing space; the device sends 17. In the capture above the CRC
is `45 E4` — the `45` byte is the CRC high byte, not an ASCII `E`, which is an easy
misread when eyeballing frames. Any parser must include the trailing space or the CRC
check fails.

### `QPIWS` — warning and fault status

```
→ 51 50 49 57 53 B4 DA 0D                                      QPIWS<CRC><CR>
← 28 30 30 30 30 30 31 30 30 30 30 30 30 30 30 30 30 30 31 30 …  (000001000000000001000000000000000000<CRC><CR>
```

**Payload: exactly 36 bytes**, each an ASCII `0` or `1`. Total frame 40 bytes. Bit `aN` is
at payload offset `N`, left to right. `1` = asserted.

| Bit | Field (normative) | Meaning |
| --- | --- | --- |
| a0 | `reserved1` | reserved |
| a1 | `inverter_fault` | Inverter fault |
| a2 | `bus_over` | Bus over |
| a3 | `bus_under` | Bus under |
| a4 | `bus_soft_fail` | Bus soft fail |
| a5 | `line_fail` | Line (grid) fail |
| a6 | `opvshort` | Output voltage short |
| a7 | `inverter_voltage_too_low` | Inverter voltage too low |
| a8 | `inverter_voltage_too_high` | Inverter voltage too high |
| a9 | `over_temperature` | Over temperature |
| a10 | `fan_locked` | Fan locked |
| a11 | `battery_voltage_high` | Battery voltage high |
| a12 | `battery_low_alarm` | Battery low alarm |
| a13 | `reserved_overcharge` | reserved |
| a14 | `battery_under_shutdown` | Battery under shutdown |
| a15 | `reserved_battery_derating` | Battery derating |
| a16 | `over_load` | Over load |
| a17 | `eeprom_fault` | EEPROM fault |
| a18 | `inverter_over_current` | Inverter over current |
| a19 | `inverter_soft_fail` | Inverter soft fail |
| a20 | `self_test_fail` | Self test fail |
| a21 | `op_dv_voltage_over` | Output DC voltage over |
| a22 | `bat_open` | Battery open |
| a23 | `current_sensor_fail` | Current sensor fail |
| a24 | `battery_short` | Battery short |
| a25 | `power_limit` | Power limit |
| a26 | `pv_voltage_high_1` | PV1 voltage high |
| a27 | `mppt_overload_fault_1` | MPPT1 overload fault |
| a28 | `mppt_overload_warning_1` | MPPT1 overload warning |
| a29 | `battery_too_low_to_charge_1` | Battery too low to charge (PV1) |
| a30 | `pv_voltage_high_2` | PV2 voltage high |
| a31 | `mppt_overload_fault_2` | MPPT2 overload fault |
| a32 | `mppt_overload_warning_2` | MPPT2 overload warning |
| a33 | `battery_too_low_to_charge_2` | Battery too low to charge (PV2) |
| a34 | `unknown1` | unknown |
| a35 | `unknown2` | unknown |

