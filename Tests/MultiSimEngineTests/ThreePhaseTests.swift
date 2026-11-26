import XCTest
@testable import MultiSimEngine

/// Three-phase wye and delta sources, checked against hand calculations.
final class ThreePhaseTests: XCTestCase {
    /// 400 V wye source -> star load (R + L per phase), star point back to N through an ammeter.
    private func starLoad(r: [Double], l: Double = 0.0318) -> (TestBench, CircuitComponent, CircuitComponent, [CircuitComponent]) {
        let bench = TestBench()
        let src = bench.add(.threePhaseWye, "V3P", value: 400, secondary: 50)
        let nAmm = bench.add(.ammeter, "IN")
        var lineAmmeters: [CircuitComponent] = []
        let star = bench.add(.resistor, "Rstar", value: 1e-3) // tiny link = the star point
        for i in 0..<3 {
            let am = bench.add(.ammeter, "I\(i)")
            let rr = bench.add(.resistor, "R\(i)", value: r[i])
            let ll = bench.add(.inductor, "L\(i)", value: l)
            bench.wire(src.pins[i], am.pins[0]); bench.wire(am.pins[1], rr.pins[0])
            bench.wire(rr.pins[1], ll.pins[0]); bench.wire(ll.pins[1], star.pins[0])
            lineAmmeters.append(am)
        }
        bench.wire(star.pins[1], nAmm.pins[0]); bench.wire(nAmm.pins[1], src.pins[3])
        bench.ground(src.pins[3])
        return (bench, src, nAmm, lineAmmeters)
    }

    func testBalancedStarLoadHasNoNeutralCurrent() throws {
        let (bench, src, nAmm, lines) = starLoad(r: [10, 10, 10])
        let ac = try ACSteadyStateAnalyzer.analyze(bench.circuit).get()
        let report = try XCTUnwrap(ac.threePhase.first { $0.id == src.id })
        let z = Complex(10.002, 2 * Double.pi * 50 * 0.0318)
        let iPhaseRMS = (400 / 3.0.squareRoot()) / z.magnitude
        for i in 0..<3 {
            XCTAssertEqual(report.lineCurrents[i].magnitude / 2.0.squareRoot(), iPhaseRMS, accuracy: 1e-3)
        }
        XCTAssertLessThan(report.neutralCurrent.magnitude, 1e-9)
        XCTAssertEqual(report.currentUnbalance, 1, accuracy: 1e-9)
        XCTAssertEqual(report.lineVoltages[0].magnitude / 2.0.squareRoot(), 400, accuracy: 1e-6)
        XCTAssertEqual(report.phaseVoltages[0].angleDegrees - report.phaseVoltages[1].angleDegrees, 120, accuracy: 1e-6)
        // P = 3 I² R per phase
        XCTAssertEqual(report.complexPower.re, 3 * iPhaseRMS * iPhaseRMS * 10.002, accuracy: 0.5)

        // The transient agrees: neutral ammeter settles to ~0 A RMS, line ammeters to the phasor value.
        let solver = bench.solver(dt: 1e-4)
        for _ in 0..<6000 { _ = solver.step() } // 0.6 s
        XCTAssertLessThan(nAmm.runtimeReading, 0.05)
        XCTAssertEqual(lines[1].runtimeReading, iPhaseRMS, accuracy: iPhaseRMS * 0.02)
        XCTAssertEqual(src.runtimeState.count, 3)
    }

    func testUnbalancedStarLoadReturnsCurrentInTheNeutral() throws {
        let (bench, src, nAmm, _) = starLoad(r: [10, 20, 40], l: 0)
        let ac = try ACSteadyStateAnalyzer.analyze(bench.circuit).get()
        let report = try XCTUnwrap(ac.threePhase.first { $0.id == src.id })
        let vp = 400 / 3.0.squareRoot() * 2.0.squareRoot()
        // Hand phasor sum of Vp/R at 0°, -120°, +120°.
        let expected = ACSteadyStateAnalyzer.polar(vp / 10.002, degrees: 0)
            + ACSteadyStateAnalyzer.polar(vp / 20.002, degrees: -120)
            + ACSteadyStateAnalyzer.polar(vp / 40.002, degrees: 120)
        XCTAssertEqual(report.neutralCurrent.magnitude, expected.magnitude, accuracy: expected.magnitude * 1e-3) // meters add a few mΩ
        XCTAssertGreaterThan(report.currentUnbalance, 3.9)
        let neutralMeter = try XCTUnwrap(ac.phasor(for: nAmm.id))
        XCTAssertEqual(neutralMeter.current.magnitude, expected.magnitude, accuracy: expected.magnitude * 1e-3)

        let solver = bench.solver(dt: 1e-4)
        for _ in 0..<5000 { _ = solver.step() }
        XCTAssertEqual(nAmm.runtimeReading, expected.magnitude / 2.0.squareRoot(), accuracy: 0.1)
    }

    func testDeltaSourceIntoDeltaLoad() throws {
        let bench = TestBench()
        let src = bench.add(.threePhaseDelta, "VD", value: 400, secondary: 50)
        let rs = (0..<3).map { bench.add(.resistor, "R\($0)", value: 100) }
        bench.wire(src.pins[0], rs[0].pins[0]); bench.wire(rs[0].pins[1], src.pins[1])
        bench.wire(src.pins[1], rs[1].pins[0]); bench.wire(rs[1].pins[1], src.pins[2])
        bench.wire(src.pins[2], rs[2].pins[0]); bench.wire(rs[2].pins[1], src.pins[0])
        bench.ground(src.pins[2])
        let ac = try ACSteadyStateAnalyzer.analyze(bench.circuit).get()
        let report = try XCTUnwrap(ac.threePhase.first)
        for r in rs {
            XCTAssertEqual(ac.phasor(for: r.id)!.rmsVoltage, 400, accuracy: 1e-6)
        }
        // Balanced delta: line current = √3 x phase current
        XCTAssertEqual(report.lineCurrents[0].magnitude / 2.0.squareRoot(), 3.0.squareRoot() * 4, accuracy: 1e-6)
        XCTAssertEqual(report.complexPower.re, 3 * 400 * 400 / 100.0, accuracy: 1e-6)
    }
}
