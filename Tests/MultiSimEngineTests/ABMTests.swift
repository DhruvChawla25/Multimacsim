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
