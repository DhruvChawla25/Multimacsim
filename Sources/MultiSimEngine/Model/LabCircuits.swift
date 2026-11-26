import Foundation

/// Ready-made lab circuits that both the app and the tests build from.
public enum LabCircuits {
    /// 130 V RMS supply, entered as the peak value the AC source expects.
    public static let sourcePeak = 130.0 * 2.0.squareRoot()

    /// Experiment 3, single-phase AC parallel circuit (130 V, 50 Hz), wired like the lab bench:
    /// supply -> switch 1-2 -> ammeter I -> wattmeter current coil -> two branches.
    /// Branch 1: switch 3-4 -> ammeter I1 -> R1 200 Ω -> choke L 0.239 H.
    /// Branch 2: switch 5-6 -> ammeter I2 -> R2 200 Ω -> C 18 µF.
    /// The wattmeter pressure coil sits across the branches, so it reads the power drawn.
    public static func acParallelBench(rlClosed: Bool, rcClosed: Bool) -> Circuit {
        let vs = CircuitComponent(kind: .acVoltageSource, designator: "Vs", position: Point2D(x: 120, y: 300), value: sourcePeak, secondaryValue: 50.0)
        let s12 = CircuitComponent(kind: .switchSPST, designator: "S1-2", position: Point2D(x: 220, y: 160), stateBool: true)
        let aI = CircuitComponent(kind: .ammeter, designator: "I", position: Point2D(x: 340, y: 160))
        let wm = CircuitComponent(kind: .wattmeter, designator: "W", position: Point2D(x: 460, y: 160), value: 0.05, secondaryValue: 1e6)

        let s34 = CircuitComponent(kind: .switchSPST, designator: "S3-4", position: Point2D(x: 600, y: 260), stateBool: rlClosed)
        let aI1 = CircuitComponent(kind: .ammeter, designator: "I1", position: Point2D(x: 720, y: 260))
        let r1 = CircuitComponent(kind: .resistor, designator: "R1", position: Point2D(x: 840, y: 260), value: 200.0)
        let l1 = CircuitComponent(kind: .inductor, designator: "L", position: Point2D(x: 960, y: 260), value: 0.239)

        let s56 = CircuitComponent(kind: .switchSPST, designator: "S5-6", position: Point2D(x: 600, y: 400), stateBool: rcClosed)
        let aI2 = CircuitComponent(kind: .ammeter, designator: "I2", position: Point2D(x: 720, y: 400))
        let r2 = CircuitComponent(kind: .resistor, designator: "R2", position: Point2D(x: 840, y: 400), value: 200.0)
        let c1 = CircuitComponent(kind: .capacitor, designator: "C", position: Point2D(x: 960, y: 400), value: 18e-6)

        let gnd = CircuitComponent(kind: .ground, designator: "GND", position: Point2D(x: 1080, y: 500))

        let wires = [
            Wire(startPinId: vs.pins[0].id, endPinId: s12.pins[0].id),
            Wire(startPinId: s12.pins[1].id, endPinId: aI.pins[0].id),
            Wire(startPinId: aI.pins[1].id, endPinId: wm.pins[0].id),
            // Branch node: current-coil output, pressure-coil + and both branch switches.
            Wire(startPinId: wm.pins[1].id, endPinId: wm.pins[2].id),
            Wire(startPinId: wm.pins[1].id, endPinId: s34.pins[0].id),
            Wire(startPinId: wm.pins[1].id, endPinId: s56.pins[0].id),
            Wire(startPinId: s34.pins[1].id, endPinId: aI1.pins[0].id),
            Wire(startPinId: aI1.pins[1].id, endPinId: r1.pins[0].id),
            Wire(startPinId: r1.pins[1].id, endPinId: l1.pins[0].id),
            Wire(startPinId: s56.pins[1].id, endPinId: aI2.pins[0].id),
            Wire(startPinId: aI2.pins[1].id, endPinId: r2.pins[0].id),
            Wire(startPinId: r2.pins[1].id, endPinId: c1.pins[0].id),
            Wire(startPinId: l1.pins[1].id, endPinId: gnd.pins[0].id),
            Wire(startPinId: c1.pins[1].id, endPinId: gnd.pins[0].id),
            Wire(startPinId: wm.pins[3].id, endPinId: gnd.pins[0].id),
            Wire(startPinId: vs.pins[1].id, endPinId: gnd.pins[0].id),
        ]
        return Circuit(components: [vs, s12, aI, wm, s34, aI1, r1, l1, s56, aI2, r2, c1, gnd], wires: wires)
    }

    // MARK: - v6 source examples

    private static func link(_ a: Pin, _ b: Pin) -> Wire { Wire(startPinId: a.id, endPinId: b.id) }

    /// 400 V / 50 Hz wye source into a balanced star load (100 Ω + 0.1 H per phase), a line ammeter in
    /// every phase and an ammeter in the neutral. Balanced, the neutral carries ~0 A; change one R to see it rise.
    public static func threePhaseStarLoad() -> Circuit {
        let src = CircuitComponent(kind: .threePhaseWye, designator: "V3P", position: Point2D(x: 160, y: 260), value: 400, secondaryValue: 50)
        var parts: [CircuitComponent] = [src]
        var wires: [Wire] = []
        var inductors: [CircuitComponent] = []
        for (i, ph) in ["A", "B", "C"].enumerated() {
            let y = 140.0 + Double(i) * 120
            let am = CircuitComponent(kind: .ammeter, designator: "I\(ph)", position: Point2D(x: 300, y: y))
            let r = CircuitComponent(kind: .resistor, designator: "R\(ph)", position: Point2D(x: 420, y: y), value: 100)
            let l = CircuitComponent(kind: .inductor, designator: "L\(ph)", position: Point2D(x: 540, y: y), value: 0.1)
            wires += [link(src.pins[i], am.pins[0]), link(am.pins[1], r.pins[0]), link(r.pins[1], l.pins[0])]
            parts += [am, r, l]
            inductors.append(l)
        }
        // Star point: the three inductor ends, then back to N through the neutral ammeter.
        let neutral = CircuitComponent(kind: .ammeter, designator: "IN", position: Point2D(x: 420, y: 500))
        let gnd = CircuitComponent(kind: .ground, designator: "GND", position: Point2D(x: 100, y: 560))
        wires += [link(inductors[0].pins[1], inductors[1].pins[1]), link(inductors[2].pins[1], inductors[1].pins[1]),
                  link(inductors[2].pins[1], neutral.pins[1]), link(neutral.pins[0], src.pins[3]), link(src.pins[3], gnd.pins[0])]
        return Circuit(components: parts + [neutral, gnd], wires: wires)
    }

    /// AM signal (2 V carrier at 500 Hz, m = 0.5 at 50 Hz) into a 1 kΩ load, ready for the oscilloscope.
    public static func amSignal() -> Circuit {
        let am = CircuitComponent(kind: .amVoltage, designator: "VAM", position: Point2D(x: 160, y: 260), value: 2, secondaryValue: 500,
                                  parameters: ["modIndex": 0.5, "modFreq": 50])
        let r = CircuitComponent(kind: .resistor, designator: "RL", position: Point2D(x: 320, y: 260), rotation: 90, value: 1000)
        let gnd = CircuitComponent(kind: .ground, designator: "GND", position: Point2D(x: 240, y: 380))
        return Circuit(components: [am, r, gnd], wires: [
            link(am.pins[0], r.pins[0]), link(r.pins[1], gnd.pins[0]), link(am.pins[1], gnd.pins[0]),
        ])
    }

    /// Current mirror from a CCCS (β = 1): the 5 mA set by Vref and Rref is copied into any load.
    public static func cccsCurrentMirror() -> Circuit {
        let v = CircuitComponent(kind: .dcVoltageSource, designator: "Vref", position: Point2D(x: 120, y: 280), value: 5)
        let iref = CircuitComponent(kind: .ammeter, designator: "Iref", position: Point2D(x: 240, y: 180))
        let rref = CircuitComponent(kind: .resistor, designator: "Rref", position: Point2D(x: 360, y: 180), value: 1000)
        let f = CircuitComponent(kind: .cccs, designator: "F1", position: Point2D(x: 500, y: 280), value: 1)
        let iout = CircuitComponent(kind: .ammeter, designator: "Iout", position: Point2D(x: 640, y: 180))
        let rl = CircuitComponent(kind: .resistor, designator: "RL", position: Point2D(x: 760, y: 280), rotation: 90, value: 2200)
        let gnd = CircuitComponent(kind: .ground, designator: "GND", position: Point2D(x: 500, y: 420))
        return Circuit(components: [v, iref, rref, f, iout, rl, gnd], wires: [
            link(v.pins[0], iref.pins[0]), link(iref.pins[1], rref.pins[0]), link(rref.pins[1], f.pins[2]),
            link(f.pins[3], gnd.pins[0]), link(v.pins[1], gnd.pins[0]),
            link(f.pins[0], iout.pins[0]), link(iout.pins[1], rl.pins[0]), link(rl.pins[1], gnd.pins[0]), link(f.pins[1], gnd.pins[0]),
        ])
    }

    /// RC low-pass (1 kΩ, 100 nF, f_c ≈ 1.59 kHz) with a Bode plotter across input and output.
    public static func bodeLowPass() -> Circuit {
        let v = CircuitComponent(kind: .acVoltageSource, designator: "Vin", position: Point2D(x: 140, y: 280), value: 1, secondaryValue: 1000)
        let r = CircuitComponent(kind: .resistor, designator: "R1", position: Point2D(x: 280, y: 180), value: 1000)
        let c = CircuitComponent(kind: .capacitor, designator: "C1", position: Point2D(x: 400, y: 280), rotation: 90, value: 100e-9)
        let bp = CircuitComponent(kind: .bodePlotter, designator: "XBP1", position: Point2D(x: 560, y: 280))
        let gnd = CircuitComponent(kind: .ground, designator: "GND", position: Point2D(x: 300, y: 420))
        return Circuit(components: [v, r, c, bp, gnd], wires: [
            link(v.pins[0], r.pins[0]), link(r.pins[1], c.pins[0]), link(c.pins[1], gnd.pins[0]), link(v.pins[1], gnd.pins[0]),
            link(bp.pins[0], v.pins[0]), link(bp.pins[1], gnd.pins[0]), link(bp.pins[2], c.pins[0]), link(bp.pins[3], gnd.pins[0]),
        ])
    }

    /// A sine VCO (200 Hz + 100 Hz/V) tuned by a DC control voltage, read by the frequency counter.
    public static func vcoWithCounter() -> Circuit {
        let vc = CircuitComponent(kind: .dcVoltageSource, designator: "Vctrl", position: Point2D(x: 120, y: 280), value: 1)
        let vco = CircuitComponent(kind: .vcoSine, designator: "VCO1", position: Point2D(x: 280, y: 280), value: 2, secondaryValue: 200,
                                   parameters: ["gain": 100])
        let rl = CircuitComponent(kind: .resistor, designator: "RL", position: Point2D(x: 420, y: 280), rotation: 90, value: 10_000)
        let fc = CircuitComponent(kind: .frequencyCounter, designator: "XFC1", position: Point2D(x: 540, y: 180), stateBool: true)
        let gnd = CircuitComponent(kind: .ground, designator: "GND", position: Point2D(x: 280, y: 420))
        return Circuit(components: [vc, vco, rl, fc, gnd], wires: [
            link(vc.pins[0], vco.pins[2]), link(vc.pins[1], gnd.pins[0]), link(vco.pins[3], gnd.pins[0]),
            link(vco.pins[0], rl.pins[0]), link(rl.pins[1], gnd.pins[0]), link(vco.pins[1], gnd.pins[0]),
            link(fc.pins[0], vco.pins[0]),
        ])
    }
}
