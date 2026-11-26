import XCTest
@testable import MultiSimEngine

/// Checks the phasor solver against the worked lab sheets (130 V RMS, 50 Hz).
final class ACSteadyStateTests: XCTestCase {
    private let peak = 130.0 * 2.0.squareRoot()

    private func seriesRLC() -> Circuit {
        let vs = CircuitComponent(kind: .acVoltageSource, designator: "Vs", value: peak, secondaryValue: 50)
        let r = CircuitComponent(kind: .resistor, designator: "R", value: 200)
        let l = CircuitComponent(kind: .inductor, designator: "L", value: 0.237)
        let c = CircuitComponent(kind: .capacitor, designator: "C", value: 18e-6)
        let gnd = CircuitComponent(kind: .ground, designator: "GND")
        return Circuit(components: [vs, r, l, c, gnd], wires: [
            Wire(startPinId: vs.pins[0].id, endPinId: r.pins[0].id),
            Wire(startPinId: r.pins[1].id, endPinId: l.pins[0].id),
            Wire(startPinId: l.pins[1].id, endPinId: c.pins[0].id),
            Wire(startPinId: c.pins[1].id, endPinId: gnd.pins[0].id),
            Wire(startPinId: vs.pins[1].id, endPinId: gnd.pins[0].id),
        ])
    }

    private func parallelBranches() -> Circuit {
        let vs = CircuitComponent(kind: .acVoltageSource, designator: "Vs", value: peak, secondaryValue: 50)
        let r1 = CircuitComponent(kind: .resistor, designator: "R1", value: 200)
        let l = CircuitComponent(kind: .inductor, designator: "L", value: 0.239)
        let r2 = CircuitComponent(kind: .resistor, designator: "R2", value: 200)
        let c = CircuitComponent(kind: .capacitor, designator: "C", value: 18e-6)
        let gnd = CircuitComponent(kind: .ground, designator: "GND")
        return Circuit(components: [vs, r1, l, r2, c, gnd], wires: [
            Wire(startPinId: vs.pins[0].id, endPinId: r1.pins[0].id),
            Wire(startPinId: vs.pins[0].id, endPinId: r2.pins[0].id),
            Wire(startPinId: r1.pins[1].id, endPinId: l.pins[0].id),
            Wire(startPinId: r2.pins[1].id, endPinId: c.pins[0].id),
            Wire(startPinId: l.pins[1].id, endPinId: gnd.pins[0].id),
            Wire(startPinId: c.pins[1].id, endPinId: gnd.pins[0].id),
            Wire(startPinId: vs.pins[1].id, endPinId: gnd.pins[0].id),
        ])
    }

    private func solved(_ circuit: Circuit) throws -> ACSteadyStateResult {
        try ACSteadyStateAnalyzer.analyze(circuit).get()
    }

    private func part(_ ac: ACSteadyStateResult, _ name: String) -> ComponentPhasor {
        ac.parts.first { $0.designator == name }!
    }

    func testSeriesRLCMatchesLabSheet() throws {
        let ac = try solved(seriesRLC())
        XCTAssertEqual(ac.omega, 314.16, accuracy: 0.01)
        XCTAssertEqual(ac.reactances.first { $0.kind == .inductor }!.impedance.im, 74.46, accuracy: 0.01)
        XCTAssertEqual(ac.reactances.first { $0.kind == .capacitor }!.impedance.im, -176.84, accuracy: 0.01)

        // |Z| = sqrt(200² + (74.46 − 176.84)²) = 224.68 Ω, I_peak = 183.85 / 224.68 = 0.818 A
        XCTAssertEqual(ac.totalImpedance.magnitude, 224.68, accuracy: 0.05)
        XCTAssertEqual(ac.sourceCurrent.magnitude, 0.818, accuracy: 0.001)
        XCTAssertEqual(ac.sourceCurrent.magnitude / 2.0.squareRoot(), 0.579, accuracy: 0.001)
        // Capacitive overall: current leads the voltage.
        XCTAssertEqual(ac.currentPhaseDegrees, 27.11, accuracy: 0.05)

        XCTAssertEqual(part(ac, "R").peakVoltage, 163.66, accuracy: 0.1)
        XCTAssertEqual(part(ac, "L").peakVoltage, 60.93, accuracy: 0.1)
        XCTAssertEqual(part(ac, "C").peakVoltage, 144.71, accuracy: 0.1)
        XCTAssertEqual(part(ac, "R").rmsVoltage, 115.72, accuracy: 0.1)
    }

    func testParallelBranchesMatchLabSheet() throws {
        let ac = try solved(parallelBranches())
        XCTAssertEqual(ac.reactances.first { $0.kind == .inductor }!.impedance.im, 75.08, accuracy: 0.01)

        let i1 = part(ac, "R1").current
        let i2 = part(ac, "R2").current
        XCTAssertEqual(i1.magnitude / 2.0.squareRoot(), 0.609, accuracy: 0.001)
        XCTAssertEqual(i1.angleDegrees, -20.58, accuracy: 0.05)
        XCTAssertEqual(i2.magnitude / 2.0.squareRoot(), 0.487, accuracy: 0.001)
        XCTAssertEqual(i2.angleDegrees, 41.49, accuracy: 0.05)

        // KCL: the source current is the phasor sum of the branch currents.
        let sum = i1 + i2
        XCTAssertEqual(ac.sourceCurrent.re, sum.re, accuracy: 1e-9)
        XCTAssertEqual(ac.sourceCurrent.im, sum.im, accuracy: 1e-9)

        XCTAssertEqual(part(ac, "R1").rmsVoltage, 121.7, accuracy: 0.2)
        XCTAssertEqual(part(ac, "L").rmsVoltage, 45.7, accuracy: 0.1)
        XCTAssertEqual(part(ac, "R2").rmsVoltage, 97.4, accuracy: 0.1)
        XCTAssertEqual(part(ac, "C").rmsVoltage, 86.1, accuracy: 0.1)
    }

    func testRejectsNonLinearParts() {
        let circuit = seriesRLC()
        circuit.components.append(CircuitComponent(kind: .diode, designator: "D1"))
        guard case .failure(.unsupportedPart("D1")) = ACSteadyStateAnalyzer.analyze(circuit) else {
            return XCTFail("a diode must stop phasor analysis")
        }
    }

    func testRequiresACSource() {
        let r = CircuitComponent(kind: .resistor, designator: "R", value: 10)
        guard case .failure(.noACSource) = ACSteadyStateAnalyzer.analyze(Circuit(components: [r])) else {
            return XCTFail("needs an AC source")
        }
    }

    /// The time-domain solver, once settled, should agree with the phasor answer.
    func testTransientSettlesToPhasorAmplitude() throws {
        let circuit = seriesRLC()
        let ac = try solved(circuit)
        let solver = MNASolver(circuit: circuit, timeStep: 2e-5)
        let r = circuit.components.first { $0.designator == "R" }!
        var maxI = 0.0
        for k in 0..<25_000 { // 0.5 s; measure over the last 2 cycles
            _ = solver.step()
            if k > 23_000 { maxI = max(maxI, abs(r.runtimeCurrent)) }
        }
        XCTAssertEqual(maxI, ac.sourceCurrent.magnitude, accuracy: 0.01)
    }

    // MARK: - Experiment 3 parallel bench, three switch cases

    private func meter(_ ac: ACSteadyStateResult, _ name: String) -> ComponentPhasor {
        ac.parts.first { $0.designator == name }!
    }

    func testParallelCase1OnlyRLBranchConducts() throws {
        let ac = try solved(LabCircuits.acParallelBench(rlClosed: true, rcClosed: false))
        XCTAssertEqual(meter(ac, "I1").rmsCurrent, 0.609, accuracy: 0.002)
        XCTAssertEqual(meter(ac, "I2").rmsCurrent, 0.0, accuracy: 1e-5)
        XCTAssertEqual(meter(ac, "I").rmsCurrent, 0.609, accuracy: 0.002)
        // W1 = I1² R1 = 0.609² × 200 ≈ 74.1 W
        XCTAssertEqual(meter(ac, "W").averagePower, 74.1, accuracy: 0.5)
    }

    func testParallelCase2OnlyRCBranchConducts() throws {
        let ac = try solved(LabCircuits.acParallelBench(rlClosed: false, rcClosed: true))
        XCTAssertEqual(meter(ac, "I1").rmsCurrent, 0.0, accuracy: 1e-5)
        XCTAssertEqual(meter(ac, "I2").rmsCurrent, 0.487, accuracy: 0.002)
        // W2 = I2² R2 = 0.487² × 200 ≈ 47.4 W
        XCTAssertEqual(meter(ac, "W").averagePower, 47.4, accuracy: 0.5)
    }

    func testParallelCase3WattmeterReadsSumOfBranches() throws {
        let ac = try solved(LabCircuits.acParallelBench(rlClosed: true, rcClosed: true))
        let i1 = meter(ac, "I1").rmsCurrent, i2 = meter(ac, "I2").rmsCurrent
        XCTAssertEqual(i1, 0.609, accuracy: 0.002)
        XCTAssertEqual(i2, 0.487, accuracy: 0.002)
        // The phasor sum is smaller than the arithmetic sum: the branches partly cancel.
        XCTAssertLessThan(meter(ac, "I").rmsCurrent, i1 + i2)
        XCTAssertEqual(meter(ac, "W").averagePower, 74.1 + 47.4, accuracy: 1.0)
    }

    /// Settled AC meters in the time-domain simulation read RMS, matching the phasor answer.
    func testTransientMetersReadRMS() throws {
        let circuit = LabCircuits.acParallelBench(rlClosed: true, rcClosed: true)
        let solver = MNASolver(circuit: circuit, timeStep: 1e-4)
        for _ in 0..<12_000 { _ = solver.step() } // 1.2 s
        let reading = { (name: String) in circuit.components.first { $0.designator == name }!.runtimeReading }
        XCTAssertEqual(reading("I1"), 0.609, accuracy: 0.015)
        XCTAssertEqual(reading("I2"), 0.487, accuracy: 0.015)
        XCTAssertEqual(reading("W"), 121.5, accuracy: 4)
    }
}

/// The generalised phasor solver: dependent sources, op-amps, generators and small-signal linearisation.
final class PhasorGeneralTests: XCTestCase {
    func testOpAmpInvertingAmplifierPhasor() throws {
        let bench = TestBench()
        let v = bench.add(.acVoltageSource, "V1", value: 1, secondary: 1000)
        let rin = bench.add(.resistor, "Rin", value: 1000)
        let rf = bench.add(.resistor, "Rf", value: 4700)
        let u = bench.add(.opAmp, "U1")
        bench.wire(v.pins[0], rin.pins[0]); bench.wire(rin.pins[1], u.pins[0])
        bench.wire(u.pins[0], rf.pins[0]); bench.wire(rf.pins[1], u.pins[2])
        bench.ground(v.pins[1], u.pins[1])
        let ac = try ACSteadyStateAnalyzer.analyze(bench.circuit).get()
        let out = ac.nodeVoltage(bench.node(u.pins[2]))
        XCTAssertEqual(out.magnitude, 4.7, accuracy: 1e-3)
        XCTAssertEqual(abs(out.angleDegrees), 180, accuracy: 0.01)
    }

    func testSineFunctionGeneratorDrivesPhasorAnalysis() throws {
        let bench = TestBench()
        let g = bench.add(.functionGenerator, "XFG1", value: 2, secondary: 500)
        let r = bench.add(.resistor, "R1", value: 100)
        bench.wire(g.pins[0], r.pins[0]); bench.ground(g.pins[1], r.pins[1])
        let ac = try ACSteadyStateAnalyzer.analyze(bench.circuit).get()
        XCTAssertEqual(ac.frequency, 500)
        XCTAssertEqual(ac.sourceCurrent.magnitude, 0.02, accuracy: 1e-9)
    }

    func testFrequencyOverrideMovesEverySource() throws {
        let bench = TestBench()
        let v = bench.add(.acVoltageSource, "V1", value: 1, secondary: 50)
        let r = bench.add(.resistor, "R1", value: 1000)
        let c = bench.add(.capacitor, "C1", value: 1e-6)
        bench.wire(v.pins[0], r.pins[0]); bench.wire(r.pins[1], c.pins[0]); bench.ground(v.pins[1], c.pins[1])
        let fc = 1 / (2 * Double.pi * 1e-3)
        let ac = try ACSteadyStateAnalyzer.analyze(bench.circuit, frequency: fc).get()
        let h = ac.nodeVoltage(bench.node(c.pins[0]))
        XCTAssertEqual(h.magnitude, 1 / 2.0.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(h.angleDegrees, -45, accuracy: 1e-6)
    }
}
