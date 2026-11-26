import XCTest
@testable import MultiSimEngine

/// Signal current sources: current leaves the OUT terminal (the arrow tip).
final class CurrentSourceTests: XCTestCase {
    private func make(_ kind: ComponentKind, value: Double? = nil, secondary: Double? = nil,
                      _ params: [String: Double] = [:], text: String = "") -> CircuitComponent {
        let d = kind.partDefaults
        return CircuitComponent(kind: kind, designator: "I", value: value ?? d.value, secondaryValue: secondary ?? d.secondaryValue,
                                parameters: params, text: text)
    }

    /// Pushes the source into a 100 Ω load; returns the load voltage each step.
    private func drive(_ src: CircuitComponent, dt: Double, steps: Int) -> (TestBench, CircuitComponent, [Double]) {
        let bench = TestBench()
        let r = bench.add(.resistor, "RL", value: 100)
        bench.components.append(src)
        bench.wire(src.pins[0], r.pins[0]); bench.ground(src.pins[1], r.pins[1])
        let solver = bench.solver(dt: dt)
        let v = (0..<steps).map { _ in bench.voltage(r.pins[0], solver.step()) }
        return (bench, r, v)
    }

    func testACCurrentSourceTransientAndPhasor() throws {
        let src = make(.acCurrentSource, value: 0.02, secondary: 100)
        let (bench, r, v) = drive(src, dt: 1e-4, steps: 200)
        XCTAssertEqual(v.max()!, 2.0, accuracy: 0.01) // 20 mA pk x 100 Ω
        XCTAssertEqual(v[24], 2.0 * sin(2 * .pi * 100 * 25e-4), accuracy: 1e-9)
        let ac = try ACSteadyStateAnalyzer.analyze(bench.circuit).get()
        XCTAssertEqual(ac.phasor(for: r.id)!.peakVoltage, 2.0, accuracy: 1e-9)
        XCTAssertEqual(ac.referenceSource.id, src.id)
    }

    /// A clock current charging a capacitor makes a staircase: it only climbs while the current is on.
    func testClockCurrentChargesACapacitorInSteps() {
        let bench = TestBench()
        let src = make(.clockCurrentSource, value: 1e-3, secondary: 1000, ["duty": 25])
        bench.components.append(src)
        let c = bench.add(.capacitor, "C1", value: 1e-6)
        bench.wire(src.pins[0], c.pins[0]); bench.ground(src.pins[1], c.pins[1])
        let solver = bench.solver(dt: 0.1e-3)
        var res = solver.step()
        for _ in 1..<20 { res = solver.step() } // 2 ms = 2 periods, on for 0.25 ms each
        // ΔV = I·t_on / C = 1 mA · 0.5 ms / 1 µF = 0.5 V
        XCTAssertEqual(bench.voltage(c.pins[0], res), 0.5, accuracy: 0.002)
    }

    func testExponentialCurrentIntoAResistor() {
        let src = make(.exponentialCurrentSource, value: 0.05, ["v1": 0, "td1": 1e-3, "tau1": 2e-3, "td2": 50e-3, "tau2": 1e-3])
        let (_, _, v) = drive(src, dt: 0.5e-3, steps: 6) // 3 ms
        XCTAssertEqual(v.last!, 100 * 0.05 * (1 - exp(-1)), accuracy: 1e-9)
    }
}
