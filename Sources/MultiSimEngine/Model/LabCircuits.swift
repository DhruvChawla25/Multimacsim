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

}
