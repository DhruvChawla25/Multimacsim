import XCTest
@testable import MultiSimEngine

/// The ABM expression language and the behavioural sources built on it.
final class ExpressionTests: XCTestCase {
    private func eval(_ s: String, refs: [Double] = [], t: Double = 0) throws -> Double {
        try Expression.parse(s).get().root.evaluate(refs: refs, time: t)
    }

    func testPrecedenceAndAssociativity() throws {
        XCTAssertEqual(try eval("1 + 2 * 3"), 7)
        XCTAssertEqual(try eval("(1 + 2) * 3"), 9)
        XCTAssertEqual(try eval("2 ^ 3 ^ 2"), 512)       // right associative
        XCTAssertEqual(try eval("-2 ^ 2"), -4)
        XCTAssertEqual(try eval("10 / 4 / 5"), 0.5)
        XCTAssertEqual(try eval("2k + 500m"), 2000.5)    // engineering suffixes
        XCTAssertEqual(try eval("1e-3 * 4"), 0.004, accuracy: 1e-15)
    }

    func testFunctionsTimeAndPi() throws {
        XCTAssertEqual(try eval("sin(pi/2) + cos(0) + exp(0) + log(1) + abs(-3) + sqrt(16)"), 1 + 1 + 1 + 0 + 3 + 4, accuracy: 1e-12)
        XCTAssertEqual(try eval("2*time", t: 0.25), 0.5)
        XCTAssertEqual(try eval("limit(7, 0, 5) + min(1, 2) + max(1, 2)"), 8)
        XCTAssertEqual(try eval("sqrt(-4) + log(0)"), log(1e-300)) // kept finite
    }

    func testReferences() throws {
        let p = try Expression.parse("V(3) - 2*V(R1) + I(R1) + V(1, 2) + V(3)").get()
        XCTAssertEqual(p.references, [.nodeVoltage(3), .partVoltage("R1"), .partCurrent("R1"), .difference(.nodeVoltage(1), .nodeVoltage(2))])
        XCTAssertEqual(p.root.evaluate(refs: [1, 2, 3, 4], time: 0), 1 - 4 + 3 + 4 + 1)
    }

    func testErrorsAreReportedNotEvaluated() {
        XCTAssertEqual(Expression.parse(""), .failure(.empty))
        XCTAssertEqual(Expression.parse("foo(1)"), .failure(.unknownFunction("foo")))
        XCTAssertEqual(Expression.parse("min(1)"), .failure(.wrongArgumentCount("min")))
        XCTAssertEqual(Expression.parse("1 +"), .failure(.unexpected("end")))
        XCTAssertEqual(Expression.parse("2 $ 3"), .failure(.unexpected("$")))
        XCTAssertEqual(Expression.parse("system(\"rm\")"), .failure(.unexpected("\"")))
    }
}
final class ABMSourceTests: XCTestCase {
    func testABMVoltageAmplifiesANode() {
        let bench = TestBench()
        let v = bench.add(.dcVoltageSource, "V1", value: 1.5)
        let r = bench.add(.resistor, "R1", value: 1000)
        let b = bench.add(.abmVoltage, "B1")
        let load = bench.add(.resistor, "RL", value: 100)
        bench.wire(v.pins[0], r.pins[0]); bench.ground(v.pins[1], r.pins[1], b.pins[1], load.pins[1])
        bench.wire(b.pins[0], load.pins[0])
        let n = bench.node(v.pins[0])
        b.text = "3*V(\(n)) + 2*V(R1) + 1k*I(R1)" // 4.5 + 3 + 1.5 = 9 V
        let res = bench.solver().step()
        XCTAssertEqual(bench.voltage(load.pins[0], res), 9, accuracy: 1e-6)
        XCTAssertEqual(b.runtimeCurrent, 0.09, accuracy: 1e-6)
    }

    func testABMCurrentSquareLawConverges() {
        // Square-law "transistor": I = 2m·V(ctrl)², into 1 kΩ.
        let bench = TestBench()
        let v = bench.add(.dcVoltageSource, "VG", value: 2)
        let b = bench.add(.abmCurrent, "B1")
        let load = bench.add(.resistor, "RL", value: 1000)
        bench.ground(v.pins[1], b.pins[1], load.pins[1])
        bench.wire(b.pins[0], load.pins[0])
        b.text = "2m*V(VG)^2"
        let res = bench.solver().step()
        XCTAssertTrue(res.converged)
        XCTAssertEqual(load.runtimeCurrent, 0.008, accuracy: 1e-9)
        XCTAssertEqual(bench.voltage(load.pins[0], res), 8, accuracy: 1e-6)
    }

    func testABMWithFeedbackSolvesSelfConsistently() {
        // V(out) = 10 - V(out)^2 / 10  ->  V = 7.0156 (positive root of v² + 10v - 100 = 0)
        let bench = TestBench()
        let b = bench.add(.abmVoltage, "B1")
        let load = bench.add(.resistor, "RL", value: 1000)
        bench.wire(b.pins[0], load.pins[0]); bench.ground(b.pins[1], load.pins[1])
        b.text = "10 - V(RL)^2/10"
        let res = bench.solver().step()
        XCTAssertTrue(res.converged)
        XCTAssertEqual(bench.voltage(load.pins[0], res), (-10 + (100.0 + 400).squareRoot()) / 2, accuracy: 1e-6)
    }

    func testABMDefaultIsATimeSignal() {
        let bench = TestBench()
        let b = bench.add(.abmVoltage, "B1")
        let load = bench.add(.resistor, "RL", value: 1000)
        bench.wire(b.pins[0], load.pins[0]); bench.ground(b.pins[1], load.pins[1])
        let solver = bench.solver(dt: 1e-3)
        var res = solver.step()
        for _ in 0..<4 { res = solver.step() } // 5 ms = quarter cycle of 50 Hz
        XCTAssertEqual(bench.voltage(load.pins[0], res), 5, accuracy: 1e-6)
        XCTAssertNil(b.textValidationError)
        XCTAssertTrue(SPICEExporter.export(circuit: bench.circuit).contains("V={"))
    }
}
