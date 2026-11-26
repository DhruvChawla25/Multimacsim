# MULTIMACSIM.v1.1 ⚡️
### Native macOS Circuit Simulator — B.Tech Year 1 Electrical Engineering Edition

A high-performance, native macOS schematic capture and SPICE circuit simulation application built in **Swift 6** and **SwiftUI**.

Designed specifically to cover the entire curriculum of **B.Tech 1st Year Basic Electrical Engineering (BEE) & Network Analysis**.

---

## How to use

### Wiring things together

Every connection in the app is a real electrical net, and the app tries hard to make one for you.

- **Magnetic terminals.** While you drag a part, its terminals reach out and grab a nearby terminal (18 pt) or a wire that passes close by (10 pt). You will see the part settle into place, and the wire appears the moment you let go.
- **Drop-on-wire = T-junction.** Landing a terminal on top of an existing wire taps into it. The junction is drawn as a dot and both sides of the wire join the same node.
- **Auto-Connect Facing Pins** (`Shift+Cmd+A`, also in the left palette and the right inspector). Wires every pair of terminals on the same row or column that are already pointing at each other within 60 pt. Use it after dropping a row of parts to turn a sketch into a circuit in one keystroke.
- **Snap All to Grid.** Tidies every part onto the grid and re-checks every connection, so parts that were a pixel off line up and connect.
- **Manual wire.** Press `W`, then click a terminal dot and click the other one (or drag from one to the other). `Esc` abandons the draft.
- **Wires are drawn, never stored.** The path of a wire is recomputed from the live positions of the two terminals it joins, so dragging a part makes its wires follow. Routes leave each pin straight along its lead, turn only at right angles, and land on grid lines - which is what keeps a busy schematic readable instead of tangled.

An open terminal is drawn in orange, so "what is not connected yet" is always visible. The inspector lists every terminal of the selected part with the net it belongs to and tells you how far the nearest matching terminal is.

### Parts

84 parts in twelve palette sections, with a search box on top. The six source sections follow NI Multisim's **Sources** group (new in v6):

- **Measuring Instruments** - ammeter (in series), voltmeter (across), multimeter with a V / A / Ω mode switch, ohmmeter, wattmeter (current coil + pressure coil), galvanometer, **function generator** (sine / square / triangle, amplitude in Vp, duty cycle, DC offset), **frequency counter** (auto or manual trigger level, period, pulse width, duty, edge count) and **Bode plotter** (IN / OUT terminals).
- **Power Sources** - ground, digital ground, DC supply, **VCC / VDD / VEE / VSS rails** (every symbol of one rail is the same global net, as in Multisim), **three-phase wye** (A, B, C, N) and **three-phase delta** sources set by line voltage (V RMS), frequency and phase angle.
- **Signal Voltage Sources** - AC sine, clock (now with duty cycle, start delay, edge time), **AM**, **FM**, **exponential** (SPICE EXP), **piecewise linear** (editable point list, optional repeat), **pulse** (SPICE PULSE: V1, V2, delay, rise, fall, width, period), **bipolar** (±V square) and **white noise** (RMS, bandwidth, seed - reproducible).
- **Signal Current Sources** - DC, **AC**, **clock / pulse**, **exponential**, **FM** and **PWL** current. Current leaves the terminal the arrow points to.
- **Controlled Sources** - VCVS, VCCS, **CCVS** and **CCCS** (controlled by the current through a sense branch I+ → I-, exactly as SPICE does it), **ABM voltage** and **ABM current** (type an expression: `V(3)`, `V(R1)`, `V(a,b)`, `I(R1)`, `time`, `pi`, `+ - * / ^`, `sin cos tan exp log log10 abs sqrt min max limit` - a small safe parser, nothing is ever executed), **voltage-controlled sine / square / triangle oscillators** (f = f0 + gain × V(ctrl)).
- **Control Function Blocks** - multiplier, divider, gain, summer, integrator, differentiator, limiter, hysteresis (Schmitt), slew-rate limiter, polynomial and **s-domain transfer function** H(s) = N(s)/D(s). Ideal inputs, ideal output to ground.
- **Digital Sources** - digital clock, digital constant and **interactive digital constant** (click it on the canvas to flip 0 / 1), all driving the existing logic gates.
- **Passives & Loads**, **Semiconductors**, **Analog & Logic ICs** (op-amp, AND / OR / NOT / NAND / NOR / XOR / XNOR / buffer) and **Probes & Test** as before.

Every new part has a schematic symbol, inspector-editable settings (numbers, plus a validated text box for PWL points, expressions, polynomial coefficients and transfer functions) and a SPICE export line.

The palette also holds the wiring tools (Select / Wire / Auto-Connect Facing Pins / Snap All to Grid), a short "how parts connect" note, and the lab examples.

Live readings appear on the part itself while the simulation runs, and the inspector shows the voltage across, current through and power of the selected part.

### Lab examples (pre-wired)

The bottom of the left palette loads a complete, already-connected circuit: **Lab 1** AC Series RLC (130 V, 50 Hz: R 200 Ω, L 0.237 H, C 18 µF), and **Labs 2-4** the three cases of the AC parallel experiment (RL branch only, RC branch only, both branches - set by switches 3-4 and 5-6, with ammeters I, I1, I2 and a wattmeter; click a switch to change case live), and **Lab 5** the plain AC parallel RL ∥ RC circuit from the printout (R1 200 Ω + L 0.239 H, R2 200 Ω + C 18 µF). After the five lab sheets come the v6 examples: a **three-phase star load** (400 V, 50 Hz, line and neutral ammeters - balanced, the neutral reads 0 A), an **AM signal on the oscilloscope**, a **CCCS current mirror**, an **RC low-pass on the Bode plotter** and a **VCO read by the frequency counter**. **The app opens on Lab 1**; `Cmd+N` starts from blank.

### AC Analysis (`Shift+Cmd+Y`)

The **AC Analysis** toolbar button solves any linear R / L / C circuit with an AC source exactly, using phasors, so there is no start-up transient. It shows:

- **Component parameters & reactances**: each part's value, formula (X_L = ωL, X_C = 1/ωC) and impedance, plus the total impedance the source sees.
- **Electrical summary table**: peak, RMS and phase (relative to the source voltage) of the source current and of the current through and voltage across every part.
- **Power**: P, Q, S, power factor (leading or lagging), and the power in each resistor.
- **Waveforms**: two cycles of the source voltage, the source current and each resistor branch current. Click a legend entry to show or hide it.

On a circuit with an AC source, ammeters and voltmeters read **RMS** and the wattmeter reads **average power**, like real lab meters (they settle within about half a second at 50 Hz). Each oscilloscope channel can now plot the probed part's current (`I`) as well as its voltage (`V`), with scales from 10 m to 100 per division.

### Three-phase

The AC Analysis sheet reports every three-phase source phase by phase: line currents and angles, phase and line voltages, neutral current, unbalance (max / min line current) and P, Q, S - so balanced and unbalanced star and delta loads can be checked against the hand calculation.

### Bode plotter and AC sweep (`Shift+Cmd+B`)

The **Bode Plotter** button runs an AC sweep (SPICE `.AC DEC`): the circuit is solved as phasors at log-spaced frequencies with every AC source driven at the sweep frequency, after diodes, transistors and non-linear blocks are linearised at the DC operating point. It plots magnitude (dB) and unwrapped phase against log frequency with a hover cursor and the -3 dB point. Input and output default to a Bode plotter part's IN / OUT terminals (or the AC source and the last R / L / C) and can be any part voltage or node.

### Solver (v6)

- **Trapezoidal integration** for capacitors and inductors (second order, keeps LC energy over hundreds of cycles), with a backward-Euler step at start-up and after every source corner so it never rings. Backward Euler stays selectable in the inspector's Solver section for comparison. Inductors carry their current as an MNA unknown.
- **Source breakpoints**: every step splits itself at pulse / clock / PWL / exponential corners and predicted VCO edges, so edges land at their true time whatever the step size.
- **Newton-Raphson** with SPICE tolerances (reltol 1e-3, vntol 1e-6, abstol 1e-12), pnjlim junction voltage limiting, gmin across junctions, warm starts, time-step cutting on failure, and a DC operating point (`.OP`) that falls back to gmin stepping and then source stepping.
- **Optional adaptive time step**: the trapezoidal local truncation error (h³/12·|x‴|) decides how finely each frame step is subdivided (inspector switch; off by default to keep the live view cheap).

### Changing values

Select any part and edit its numbers in the right-hand inspector. Every number has the same four controls:

- **Type it** with engineering units: `4.7k`, `4k7`, `100u`, `2.2nF`, `10MEG`, `1kHz`, `-12`. Press Return or click away to apply. Bad input turns the box red and the circuit keeps its old value. `M` means mega and `m` means milli.
- **Arrows** step to the next or previous standard E12 value (1.0, 1.2, 1.5 ... 8.2) for R, C, L and frequency; voltages move in 1-2-5 steps.
- **Slider** sweeps the value live (logarithmic for R, C, L and frequency) so you can watch a circuit respond while it runs.
- **`[` and `]`** step the selected part's main value from the keyboard.

Values are clamped to sensible limits (resistance can't go negative; a DC supply can be reversed with a negative voltage). AC sources warn when the frequency is too high for the solver's time step to draw properly.

### Files

- **Printable PNGs.** `/Applications/MultiSim --export-png ~/Desktop/"MultiSim Circuits"` renders every lab circuit to a print-ready PNG (white background, no grid, about 300 dpi, title and parts list, meters showing their expected AC readings) and quits without opening a window.

- **New / Open / Save** (toolbar, or `Cmd+N` / `Cmd+O` / `Cmd+S` / `Shift+Cmd+S`). Circuits are saved as `.msim` files. **SPICE** in the toolbar writes an ngspice/LTspice-compatible `.cir` netlist, including the instrument models.

## Keyboard Shortcuts

- `W`: Toggle Wire Mode
- `Shift+Cmd+A`: Auto-Connect Facing Pins
- `Space`: Run / Pause Simulation
- `R`: Rotate Selected Component 90°
- `Backspace` / `Delete`: Delete Selected Component or Wire
- `Esc`: Cancel Active Wire Drafting

---

## How to Run MULTIMACSIM.v1.1

The fastest way is the installed binary: **`/Applications/MultiSim`** - double-click it, or

```bash
open /Applications/MultiSim
```

To run straight from this folder:
```bash
cd ~/Projects/MultiSim/multisim.v.4
swift run
```
Or open in Xcode:
```bash
open ~/Projects/MultiSim/multisim.v.4/Package.swift
```
*(Press `Cmd + R` in Xcode)*

After changing code, refresh the installed binary with:
```bash
swift build -c release && cp .build/release/MultiSim /Applications/MultiSim
```

## Versions

This folder is **v4**, the merge of the two older MultiSim folders (their code, plus the design PDFs). Frozen earlier versions are zipped in `~/Projects/MultiSim/all the old versions/` - see `VERSIONS.txt` there for what each one contains and when it was taken.

## Tests

```bash
swift test
```

145 engine tests: value editing (unit parser, E12 stepping, limits, live edits), MNA solver correctness, wiring geometry, instrument behaviour, AC phasor analysis checked against the worked lab sheets, and for v6: every new source, controlled source, control block and digital source; the expression, PWL and transfer-function parsers; three-phase balanced / unbalanced / delta loads; frequency counter and AC sweep; the example circuits; and accuracy against closed-form answers (RC charge, RL rise, LC energy over 100 cycles, series RLC transient vs phasor sample by sample, neutral current of a balanced star load, Newton fallbacks, adaptive stepping).
