import XCTest
@testable import MultiSimEngine

/// Digital sources drive the existing logic gates (5 V logic, 2.5 V threshold).
final class DigitalSourceTests: XCTestCase {
    func testDigitalClockDrivesAnInverter() {
        let bench = TestBench()
        let clk = bench.add(.digitalClock, "CLK1", secondary: 100) // 10 ms period, high first 5 ms
        let inv = bench.add(.logicNOT, "U1")
        bench.wire(clk.pins[0], inv.pins[0])
        let solver = bench.solver(dt: 1e-3)
        var outs: [Double] = []
        var ins: [Double] = []
        for _ in 0..<20 {
            let r = solver.step()
            ins.append(bench.voltage(clk.pins[0], r))
            outs.append(bench.voltage(inv.pins[1], r))
        }
        XCTAssertEqual(ins[2], 5); XCTAssertEqual(outs[2], 0)   // t = 3 ms
        XCTAssertEqual(ins[7], 0); XCTAssertEqual(outs[7], 5)   // t = 8 ms
        XCTAssertEqual(ins.filter { $0 > 2.5 }.count, 10, accuracy: 1)
        XCTAssertEqual(clk.runtimeReading, ins.last! > 2.5 ? 1 : 0)
    }

    /// Two digital constants into an AND gate: the truth table.
    func testDigitalConstantsDriveAnAndGate() {
        for (a, b) in [(false, false), (false, true), (true, false), (true, true)] {
            let bench = TestBench()
            let ca = bench.add(.digitalConstant, "A", closed: a)
            let cb = bench.add(.digitalConstant, "B", closed: b)
            let gate = bench.add(.logicAND, "U1")
            bench.wire(ca.pins[0], gate.pins[0]); bench.wire(cb.pins[0], gate.pins[1])
            let res = bench.solver().step()
            XCTAssertEqual(bench.voltage(gate.pins[2], res), a && b ? 5 : 0, "\(a) AND \(b)")
            XCTAssertEqual(bench.voltage(ca.pins[0], res), a ? 5 : 0)
        }
    }

    func testInteractiveConstantTogglesTheLogicLive() {
        let bench = TestBench()
        let key = bench.add(.interactiveDigitalConstant, "KEY1")
        let buf = bench.add(.logicBuffer, "U1")
        bench.wire(key.pins[0], buf.pins[0])
        let solver = bench.solver()
        XCTAssertEqual(bench.voltage(buf.pins[1], solver.step()), 0)
        XCTAssertTrue(key.kind.togglesOnClick)
        key.stateBool.toggle() // what a click on the canvas does
        XCTAssertEqual(bench.voltage(buf.pins[1], solver.step()), 5)
        key.stateBool.toggle()
        XCTAssertEqual(bench.voltage(buf.pins[1], solver.step()), 0)
    }
}
