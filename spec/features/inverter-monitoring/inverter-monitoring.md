## Inverter monitoring

* depends on the [local collector](../monitoring/local-collector.md) and sends the measurements to it
* [protocol docs](./protocol.md)
* starts at boot
* a systemd unit that gets restarted 15 minutes after exit (failure or success)
* all incoming communication needs to check the CRC and discard the message on failure
* every failure exits the unit, systemd will restart it

### Finding the USB device

* it reads all devices in /dev/ttyUSB
* evaluates the available USBs in random order
    * start with a device that it last connected to (written in a file)
    * this uses the /dev/serial/by-id/ path for identification
* for each device:
    * listens to it for 10 seconds => if there is data coming without asking then it's the BMS => skip
    * sets the serial parameters
    * writes `QID` command and listens for a response with a small timeout => if valid response then found the USB
* if no suitable USB found => exits and let systemd restart it

### Static data

* first thing after finding the USB is to read the static data
* queries `QID`, `QVFW`, `QVFW3`, `QMN`, `QGMN`
* refresh these data once every hour

### Continuous monitoring

* queries `QMOD`, `QPIGS`, `QPIGS2`, `QPIWS`
* collects every minute

### Measurements

* the metrics are in the `inverter` namespace, so each measurement is `inverter.<name>` and sub measurements are `inverter.<name>.<sub>`
* all fields can be missing if the value can not be collected
* values are emitted as scaled numbers in natural units, not as the raw ASCII fields (`54.20` => `54.2` volts, field 18's 10 mV steps => volts); version fields stay opaque strings

* resource attributes:
    * service.name: "inverter-monitoring"
    * host.name / boot_id
    * inverter.serial_number: `QID`
    * inverter.model: `QMN`
    * inverter.model_code: `QGMN`
    * inverter.firmware: `QVFW`
    * inverter.firmware_panel: `QVFW3`
    * inverter.device: the /dev/serial/by-id/ path
* scope attributes:
    * name: "inverter-monitoring"
    * version: crate version

#### status

* one record per poll cycle

* body:
    * mode_code, mode
    * grid_voltage_volts, grid_frequency_hz
    * output_voltage_volts, output_frequency_hz, output_apparent_power_va,
        output_active_power_watts, output_load_percent
    * battery_voltage_volts, battery_capacity_percent, battery_charging_current_amps,
        battery_discharge_current_amps, battery_voltage_from_scc1_volts,
        battery_voltage_offset_fans_on_volts
    * pv1_current_amps, pv1_voltage_volts, pv1_charging_power_watts
    * pv2_current_amps, pv2_voltage_volts, pv2_charging_power_watts
    * bus_voltage_volts, heat_sink_temperature_celsius, eeprom_version
    * load_on, charging, charging_scc, charging_ac, float_charge, switch_on,
        configuration_changed, scc_firmware_updated, add_sbu_priority_version,
        battery_voltage_to_steady_while_charging
    * warnings_raw, warnings_asserted_count, inverter_fault
    * link_connected_seconds, link_discarded_frames, link_unsupported_commands

#### status.flag

one per asserted `QPIWS` bit, emitted only when the bit is set — normally zero records

* attributes:
    * bit: `aN`
    * flag: the normative name from the protocol doc
* body:
    * asserted: true

