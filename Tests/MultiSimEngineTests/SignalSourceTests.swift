import XCTest
@testable import MultiSimEngine

/// Signal voltage and current sources: waveform values, breakpoints and circuit behaviour.
final class SignalSourceTests: XCTestCase {
    private func make(_ kind: ComponentKind, value: Double? = nil, secondary: Double? = nil,
                      _ params: [String: Double] = [:], text: String = "") -> CircuitComponent {
        let d = kind.partDefaults
        return CircuitComponent(kind: kind, designator: "S", value: value ?? d.value, secondaryValue: secondary ?? d.secondaryValue,
                                modeIndex: d.modeIndex, parameters: params, text: text)
    }

    /// Drives a 1 kΩ load and returns the load voltage at each step.
    private func drive(_ src: CircuitComponent, dt: Double, steps: Int) -> [Double] {
        let bench = TestBench()
        let r = bench.add(.resistor, "RL", value: 1000)
        bench.components.append(src)
        bench.wire(src.pins[0], r.pins[0]); bench.ground(src.pins[1], r.pins[1])
        let solver = bench.solver(dt: dt)
        return (0..<steps).map { _ in bench.voltage(r.pins[0], solver.step()) }
    }

    func testAMEnvelope() {
        let am = make(.amVoltage, value: 2, secondary: 1000, ["modIndex": 0.5, "modFreq": 50])
        // Envelope peaks at 2·1.5 = 3 V a quarter of the modulating period in; trough 1 V at three quarters.
        XCTAssertEqual(SourceWaveforms.value(am, at: 5e-3 + 0.25e-3), 3, accuracy: 0.01)
        XCTAssertEqual(abs(SourceWaveforms.value(am, at: 15e-3 + 0.25e-3)), 1, accuracy: 0.01)
        let v = drive(am, dt: 2e-5, steps: 1000) // 20 ms = one modulating cycle
        XCTAssertEqual(v.map(abs).max()!, 3, accuracy: 0.02)
        XCTAssertTrue(SPICEExporter.export(circuit: Circuit(components: [am])).contains("AM("))
    }

    func testFMInstantaneousFrequencySwings() {
        let fm = make(.fmVoltage, value: 1, secondary: 1000, ["modIndex": 5, "modFreq": 20])
        // Count zero crossings over a short window at the modulation peak and trough of instantaneous frequency.
        func crossings(around t0: Double) -> Int {
            var n = 0
            var prev = SourceWaveforms.value(fm, at: t0)
            for k in 1...2000 {
                let v = SourceWaveforms.value(fm, at: t0 + Double(k) * 1e-6)
                if (v >= 0) != (prev >= 0) { n += 1 }
                prev = v
            }
            return n
        }
        // f_inst = fc + β·fm·cos(2π fm t): 1100 Hz at t = 0, 900 Hz at t = 25 ms.
        XCTAssertGreaterThan(crossings(around: 0), crossings(around: 0.025))
        XCTAssertEqual(SourceWaveforms.value(fm, at: 0.2e-3), sin(2 * .pi * 1000 * 0.2e-3 + 5 * sin(2 * .pi * 20 * 0.2e-3)), accuracy: 1e-12)
        XCTAssertTrue(SPICEExporter.export(circuit: Circuit(components: [fm])).contains("SFFM("))
    }

    func testExponentialRiseAndFall() {
        let e = make(.exponentialVoltage, value: 10, ["v1": 0, "td1": 1e-3, "tau1": 1e-3, "td2": 4e-3, "tau2": 2e-3])
        XCTAssertEqual(SourceWaveforms.value(e, at: 0.5e-3), 0)
        XCTAssertEqual(SourceWaveforms.value(e, at: 2e-3), 10 * (1 - exp(-1)), accuracy: 1e-12)
        let rise = 10 * (1 - exp(-5.0))
        XCTAssertEqual(SourceWaveforms.value(e, at: 6e-3), rise - 10 * (1 - exp(-1)), accuracy: 1e-9)
        XCTAssertEqual(SourceWaveforms.nextBreakpoint(e, after: 0)!, 1e-3)
        XCTAssertEqual(SourceWaveforms.nextBreakpoint(e, after: 1e-3)!, 4e-3)
        // The solver follows it through a load (the 1 ms delay lands between steps of 0.3 ms).
        let v = drive(e, dt: 3e-4, steps: 10) // t = 3 ms
        XCTAssertEqual(v.last!, 10 * (1 - exp(-2)), accuracy: 1e-9)
    }
}
