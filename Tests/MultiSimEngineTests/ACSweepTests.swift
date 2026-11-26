import XCTest
@testable import MultiSimEngine

/// AC sweep against closed-form frequency responses.
final class ACSweepTests: XCTestCase {
    func testFrequencyGridIsLogSpaced() {
        let f = ACSweepAnalyzer.frequencies(start: 10, stop: 10_000, pointsPerDecade: 10)
        XCTAssertEqual(f.count, 31)
        XCTAssertEqual(f.first!, 10, accuracy: 1e-9)
        XCTAssertEqual(f.last!, 10_000, accuracy: 1e-6)
        XCTAssertEqual(f[10], 100, accuracy: 1e-9)
    }

    func testRCLowPassBode() throws {
        let bench = TestBench()
        let v = bench.add(.acVoltageSource, "V1", value: 1, secondary: 50)
        let r = bench.add(.resistor, "R1", value: 1000)
        let c = bench.add(.capacitor, "C1", value: 100e-9) // fc = 1591.5 Hz
        bench.wire(v.pins[0], r.pins[0]); bench.wire(r.pins[1], c.pins[0]); bench.ground(v.pins[1], c.pins[1])
        let sweep = try ACSweepAnalyzer.sweep(bench.circuit, input: .across(v, in: bench.circuit), output: .across(c, in: bench.circuit),
                                              start: 10, stop: 1e6, pointsPerDecade: 40).get()
        let fc = 1 / (2 * Double.pi * 1000 * 100e-9)
        XCTAssertEqual(try XCTUnwrap(sweep.lowPassCutoff), fc, accuracy: fc * 0.01)
        for p in sweep.points {
            let w = 2 * Double.pi * p.frequency * 1e-4
            XCTAssertEqual(p.magnitudeDB, -10 * log10(1 + w * w), accuracy: 1e-9)
            XCTAssertEqual(p.phaseDegrees, -atan(w) * 180 / .pi, accuracy: 1e-9)
        }
        // -20 dB/decade roll-off well above fc
        let a = sweep.nearest(1e5)!, b = sweep.nearest(1e6)!
        XCTAssertEqual(a.magnitudeDB - b.magnitudeDB, 20, accuracy: 0.05)
    }

    func testPhaseIsUnwrappedThroughAThirdOrderFilter() throws {
        // Three RC sections: phase heads to -270° without jumping back to +90°.
        let bench = TestBench()
        let v = bench.add(.acVoltageSource, "V1", value: 1, secondary: 50)
        bench.ground(v.pins[1])
        var prev = v.pins[0]
        var lastC: CircuitComponent!
        for k in 0..<3 {
            let r = bench.add(.resistor, "R\(k)", value: 1000), c = bench.add(.capacitor, "C\(k)", value: 1e-7)
            bench.wire(prev, r.pins[0]); bench.wire(r.pins[1], c.pins[0]); bench.ground(c.pins[1])
            prev = r.pins[1]; lastC = c
        }
        let sweep = try ACSweepAnalyzer.sweep(bench.circuit, input: .across(v, in: bench.circuit), output: .across(lastC, in: bench.circuit),
                                              start: 10, stop: 1e7, pointsPerDecade: 20).get()
        XCTAssertEqual(sweep.points.last!.phaseDegrees, -270, accuracy: 2)
        for (a, b) in zip(sweep.points, sweep.points.dropFirst()) { XCTAssertLessThan(abs(b.phaseDegrees - a.phaseDegrees), 30) }
    }

    func testSmallSignalCommonEmitterGain() throws {
        // BJT common-emitter stage, linearised at its operating point: gain ≈ -gm·Rc at mid band.
        let bench = TestBench()
        let vcc = bench.add(.dcVoltageSource, "VCC", value: 12)
        let rb = bench.add(.resistor, "RB", value: 1e6)
        let rc = bench.add(.resistor, "RC", value: 2000)
        let q = bench.add(.bjtNPN, "Q1", secondary: 100)
        let cin = bench.add(.capacitor, "CIN", value: 10e-6)
        let vs = bench.add(.acVoltageSource, "VS", value: 0.001, secondary: 1000)
        bench.wire(vcc.pins[0], rb.pins[0]); bench.wire(vcc.pins[0], rc.pins[0])
        bench.wire(rb.pins[1], q.pins[0]); bench.wire(rc.pins[1], q.pins[1])
        bench.wire(vs.pins[0], cin.pins[0]); bench.wire(cin.pins[1], q.pins[0])
        bench.ground(vcc.pins[1], q.pins[2], vs.pins[1])
        let sweep = try ACSweepAnalyzer.sweep(bench.circuit, input: .across(vs, in: bench.circuit),
                                              output: ACSweepProbe(plus: bench.node(q.pins[1]), label: "Vc"),
                                              start: 100, stop: 10_000, pointsPerDecade: 5).get()
        // I_B = (12 - 0.7) / 1 MΩ ≈ 11.3 µA, I_C ≈ 1.13 mA, gm = I_C / V_T ≈ 43.7 mS, |A| ≈ gm·RC ≈ 87
        let mid = sweep.nearest(10_000)!
        XCTAssertEqual(mid.response.magnitude, 87, accuracy: 6)
        XCTAssertEqual(abs(mid.phaseDegrees), 180, accuracy: 2)
    }

    func testBodePlotterPartMeasuresItsOwnTerminals() throws {
        let bench = TestBench()
        let v = bench.add(.acVoltageSource, "V1", value: 1, secondary: 50)
        let r = bench.add(.resistor, "R1", value: 1000)
        let c = bench.add(.capacitor, "C1", value: 100e-9)
        let bp = bench.add(.bodePlotter, "XBP1")
        bench.wire(v.pins[0], r.pins[0]); bench.wire(r.pins[1], c.pins[0]); bench.ground(v.pins[1], c.pins[1])
        bench.wire(bp.pins[0], v.pins[0]); bench.wire(bp.pins[2], c.pins[0]); bench.ground(bp.pins[1], bp.pins[3])
        let pair = try XCTUnwrap(ACSweepProbe.bodePairs(bp, in: bench.circuit))
        let sweep = try ACSweepAnalyzer.sweep(bench.circuit, input: pair.input, output: pair.output, start: 100, stop: 1e5, pointsPerDecade: 20).get()
        XCTAssertEqual(try XCTUnwrap(sweep.lowPassCutoff), 1591.5, accuracy: 16)
        // The plotter itself draws no current and does not upset the transient.
        let res = bench.solver().step()
        XCTAssertFalse(res.isSingular)
    }
}
