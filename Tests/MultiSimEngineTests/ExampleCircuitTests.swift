import XCTest
@testable import MultiSimEngine

/// The v6 example circuits load wired and behave as their titles promise.
final class ExampleCircuitTests: XCTestCase {
    private func part(_ c: Circuit, _ name: String) -> CircuitComponent { c.components.first { $0.designator == name }! }

    private func allPinsWired(_ c: Circuit) -> Bool {
        let wired = Set(c.wires.flatMap { [$0.startPinId, $0.endPinId] })
        return c.components.allSatisfy { $0.pins.allSatisfy { wired.contains($0.id) } }
    }

    func testThreePhaseStarLoad() throws {
        let c = LabCircuits.threePhaseStarLoad()
        XCTAssertTrue(allPinsWired(c))
        let ac = try ACSteadyStateAnalyzer.analyze(c).get()
        let expected = (400 / 3.0.squareRoot()) / Complex(100.002, 2 * .pi * 50 * 0.1).magnitude
        XCTAssertEqual(ac.phasor(for: part(c, "IA").id)!.rmsCurrent, expected, accuracy: 1e-3)
        XCTAssertLessThan(ac.phasor(for: part(c, "IN").id)!.rmsCurrent, 1e-6)
        let solver = MNASolver(circuit: c, timeStep: 1e-4)
        for _ in 0..<5000 { _ = solver.step() }
        XCTAssertEqual(part(c, "IB").runtimeReading, expected, accuracy: expected * 0.02)
        XCTAssertLessThan(part(c, "IN").runtimeReading, 0.02)
    }

    func testAMSignal() {
        let c = LabCircuits.amSignal()
        XCTAssertTrue(allPinsWired(c))
        let solver = MNASolver(circuit: c, timeStep: 1e-4)
        var peak = 0.0
        for _ in 0..<400 { _ = solver.step(); peak = max(peak, abs(part(c, "RL").runtimeVoltageDrop)) }
        XCTAssertEqual(peak, 3, accuracy: 0.05) // 2 V x (1 + 0.5)
    }

    func testCCCSMirrorCopiesTheReferenceCurrent() {
        let c = LabCircuits.cccsCurrentMirror()
        XCTAssertTrue(allPinsWired(c))
        let solver = MNASolver(circuit: c, timeStep: 1e-4)
        _ = solver.step()
        XCTAssertEqual(part(c, "Iref").runtimeReading, 0.005, accuracy: 1e-5)
        XCTAssertEqual(part(c, "Iout").runtimeReading, part(c, "Iref").runtimeReading, accuracy: 1e-6)
        part(c, "RL").value = 470 // any load: the mirror still delivers the same current
        _ = solver.step()
        XCTAssertEqual(part(c, "Iout").runtimeReading, 0.005, accuracy: 1e-5)
    }

    func testBodeLowPassCutoff() throws {
        let c = LabCircuits.bodeLowPass()
        XCTAssertTrue(allPinsWired(c))
        let pair = try XCTUnwrap(ACSweepProbe.bodePairs(part(c, "XBP1"), in: c))
        let sweep = try ACSweepAnalyzer.sweep(c, input: pair.input, output: pair.output, start: 10, stop: 1e5, pointsPerDecade: 40).get()
        XCTAssertEqual(try XCTUnwrap(sweep.lowPassCutoff), 1591.5, accuracy: 16)
    }

    func testVCOCounterReadsTheTunedFrequency() {
        let c = LabCircuits.vcoWithCounter()
        XCTAssertTrue(allPinsWired(c))
        let solver = MNASolver(circuit: c, timeStep: 1e-4)
        for _ in 0..<1000 { _ = solver.step() }
        XCTAssertEqual(part(c, "XFC1").runtimeReading, 300, accuracy: 1)
    }
}
