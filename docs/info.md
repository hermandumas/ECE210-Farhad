<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

This design implements a single exponential integrate-and-fire (EIF) neuron.

- `ui_in[7:0]` is a signed 8-bit input current (`I_in`) in 2's complement.
- Internal membrane state `V` is a signed 12-bit register.
- On each neuron update tick, the model computes:
  - leak term (`V >> 5`)
  - exponential term from a 16-entry LUT based on `(V - V_T)`
  - Euler update `dV = I - leak + exp`
- If `V` crosses the spike threshold, the design emits a 1-cycle spike pulse and enters a refractory period where `V` is held at reset.

Control pins on `uio_in`:

- `uio_in[0]`: `run_en` (enable updates)
- `uio_in[1]`: `step_mode` (0 = periodic divider tick, 1 = external step pulses)
- `uio_in[2]`: `step_pulse` (rising edge triggers one update in step mode)
- `uio_in[7:5]`: `tick_scale` (sets periodic update divider in free-run mode)

Outputs:

- `uo_out[7]`: `spike_pulse`
- `uo_out[6:0]`: top 7 bits of membrane voltage display (`V_disp`)
- `uio_out = 0` and `uio_oe = 0` (UIO pins are input-only in this design)

## How to test

The included cocotb test is a smoke test that clocks, resets, and exercises both free-run and step-mode operation.

Run RTL simulation:

```sh
cd test
make -B
```

What the test does:

1. Starts clock and applies reset.
2. Enables free-run mode (`run_en=1`, `step_mode=0`) for multiple cycles.
3. Switches to step mode (`step_mode=1`) and applies several `step_pulse` edges.
4. Completes without strict numerical assertions, verifying the DUT runs through normal control paths.

Waveforms are written to `test/tb.fst` and can be inspected with GTKWave or Surfer.

## External hardware

None.
