# JK BMS wired (UART) protocol

Complete, self-contained spec for reading this BMS over its **serial cable**. This is the
JK/Jikong "modern" protocol (`55 AA EB 90` frames, integer-encoding `JK-BXAXS-XP` profile).

## 1. Transport
| | |
|---|---|
| Baud | **115200** |
| Framing | **8N1** (8 data bits, no parity, 1 stop bit) |
| Flow control | none |
| Direction | **BMS → host only** — the BMS auto-pushes; the host sends nothing |
| Throughput | bursty, ~127 B/s average; line idle between bursts |
| Endianness | **little-endian** for all multi-byte integers |

There is **no handshake, no MTU exchange, no `AT` chatter, and no start command**. Open the
port and read.

**Use raw mode — this is not optional.** The payload is binary and contains bytes a
cooked line-discipline will corrupt: `0x0d`/`0x0a` (CR/LF — 60/40 occurrences in a 10-cycle
capture) get NL/CR-translated, and `0x11`/`0x13` (XON/XOFF) occur in current/temperature
fields and get eaten by software flow control. Open the port raw with software **and**
hardware flow control **and** NL/CR translation disabled:

```
stty -F /dev/ttyUSB0 115200 cs8 -cstopb -parenb raw -echo -ixon -ixoff -icrnl -crtscts
```

## 2. What the BMS emits — the cycle
The stream repeats a fixed cycle roughly **every ~6 s** (measured: 5 cycles per 30 s capture;
one cycle = **781 bytes**):

```
[ 0x02 realtime frame   300 B ]   ← main telemetry (§6)
[ 1 short Modbus record   8 B ]
[ 0x01 settings frame    300 B ]   ← settings snapshot (§7)
[ ~16 short Modbus records 173 B ] ← auxiliary RS485 poll (§8) — ignore
… repeat …
```

Only `0x02` and `0x01` frames are auto-emitted. **`0x03` device-info is NOT sent** on the
wire (it would require a request, which we never send). For monitoring you only need `0x02`.

## 3. Frame format (`55 AA EB 90`)
```
off  size field
 0    4   header    = 55 AA EB 90
 4    1   frameCode = 0x02 realtime | 0x01 settings
 5    1   counter   = 0x00 on the wire (always)
 6  293   data      (record body — §6 / §7)
299   1   checksum  = sum(bytes 0..298) & 0xFF        ("sum8", 8-bit sum)
```
- Fixed **300 bytes** per frame.
- **Checksum = `sum8`**: add bytes 0..298 mod 256; it must equal byte 299. Verified on every
  captured `0x02` and `0x01` frame.
- The `counter` byte (offset 5) is **always `0x00`** on the cable, so you can match the full
  6-byte prefix `55 AA EB 90 02 00` (realtime) / `55 AA EB 90 01 00` (settings).

## 4. Scaling rule (verified on hardware — important)
Raw integers are fixed-point. The divisor depends on the **quantity**:

| Quantity | Divisor |
|---|---|
| Voltage (V), Current (A), Power (W), Capacity (Ah) | **÷ 1000** |
| Temperature (°C) | **÷ 10** |
| SOC, SOH (%), cycle count, seconds, indices, bitmaps | **as-is** |

## 5. Endian / type primitives
- `u8` / `i8`: 1 byte. `u16` / `i16`: 2 bytes LE. `u32` / `i32`: 4 bytes LE.
- Signed types are two's-complement (current and temperatures can go negative).
- Bitmaps are read LSB-first per byte.

## 6. Real-time frame `0x02` — field layout
Offsets are absolute in the 300-byte frame. This model populates **cells 1–16** (slots
17–32 read 0). Apply the §4 divisor.

| offset | size | field | type | unit | notes |
|-------:|-----:|-------|------|------|-------|
| 6   | 64 | cellVol[32]      | u16×32 | V | ÷1000; cells 1–16 used |
| 70  | 4  | cellStatus       | bitmap32 | | per-cell present/valid |
| 74  | 2  | cellVolAve       | u16 | V | ÷1000 |
| 76  | 2  | maxVoltDelta     | u16 | V | ÷1000 (max−min); BMS's own aggregate — may disagree with cellVol[] |
| 78  | 1  | celMaxVol        | u8 | | **0-based** index of highest cell; BMS-sampled — may not match cellVol[] argmax |
| 79  | 1  | celMinVol        | u8 | | **0-based** index of lowest cell; BMS-sampled — may not match cellVol[] argmin |
| 80  | 64 | cellWireRes[32]  | u16×32 | Ω | ÷1000 |
| 144 | 2  | tempMos          | i16 | °C | ÷10 |
| 146 | 4  | cellWireResStat  | bitmap32 | | |
| 150 | 4  | **batVol**       | i32 | V | ÷1000 (pack voltage) |
| 154 | 4  | batWatt          | u32 | W | ÷1000; **unsigned magnitude** — no sign here. Take direction from batCurrent, e.g. `copysign(batWatt, batCurrent)` (charge-direction sign unverified) |
| 158 | 4  | **batCurrent**   | i32 | A | ÷1000, signed (− under discharge) |
| 162 | 2  | batTemp1         | i16 | °C | ÷10 |
| 164 | 2  | batTemp2         | i16 | °C | ÷10 |
| 166 | 4  | sysAlarm         | bitmap32 | | alarm flags (see §6.1) |
| 170 | 2  | equCurrent       | i16 | A | ÷1000 (balance current) |
| 172 | 1  | equStatus        | u8/flags | | balancing state |
| 173 | 1  | **SOC**          | u8 | % | as-is |
| 174 | 4  | socCapabilityRemain   | u32 | Ah | ÷1000 |
| 178 | 4  | socFullChargeCapacity | u32 | Ah | ÷1000 |
| 182 | 4  | socCycleCount    | u32 | | as-is |
| 186 | 4  | socCycleCapacity | u32 | Ah | ÷1000 |
| 190 | 1  | SOH              | u8 | % | as-is |
| 194 | 4  | runtime          | u32 | s | as-is |
| 198 | 1  | chargeStatus     | u8 | | charge MOSFET on/off |
| 199 | 1  | dischargeStatus  | u8 | | discharge MOSFET on/off |
| 200 | 2  | userAlarm2       | bitmap16 | | |
| 202–212 | 2 ea | timeDcOCPR, timeDcSCPR, timeCOCPR, timeCSCPR, timeUVPR, timeOVPR | u16 | | protection-release countdowns |
| 214 | 1  | (reserved)       | u8 | | observed constant **0xFF** with sensors live — **NOT** a usable present/absent map; do not gate temperatures on it |
| 215 | 1  | heatingStatus    | u8 | | |
| 234 | 2  | totalBatVol      | u16 | V | ÷100 (secondary/legacy pack-V; verified **5202→52.02 V** = batVol). Offset is **234**, not 233 |
| 252 | 2  | batTemp3         | i16 | °C | ÷10; **reads 0** on this unit (sensor 3 not populated) |
| 254 | 2  | batTemp4         | i16 | °C | ÷10; **byte-identical to tempMos@144** in all frames — a mirror, not a distinct sensor |
| 256 | 2  | batTemp5(?)      | i16 | °C | ÷10 (~36.9 °C) but **held constant** through capture — unconfirmed |
| 285 | 12 | enableFlags      | bytes | | per-field enable bitmap |

Only **tempMos@144, batTemp1@162, batTemp2@164** are confirmed-live temperature sensors on
this unit. `celMaxVol`/`celMinVol`/`maxVoltDelta` come from a separate BMS sample and are not
guaranteed to match `cellVol[]` in the same frame — **compute your own aggregates** from
`cellVol[]` if you need internal consistency.

Bytes not listed are reserved / firmware-internal — not needed for monitoring. Known
live-but-unused ones (measured, listed so they aren't re-discovered): `@224` u8 (~21, noisy),
`@226` f32 (≈2.97, constant), `@246` u16 (+~68/frame ≈ a 10 Hz tick), `@258` i16 (≈37 °C,
unconfirmed), `@262` u16 (+~7/frame ≈ 1 Hz power-on seconds, ≈10.3 h — distinct from `runtime`).

### 6.1 `sysAlarm` bitmap (offset 166, 32 bits, LSB first)
`0` balancing-wire-resistance-high · `1` MOS-over-temp · `2` cell-count-mismatch ·
`3` current-sensor-abnormal · `4` cell-overvoltage · `5` pack-overvoltage ·
`6` charge-overcurrent · `7` charge-short-circuit · `8` charge-over-temp ·
`9` charge-low-temp · `10` internal-comms-abnormal · `11` cell-undervoltage ·
`12` pack-undervoltage · `13` discharge-overcurrent · `14` discharge-short-circuit ·
`15` discharge-over-temp · `16` charge-anomaly · `17` discharge-anomaly ·
`18` GPS-disconnected · `19` change-authorization-password · `20` discharge-on-failure ·
`21` battery-over-temp · `22` temp-sensor-anomaly · `23` parallel-module-failure ·
`24–31` reserved/unknown.

## 7. Settings frame `0x01` — field layout
Also a 300-byte `sum8` frame (verified on the wire). Layout decoded from the device ICD;
apply the §4 divisor by unit. Offsets from frame start. **Read-only use** — this doc never
writes.

| offset | field | type | unit |
|-------:|-------|------|------|
| 6   | volSmartSleep | u32 | V |
| 10  | volCellUV / volCellUVPR | u32 | V (recovery at 14) |
| 18  | volCellOV / volCellOVPR | u32 | V (recovery at 22) |
| 26  | volBalanTrig | u32 | V |
| 30  | volSOCP100 / volSOCP0 | u32 | V (34) |
| 38  | volCellRCV / volCellRFV | u32 | V (42) |
| 46  | volSysPwrOff | u32 | V |
| 50  | timBatCOC (charge OC current) / delay / release-delay | u32 | A / s / s (54, 58) |
| 62  | timBatDcOC (discharge OC current) / delay / release-delay | u32 | A / s / s (66, 70) |
| 74  | timBatSCPRDly | u32 | s |
| 78  | curBalanMax | u32 | A |
| 82  | tmpBatCOT/PR, tmpBatDcOT/PR, tmpBatCUT/PR, tmpMosOT/PR | i32×8 | °C |
| 114 | cellCount | u32 | |
| 118 | batChargeEn / batDischargeEn / balanEn | u32×3 | bool |
| 130 | capBatCell | u32 | Ah |
| 134 | scpDelay | u32 | µs |
| 138 | volStartBalan | u32 | V |
| 142 | cellConWireRes[32] | u32×32 | mΩ — **reads all-zero** on this unit; use realtime cellWireRes@80 for actual values |
| 270 | devAddr | u32 | |
| 274 | dischrgPreChrgT | u32 | s |
| 278 | currentRange | u32 | **A ÷10000** (exception to §4: raw 1500000 → 150 A, matching the 150 A discharge OCP) |
| 282 | switchStatus | bitmap16 | |
| 284 | timeSmartSleep | u8 | h |

> **Scaling inside the current/delay rows (offsets 50 & 62):** the current sub-field
> (`timBatCOC`/`timBatDcOC`) is ÷1000 (verified: 100000→100 A, 150000→150 A); the **delay and
> release sub-fields are raw integer seconds — NOT ÷1000** (measured: charge-OC delay 3 s /
> release 60 s, discharge-OC delay 300 s / release 60 s, SCP release 5 s). Whether the *delay*
> values are as-is or ÷10 (300→30 s) is unconfirmed without the JK app.

## 8. Auxiliary Modbus records (ignore for telemetry)
Between the big frames the BMS emits short **Modbus-RTU** frames — its RS485 host/inverter
poll, multiplexed onto the same line. Not needed for monitoring; skip anything that isn't a
`55 AA EB 90` frame.

Structure (verified):
```
ADDR(1)  FUNC=0x10  REG(2, big-endian)  QTY(2, BE)  [BYTECOUNT(1) DATA(2)]  CRC16(2, LE)
```
- **CRC = CRC16/MODBUS** (poly `0xA001` reflected, init `0xFFFF`), little-endian, computed
  over all bytes incl. `ADDR`. Verified on every record.
- `ADDR` increments `0x00 → 0x0f` across the ~16 records per cycle (a poll of addresses 0–15).
- `FUNC = 0x10` (write-multiple-registers), `REG ≈ 0x1620`/`0x161e`, value `0x0000`.
- Two lengths seen: 8-byte (`ADDR 10 16 20 00 01 <crc>`) and 11-byte
  (`ADDR 10 16 20 00 01 02 00 00 <crc>`).
- Examples (CRC-valid): `01 10 16 20 00 01 02 00 00 d6 f1`, `00 10 16 20 00 01 05 9a`.


