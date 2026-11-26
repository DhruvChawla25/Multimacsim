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
