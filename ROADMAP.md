# MultiMacSim Roadmap

Each release adds one NI Multisim part group, plus the instruments and analyses that go with it, plus one round of physics/solver work.

| Version | Part group | Instruments / analyses | Physics focus |
|---|---|---|---|
| **v6** | **1. Sources** (three-phase, AM/FM, PWL, exponential, noise, current sources, CCVS/CCCS, ABM, control blocks, digital sources, supply rails) | Function generator upgrade, Frequency counter, AC Sweep + Bode plotter | Trapezoidal integration, source breakpoints, Newton convergence, accuracy tests |
| v7 | 2. Basic (SPDT/DPDT/push/time-delay/controlled switches, relays, transformers, coupled inductors, Z-load, variable L, rated parts) | DC Sweep, Parameter Sweep | Mutual inductance, ideal-switch stamping |
| v8 | 3. Diodes (photodiode, TVS, bridge rectifier, varactor, PIN, tunnel, SCR, DIAC, TRIAC) | IV Analyzer | Junction capacitance, thyristor latching |
| v9 | 4. Transistors (MOSFETs, JFETs, Darlingtons, IGBT, UJT, power MOS) | IV Analyzer curves, Temperature Sweep | Level-1 MOSFET, Ebers-Moll + Early effect |
| v10 | 5. Analog (real op-amps, comparator, instrumentation/diff amps, audio amp) | Four-channel oscilloscope, Distortion Analyzer | Op-amp saturation, slew rate, GBW |
| v11 | 6–7. TTL + CMOS digital (flip-flops, counters, mux, decoders, adders, tri-state) | Word Generator, Logic Analyzer, Logic Converter | Event-driven mixed-signal |
| v12 | 11. Mixed (555, monostable, PLL, ADC, DAC, analog switches) | Fourier analysis | Mixed analog/digital timing |
| v13 | 12. Indicators (7-segment, hex display, bar graph, buzzer, virtual lamp) | — | — |
| v14 | 13. Power (regulators, references, PWM controllers, drivers, buck/boost) | Current clamp | Averaged switch models |
| v15 | 14. Misc (crystal, optocoupler, vacuum tube, transmission lines, filters, motors) | Spectrum Analyzer, Noise analysis | Transmission-line delay |
| v16 | 16. Electro-Mechanical (sensing/timed contacts, coils, breakers, 3-phase motor) | — | Motor dynamics |
| v17 | 17. Ladder diagrams (PLC) | — | Scan-cycle logic |
| v18 | 8–10. MCU, Advanced Peripherals, Misc Digital (8051/PIC, LCD, keypad) | — | Instruction-level MCU |
| v19 | 15. RF | Network Analyzer | S-parameters |
| v20 | 18–20. NI components, Connectors, Hierarchy/bus | Monte Carlo, Worst Case, Sensitivity, Pole-Zero, Transfer Function, Noise Figure | — |
