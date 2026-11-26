import XCTest
@testable import MultiSimEngine

/// Control function blocks: ideal inputs, ideal output to ground.
final class ControlBlockTests: XCTestCase {
    /// Wires DC (or `kind`) sources into a block's inputs and a 1 kΩ load on its output.
    func block(_ kind: ComponentKind, value: Double? = nil, inputs: [Double], params: [String: Double] = [:],
               text: String = "", source: ComponentKind = .dcVoltageSource, secondary: Double? = nil)
        -> (TestBench, CircuitComponent, [CircuitComponent], CircuitComponent) {
        let bench = TestBench()
        let b = bench.add(kind, "A1", value: value)
        b.parameters = params
        b.text = text
        var sources: [CircuitComponent] = []
        for (i, u) in inputs.enumerated() {
            let s = bench.add(source, "V\(i)", value: u, secondary: secondary)
            bench.wire(s.pins[0], b.pins[i]); bench.ground(s.pins[1])
            sources.append(s)
        }
        let load = bench.add(.resistor, "RL", value: 1000)
        bench.wire(b.pins[inputs.count], load.pins[0]); bench.ground(load.pins[1])
        return (bench, b, sources, load)
    }

    func output(_ bench: TestBench, _ b: CircuitComponent, _ res: SimulationStepResult) -> Double {
        bench.voltage(b.pins[b.pins.count - 1], res)
    }

    func testGainBlock() throws {
        let (bench, b, _, _) = block(.gainBlock, value: -3, inputs: [1.5], params: ["inOffset": 0.5, "outOffset": 1])
        XCTAssertEqual(output(bench, b, bench.solver().step()), -3 * 2 + 1, accuracy: 1e-9)
        let (acBench, acBlock, _, _) = block(.gainBlock, value: 4, inputs: [1], source: .acVoltageSource, secondary: 100)
        let ac = try ACSteadyStateAnalyzer.analyze(acBench.circuit).get()
        XCTAssertEqual(ac.nodeVoltage(acBench.node(acBlock.pins[1])).magnitude, 4, accuracy: 1e-9)
        XCTAssertTrue(SPICEExporter.export(circuit: bench.circuit).contains("V={-3.0*("))
    }

    func testMultiplierAndMixing() {
        let (bench, b, _, _) = block(.multiplierBlock, value: 0.5, inputs: [3, -4], params: ["xOffset": 1])
        XCTAssertEqual(output(bench, b, bench.solver().step()), 0.5 * 4 * -4, accuracy: 1e-9)
        // Squaring a sine (both inputs on one net): mean = A²/2, i.e. a frequency doubler with DC.
        let sq = TestBench()
        let s = sq.add(.acVoltageSource, "VS", value: 2, secondary: 50)
        let m = sq.add(.multiplierBlock, "A1", value: 1)
        sq.wire(s.pins[0], m.pins[0]); sq.wire(s.pins[0], m.pins[1]); sq.ground(s.pins[1])
        let solver = sq.solver(dt: 1e-4)
        var sum = 0.0
        for _ in 0..<200 { sum += sq.voltage(m.pins[2], solver.step()) }
        XCTAssertEqual(sum / 200, 2.0, accuracy: 1e-3)
    }

    func testDividerAndItsLowerLimit() {
        let (bench, b, src, _) = block(.dividerBlock, value: 2, inputs: [3, 4])
        let solver = bench.solver()
        XCTAssertEqual(output(bench, b, solver.step()), 2 * 3 / 4.0, accuracy: 1e-9)
        src[1].value = 0 // divide by zero: the denominator is held at 1 µV, never infinite
        XCTAssertEqual(output(bench, b, solver.step()), 2 * 3 / 1e-6, accuracy: 1)
        src[1].value = -0.5
        XCTAssertEqual(output(bench, b, solver.step()), -12, accuracy: 1e-9)
    }

    func testSummerWeightsItsInputs() throws {
        let (bench, b, _, _) = block(.summerBlock, value: 2, inputs: [1, 2, 3], params: ["bGain": -1, "outOffset": 0.5])
        XCTAssertEqual(output(bench, b, bench.solver().step()), 2 * (1 - 2 + 3) + 0.5, accuracy: 1e-9)
        // Phasor: two AC inputs at the same frequency add as phasors.
        let (acBench, s, _, _) = block(.summerBlock, value: 1, inputs: [1, 1, 0], source: .acVoltageSource, secondary: 50)
        let ac = try ACSteadyStateAnalyzer.analyze(acBench.circuit).get()
        XCTAssertEqual(ac.nodeVoltage(acBench.node(s.pins[3])).magnitude, 2, accuracy: 1e-9)
    }

    func testIntegratorRampsAndClips() throws {
        let (bench, b, _, _) = block(.integratorBlock, value: 100, inputs: [2], params: ["upper": 1.5, "lower": -1.5])
        let solver = bench.solver(dt: 1e-3)
        var res = solver.step()
        XCTAssertEqual(output(bench, b, res), 100 * 2 * 1e-3, accuracy: 1e-9) // 0.2 V after 1 ms
        for _ in 0..<4 { res = solver.step() }
        XCTAssertEqual(output(bench, b, res), 1.0, accuracy: 1e-9)             // 5 ms
        for _ in 0..<10 { res = solver.step() }
        XCTAssertEqual(output(bench, b, res), 1.5, accuracy: 1e-9)             // clipped at the upper limit
        // Integrating a sine gives -cos: trapezoidal tracks it closely, and the phasor gain is K/ω at -90°.
        let (sb, sblk, _, _) = block(.integratorBlock, value: 2 * .pi * 50, inputs: [1], source: .acVoltageSource, secondary: 50)
        let sv = sb.solver(dt: 1e-4)
        var r = sv.step()
        for _ in 1..<100 { r = sv.step() } // 10 ms: half a cycle, ∫ = (1 - cos π)·K/ω = 2
        XCTAssertEqual(output(sb, sblk, r), 2, accuracy: 1e-3)
        let ac = try ACSteadyStateAnalyzer.analyze(sb.circuit).get()
        let out = ac.nodeVoltage(sb.node(sblk.pins[1]))
        XCTAssertEqual(out.magnitude, 1, accuracy: 1e-9)
        XCTAssertEqual(out.angleDegrees, -90, accuracy: 1e-9)
    }

    func testDifferentiatorOfARampIsConstant() throws {
        let bench = TestBench()
        let ramp = bench.add(.pwlVoltage, "VR")
        ramp.text = "0 0\n10m 5"           // 500 V/s
        ramp.parameters = ["period": 0]
        let d = bench.add(.differentiatorBlock, "A1", value: 2e-3)
        bench.wire(ramp.pins[0], d.pins[0]); bench.ground(ramp.pins[1])
        let solver = bench.solver(dt: 1e-4)
        var res = solver.step()
        for _ in 0..<20 { res = solver.step() }
        XCTAssertEqual(bench.voltage(d.pins[1], res), 2e-3 * 500, accuracy: 1e-6)
        let (ab, ablk, _, _) = block(.differentiatorBlock, value: 1e-3, inputs: [1], source: .acVoltageSource, secondary: 1000)
        let ac = try ACSteadyStateAnalyzer.analyze(ab.circuit).get()
        let out = ac.nodeVoltage(ab.node(ablk.pins[1]))
        XCTAssertEqual(out.magnitude, 2 * .pi, accuracy: 1e-9)
        XCTAssertEqual(out.angleDegrees, 90, accuracy: 1e-9)
    }

    func testLimiterClipsASine() {
        let (bench, b, _, _) = block(.limiterBlock, value: 2, inputs: [3], params: ["upper": 4, "lower": -1],
                                     source: .acVoltageSource, secondary: 50)
        let solver = bench.solver(dt: 1e-4)
        let v = (0..<200).map { _ in output(bench, b, solver.step()) }
        XCTAssertEqual(v.max()!, 4, accuracy: 1e-9)
        XCTAssertEqual(v.min()!, -1, accuracy: 1e-9)
        XCTAssertEqual(v[9], 2 * 3 * sin(2 * .pi * 50 * 1e-3), accuracy: 1e-9) // unclipped region is K·u
    }

    func testHysteresisSwitchesAtDifferentThresholds() {
        let (bench, b, _, _) = block(.hysteresisBlock, inputs: [2], source: .acVoltageSource, secondary: 50) // ±1 V thresholds
        let solver = bench.solver(dt: 1e-4)
        var risingSwitch: Double?, fallingSwitch: Double?
        var last = output(bench, b, solver.step())
        for k in 2...400 {
            let y = output(bench, b, solver.step())
            let t = Double(k) * 1e-4
            if y > last { risingSwitch = risingSwitch ?? t }
            if y < last { fallingSwitch = fallingSwitch ?? t }
            last = y
        }
        // 2 sin(ωt) crosses +1 V going up at 1.667 ms and -1 V going down at 11.667 ms.
        XCTAssertEqual(try XCTUnwrap(fallingSwitch), 0.011667, accuracy: 1.5e-4)
        XCTAssertEqual(try XCTUnwrap(risingSwitch), 0.021667, accuracy: 1.5e-4)
        XCTAssertEqual(Set([5.0, -5.0]).contains(last), true)
    }
}
