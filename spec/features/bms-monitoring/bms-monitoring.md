## BMS monitoring

* depends on the [local collector](../monitoring/local-collector.md) and sends the measurements to it
* [protocol docs](./protocol.md)
* starts at boot
* a systemd unit that gets restarted 15 minutes after exit (failure or success)
* all incoming communication needs to check the CRC and discard the message on failure
* every failure exits the unit, systemd will restart it

### Locking the USB

* after open(), use flock()
* if it is locked already => skip the device on discovery

### Finding the USB device

* it reads all devices in /dev/ttyUSB
* evaluates the available USBs in random order
* for each device:
    * listens to it for 10 seconds => if there is no data => skip
    * sets the serial parameters
* if no suitable USB found => exits and let systemd restart it

### Continuous monitoring

* only passive monitoring, never sending data, only listening
* when it's time to make a measurement it listens for the next suitable frame

### Measurements

* the metrics are in the `bms` namespace, so each measurement is `bms.<name>` and sub measurements are `bms.<name>.<sub>`
* all fields can be missing if the value can not be collected
* values are emitted as scaled numbers in natural units, not raw frame integers (§4 divisors applied)

* resource attributes:
    * service.name: "bms-monitoring"
    * host.name / boot_id
    * bms.device: the /dev/serial/by-path/ path
* scope attributes:
    * name: "bms-monitoring"
    * version: crate version

#### bms.settings

* emitted once right after the device is found, then every 24 hours

* body:
    * cell_count, cell_capacity_ah
    * cell_undervoltage_volts, cell_undervoltage_recovery_volts
    * cell_overvoltage_volts, cell_overvoltage_recovery_volts
    * cell_request_charge_volts, cell_request_float_volts
    * soc_100_percent_volts, soc_0_percent_volts, system_power_off_volts
    * balance_trigger_delta_volts, balance_start_voltage_volts,
        balance_current_max_amps, balancing_enabled
    * charge_enabled, discharge_enabled
    * charge_overcurrent_amps, charge_overcurrent_delay_seconds,
        charge_overcurrent_release_seconds
    * discharge_overcurrent_amps, discharge_overcurrent_delay_seconds,
        discharge_overcurrent_release_seconds
    * short_circuit_delay_micros, short_circuit_release_delay_seconds
    * charge_over_temp_celsius, charge_over_temp_recovery_celsius
    * discharge_over_temp_celsius, discharge_over_temp_recovery_celsius
    * charge_under_temp_celsius, charge_under_temp_recovery_celsius
    * mos_over_temp_celsius, mos_over_temp_recovery_celsius
    * smart_sleep_volts, smart_sleep_hours
    * precharge_seconds, current_range_amps, device_address, switch_status_raw

* sub measurements:
    * cell: one per configured cell
        * attributes:
            * cell: 1-based index
        * body:
              * connection_resistance_ohms   (configured, cellConWireRes)

#### bms.status

* measures every 1 minute
* body:
    * pack_voltage_volts, pack_current_amps (signed, − = discharge), pack_power_watts
    * soc_percent, soh_percent
    * remaining_capacity_ah, full_charge_capacity_ah, cycle_capacity_ah, cycle_count
    * cell_voltage_average_volts, cell_voltage_delta_volts,
        cell_voltage_min_volts, cell_voltage_max_volts,
        cell_min_index, cell_max_index, cells_present
    * mos_temperature_celsius, temperature_1_celsius … temperature_5_celsius
        (omitted for sensors flagged absent by tempSensorAbsent)
    * balance_current_amps, balancing
    * charge_mosfet_on, discharge_mosfet_on, heating_on
    * alarms_raw, alarms_asserted_count, alarms2_raw
    * bms_uptime_seconds
    * protection_release_{discharge_oc,discharge_sc,charge_oc,charge_sc,uv,ov}_seconds
    * link_connected_seconds, link_frames_ok, link_frames_discarded, link_frame_wait_seconds

* sub measurements:
    * cell: one per present cell
        * attributes:
            * cell: 1-based index (matches cell_min_index / cell_max_index)
        * body:
            * voltage_volts
            * wire_resistance_ohms   (measured, cellWireRes)
    * alarm: one per asserted bit, emitted only when set — normally zero records
        * attributes:
            * bit: `b12` for sysAlarm, `u2b3` for userAlarm2
            * flag: the normative name from §6.1
        * body:
              * asserted: true
