import XCTest
@testable import MultiSimEngine

/// Voltage-controlled oscillators: f = f0 + gain x V(ctrl), phase integrated step by step.
final class VCOTests: XCTestCase {
    /// Runs the VCO with a DC control voltage and returns the output samples.
    func run(_ kind: ComponentKind, control: Double, dt: Double = 1e-5, steps: Int = 1000,
             params: [String: Double] = ["gain": 500]) -> (TestBench, CircuitComponent, [Double]) {
        let bench = TestBench()
        let vc = bench.add(.dcVoltageSource, "VC", value: control)
        let vco = bench.add(kind, "VCO1", value: 2, secondary: 1000)
        vco.parameters = params
        let load = bench.add(.resistor, "RL", value: 1000)
        bench.wire(vc.pins[0], vco.pins[2]); bench.ground(vc.pins[1], vco.pins[3], vco.pins[1], load.pins[1])
        bench.wire(vco.pins[0], load.pins[0])
        let solver = bench.solver(dt: dt)
        let v = (0..<steps).map { _ in bench.voltage(load.pins[0], solver.step()) }
        return (bench, vco, v)
    }

    static func risingCrossings(_ v: [Double]) -> Int {
        zip(v, v.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
    }

    func testSineFrequencyFollowsTheControlVoltage() {
        let (_, vco, at0) = run(.vcoSine, control: 0)   // 1 kHz for 10 ms
        let (_, _, at2) = run(.vcoSine, control: 2)     // 2 kHz
        XCTAssertEqual(Self.risingCrossings(at0), 10, accuracy: 1)
        XCTAssertEqual(Self.risingCrossings(at2), 20, accuracy: 1)
        XCTAssertEqual(at2.map(abs).max()!, 2, accuracy: 0.01)
        XCTAssertEqual(vco.runtimeReading, 1000, accuracy: 1e-9) // reports its present frequency
        // Exact phase: sample k is at t = (k + 1)·dt on a 2 kHz sine.
        for k in [7, 12, 333] {
            XCTAssertEqual(at2[k], 2 * sin(2 * .pi * 2000 * Double(k + 1) * 1e-5), accuracy: 1e-6)
        }
    }
}

final class VCOSquareTests: XCTestCase {
    func testSquareFrequencyAndExactEdges() {
        let t = VCOTests()
        let (_, _, v) = t.run(.vcoSquare, control: 1, dt: 1e-5, steps: 1000) // 1.5 kHz
        XCTAssertEqual(VCOTests.risingCrossings(v), 15, accuracy: 1)
        XCTAssertEqual(v.max()!, 2, accuracy: 1e-9)
        XCTAssertEqual(v.min()!, -2, accuracy: 1e-9)
        // Edges at multiples of 1/3 ms do not fall on the 10 µs grid, yet the duty stays 50 %.
        let high = v.filter { $0 > 0 }.count
        XCTAssertEqual(Double(high) / Double(v.count), 0.5, accuracy: 0.01)
    }
}
