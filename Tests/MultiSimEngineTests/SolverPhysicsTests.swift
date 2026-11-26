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
}
