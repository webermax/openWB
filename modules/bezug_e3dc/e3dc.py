#!/usr/bin/python
from pymodbus.constants import Endian
import logging
import math
from typing import List

from helpermodules.cli import run_using_positional_cli_args
from helpermodules.log import setup_logging_stdout
from modules.common.component_state import CounterState
from modules.common.modbus import ModbusClient, ModbusDataType
from modules.common.store import get_counter_value_store

log = logging.getLogger("E3DC EVU")

def update(ipaddress: str):
    log.debug("Beginning update")
    client = ModbusClient(ipaddress, port=502)
#40074 EVU Punkt negativ -> Einspeisung in Watt
    power_all = client.read_holding_registers(40073, ModbusDataType.INT_32, wordorder=Endian.Little, unit=1)
#40130 Phasenleistung in Watt
    powers = client.read_holding_registers(40129, [ModbusDataType.INT_16] * 3, unit=1)
    currents = [0]*3
    voltages = [230]*3
    for i in range(0, 3):
        if powers[i] > 0:
            currents[i]=powers[i]/voltages[i]
    get_counter_value_store(1).set(CounterState(
        power_all=power_all,
        powers=powers,
        voltages=voltages,
        currents=currents
    ))
    log.debug("Update completed successfully")

if __name__ == '__main__':
    setup_logging_stdout()
    run_using_positional_cli_args(update)
