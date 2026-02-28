# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


def control_word(run=0, step_mode=0, step_in=0, tick_scale=0):
    return (
        ((tick_scale & 0x7) << 5)
        | ((step_in & 0x1) << 2)
        | ((step_mode & 0x1) << 1)
        | (run & 0x1)
    )


@cocotb.test()
async def test_project(dut):
    # 100 kHz clock
    clock = Clock(dut.clk, 10, units="us")
    cocotb.start_soon(clock.start())

    # Reset
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = control_word()
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)

    # Free-run mode for a while.
    dut.ui_in.value = 64
    dut.uio_in.value = control_word(run=1, step_mode=0, tick_scale=0)
    await ClockCycles(dut.clk, 300)

    # Step mode for a while.
    dut.uio_in.value = control_word(run=1, step_mode=1, step_in=0)
    await ClockCycles(dut.clk, 2)
    for _ in range(8):
        dut.uio_in.value = control_word(run=1, step_mode=1, step_in=1)
        await ClockCycles(dut.clk, 1)
        dut.uio_in.value = control_word(run=1, step_mode=1, step_in=0)
        await ClockCycles(dut.clk, 1)

    # Finish after a few additional cycles.
    await ClockCycles(dut.clk, 10)
