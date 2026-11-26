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
}
