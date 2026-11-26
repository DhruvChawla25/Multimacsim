import XCTest
@testable import MultiSimEngine

final class SourcePolarityTests: XCTestCase {
    /// A current source pushes current out of the terminal its arrow points to (OUT, pin 0).
    func testCurrentSourceDrivesOutOfItsArrow() {
        let bench = TestBench()
        let i = bench.add(.dcCurrentSource, "I1", value: 0.01)
        let r = bench.add(.resistor, "R1", value: 1000)
        bench.wire(i.pins[0], r.pins[0])
        bench.ground(r.pins[1], i.pins[1])
        let res = bench.solver().step()
        XCTAssertEqual(bench.voltage(r.pins[0], res), 10.0, accuracy: 1e-6)
    }

    func testVCCSDrivesOutOfOutPlus() {
        let bench = TestBench()
        let v = bench.add(.dcVoltageSource, "V1", value: 2)
        let g = bench.add(.vccs, "G1", value: 0.01)
        let r = bench.add(.resistor, "R1", value: 100)
        bench.wire(v.pins[0], g.pins[2])
        bench.ground(v.pins[1], g.pins[3], g.pins[1], r.pins[1])
        bench.wire(g.pins[0], r.pins[0])
        let res = bench.solver().step()
        XCTAssertEqual(bench.voltage(r.pins[0], res), 2.0, accuracy: 1e-6) // 0.01 S * 2 V * 100 Ω
    }
}
