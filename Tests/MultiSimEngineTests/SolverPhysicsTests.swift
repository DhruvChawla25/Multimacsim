import XCTest
@testable import MultiSimEngine

/// Accuracy of the transient solver against closed-form answers.
final class SolverPhysicsTests: XCTestCase {

    func testVoltageSourceReportsDeliveredCurrent() {
        let bench = TestBench()
        let v = bench.add(.dcVoltageSource, "V1", value: 10)
        let r = bench.add(.resistor, "R1", value: 2000)
        bench.wire(v.pins[0], r.pins[0])
        bench.ground(v.pins[1], r.pins[1])
        let res = bench.solver().step()
        XCTAssertTrue(res.converged)
        XCTAssertEqual(v.runtimeCurrent, 0.005, accuracy: 1e-12)
    }

    func testSPICEToleranceDefaults() {
        let t = SolverTolerances()
        XCTAssertEqual(t.reltol, 1e-3)
        XCTAssertEqual(t.vntol, 1e-6)
        XCTAssertEqual(t.abstol, 1e-12)
    }

    // MARK: - Trapezoidal integration

    func testRCChargeMatchesExponential() {
        // 10 V step into 1 kΩ + 1 µF, tau = 1 ms.
        let bench = TestBench()
        let v = bench.add(.dcVoltageSource, "V1", value: 10)
        let r = bench.add(.resistor, "R1", value: 1000)
        let c = bench.add(.capacitor, "C1", value: 1e-6)
        bench.wire(v.pins[0], r.pins[0]); bench.wire(r.pins[1], c.pins[0])
        bench.ground(v.pins[1], c.pins[1])
        let solver = bench.solver(dt: 1e-5)
        var worst = 0.0
        for k in 1...500 {
            let res = solver.step()
            let t = Double(k) * 1e-5
            worst = max(worst, abs(bench.voltage(c.pins[0], res) - 10 * (1 - exp(-t / 1e-3))))
        }
        XCTAssertLessThan(worst, 5e-3, "trapezoidal RC error")
    }

    func testRLRiseMatchesExponential() {
        // 10 V into 100 Ω + 0.1 H, tau = 1 ms, final current 100 mA.
        let bench = TestBench()
        let v = bench.add(.dcVoltageSource, "V1", value: 10)
        let r = bench.add(.resistor, "R1", value: 100)
        let l = bench.add(.inductor, "L1", value: 0.1)
        bench.wire(v.pins[0], r.pins[0]); bench.wire(r.pins[1], l.pins[0])
        bench.ground(v.pins[1], l.pins[1])
        let solver = bench.solver(dt: 1e-5)
        var worst = 0.0
        for k in 1...500 {
            _ = solver.step()
            let t = Double(k) * 1e-5
            worst = max(worst, abs(l.runtimeCurrent - 0.1 * (1 - exp(-t / 1e-3))))
        }
        XCTAssertLessThan(worst, 5e-5, "trapezoidal RL error (A)")
    }

    /// Ideal LC tank: trapezoidal keeps the energy, backward Euler visibly bleeds it.
    private func lcEnergyRatio(_ method: IntegrationMethod, cycles: Int) -> Double {
        let bench = TestBench()
        let c = bench.add(.capacitor, "C1", value: 1e-6)
        let l = bench.add(.inductor, "L1", value: 1e-3)
        bench.wire(c.pins[0], l.pins[0])
        bench.ground(c.pins[1], l.pins[1])
        let solver = bench.solver(dt: 2e-6)
        solver.integrationMethod = method
        c.runtimePrevVoltage = 1.0 // pre-charged to 1 V, no current
        let e0 = 0.5 * 1e-6 * 1.0
        let period = 2 * Double.pi * (1e-3 * 1e-6).squareRoot()
        let steps = Int(Double(cycles) * period / 2e-6)
        var maxE = 0.0
        for k in 0..<steps {
            _ = solver.step()
            let e = 0.5 * 1e-6 * c.runtimeVoltageDrop * c.runtimeVoltageDrop + 0.5 * 1e-3 * l.runtimeCurrent * l.runtimeCurrent
            if k > steps - 200 { maxE = max(maxE, e) }
        }
        return maxE / e0
    }

    func testLCTankConservesEnergyWithTrapezoidal() {
        let ratio = lcEnergyRatio(.trapezoidal, cycles: 100)
        XCTAssertEqual(ratio, 1.0, accuracy: 0.01, "energy after 100 cycles")
    }

    func testBackwardEulerDampsTheLCTank() {
        XCTAssertLessThan(lcEnergyRatio(.backwardEuler, cycles: 100), 0.5)
    }
}

/// The solver must land exactly on source edges instead of smearing them across a step.
final class BreakpointTests: XCTestCase {
    func testPulseCornersAreExact() {
        let p = PulseShape(v1: 0, v2: 5, delay: 1e-3, rise: 1e-4, fall: 2e-4, width: 3e-4, period: 1e-3)
        XCTAssertEqual(p.nextBreakpoint(after: 0)!, 1e-3, accuracy: 1e-15)
        XCTAssertEqual(p.nextBreakpoint(after: 1e-3)!, 1.1e-3, accuracy: 1e-15)
        XCTAssertEqual(p.nextBreakpoint(after: 1.1e-3)!, 1.4e-3, accuracy: 1e-15)
        XCTAssertEqual(p.nextBreakpoint(after: 1.4e-3)!, 1.6e-3, accuracy: 1e-15)
        XCTAssertEqual(p.nextBreakpoint(after: 1.6e-3)!, 2.0e-3, accuracy: 1e-15)
        XCTAssertEqual(p.value(at: 1.05e-3), 2.5, accuracy: 1e-9)
        XCTAssertEqual(p.value(at: 1.5e-3), 2.5, accuracy: 1e-9)
    }

    /// Clock edge in the middle of a step: the RC response must still follow the exact edge time.
    func testClockEdgeInsideAStepIsResolved() {
        let bench = TestBench()
        let clk = bench.add(.clockSource, "CLK", value: 5, secondary: 2000) // high 0...0.25 ms
        let r = bench.add(.resistor, "R1", value: 1000)
        let c = bench.add(.capacitor, "C1", value: 1e-7) // tau = 0.1 ms
        bench.wire(clk.pins[0], r.pins[0]); bench.wire(r.pins[1], c.pins[0])
        bench.ground(clk.pins[1], c.pins[1])
        let solver = bench.solver(dt: 2e-5) // falling edge at 0.25 ms sits mid-step
        var res = solver.step()
        for _ in 1..<15 { res = solver.step() } // t = 0.3 ms
        XCTAssertEqual(res.time, 3e-4, accuracy: 1e-12)
        let tau = 1e-4
        let atEdge = 5 * (1 - exp(-(2.5e-4 - 1e-9) / tau))
        let expected = atEdge * exp(-(0.5e-4 - 1e-9) / tau)
        XCTAssertEqual(bench.voltage(c.pins[0], res), expected, accuracy: expected * 0.005)
    }
}

/// Optional LTE-controlled sub-stepping.
final class AdaptiveStepTests: XCTestCase {
    /// Worst deviation of a 1 V LC tank from cos(ωt) over `cycles`, at ~10 coarse steps per cycle.
    private func tankError(adaptive: Bool, trtol: Double = 7, cycles: Int = 5) -> (error: Double, substepsUsed: Bool) {
        let bench = TestBench()
        let c = bench.add(.capacitor, "C1", value: 1e-6)
        let l = bench.add(.inductor, "L1", value: 1e-3)
        bench.wire(c.pins[0], l.pins[0])
        bench.ground(c.pins[1], l.pins[1])
        let omega = 1 / (1e-3 * 1e-6).squareRoot()
        let period = 2 * Double.pi / omega
        let dt = period / 10
        let solver = bench.solver(dt: dt)
        solver.adaptiveTimestep = adaptive
        solver.truncationErrorFactor = trtol
        c.runtimePrevVoltage = 1
        var worst = 0.0
        for k in 1...(10 * cycles) {
            _ = solver.step()
            worst = max(worst, abs(c.runtimeVoltageDrop - cos(omega * Double(k) * dt)))
        }
        return (worst, solver.adaptiveStep < dt * 0.99)
    }

    func testAdaptiveStepTracksTheTankFarBetter() {
        let fixed = tankError(adaptive: false).error
        let (adaptive, subdivided) = tankError(adaptive: true, trtol: 1)
        XCTAssertTrue(subdivided)
        XCTAssertGreaterThan(fixed, 0.3, "10 samples per cycle is too coarse on its own")
        XCTAssertLessThan(adaptive, fixed / 5)
        XCTAssertLessThan(adaptive, 0.15)
    }

    func testAdaptiveStepLeavesSlowCircuitsAlone() {
        let bench = TestBench()
        let v = bench.add(.dcVoltageSource, "V1", value: 10)
        let r = bench.add(.resistor, "R1", value: 1000)
        let c = bench.add(.capacitor, "C1", value: 1e-3) // tau = 1 s, steps of 0.1 ms
        bench.wire(v.pins[0], r.pins[0]); bench.wire(r.pins[1], c.pins[0])
        bench.ground(v.pins[1], c.pins[1])
        let solver = bench.solver(dt: 1e-4)
        solver.adaptiveTimestep = true
        var res = solver.step()
        for _ in 0..<99 { res = solver.step() }
        XCTAssertEqual(bench.voltage(c.pins[0], res), 10 * (1 - exp(-0.01)), accuracy: 1e-5)
        XCTAssertGreaterThanOrEqual(solver.adaptiveStep, 1e-4 * 0.999, "grows back to the full step")
    }
}

/// Transient against phasor: once the start-up transient dies away the two must agree in amplitude and phase.
final class TransientVersusPhasorTests: XCTestCase {
    func testSeriesRLCSettlesToThePhasorAmplitudeAndPhase() throws {
        let peak = 130.0 * 2.0.squareRoot()
        let bench = TestBench()
        let vs = bench.add(.acVoltageSource, "Vs", value: peak, secondary: 50)
        let r = bench.add(.resistor, "R", value: 200)
        let l = bench.add(.inductor, "L", value: 0.237)
        let c = bench.add(.capacitor, "C", value: 18e-6)
        bench.wire(vs.pins[0], r.pins[0]); bench.wire(r.pins[1], l.pins[0]); bench.wire(l.pins[1], c.pins[0])
        bench.ground(c.pins[1], vs.pins[1])
        let ac = try ACSteadyStateAnalyzer.analyze(bench.circuit).get()
        let i = ac.sourceCurrent // peak phasor, angle relative to the sine source
        let dt = 5e-5
        let solver = bench.solver(dt: dt)
        var worst = 0.0
        for k in 1...10_000 { // 0.5 s; compare over the last two cycles sample by sample
            _ = solver.step()
            if k > 9_200 {
                let t = Double(k) * dt
                let expected = i.magnitude * sin(2 * .pi * 50 * t + i.angleDegrees * .pi / 180)
                worst = max(worst, abs(r.runtimeCurrent - expected))
            }
        }
        XCTAssertLessThan(worst, i.magnitude * 0.002, "within 0.2 % of the phasor waveform")
    }
}
