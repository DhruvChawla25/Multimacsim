import XCTest
@testable import MultiSimEngine

/// Current-controlled sources sense their control current through a 0 V branch, as SPICE does.
final class ControlledSourceTests: XCTestCase {
    /// 5 V across 1 kΩ through the sense branch: i_s = 5 mA.
    private func sensed(_ kind: ComponentKind, gain: Double) -> (TestBench, CircuitComponent, CircuitComponent) {
        let bench = TestBench()
        let v = bench.add(.dcVoltageSource, "V1", value: 5)
        let r = bench.add(.resistor, "R1", value: 1000)
        let dep = bench.add(kind, "X1", value: gain)
        let load = bench.add(.resistor, "RL", value: 200)
        bench.wire(v.pins[0], dep.pins[2]); bench.wire(dep.pins[3], r.pins[0])
        bench.ground(r.pins[1], v.pins[1], dep.pins[1], load.pins[1])
        bench.wire(dep.pins[0], load.pins[0])
        return (bench, dep, load)
    }

    func testCCVSOutputsTransresistanceTimesSenseCurrent() {
        let (bench, dep, load) = sensed(.ccvs, gain: 400)
        let res = bench.solver().step()
        XCTAssertEqual(bench.voltage(load.pins[0], res), 400 * 0.005, accuracy: 1e-9)
        XCTAssertEqual(dep.runtimeState.first!, 0.005, accuracy: 1e-12)
        XCTAssertEqual(dep.runtimeCurrent, 2.0 / 200, accuracy: 1e-9)
    }

    func testCCCSPushesGainTimesSenseCurrentOutOfOutPlus() {
        let (bench, dep, load) = sensed(.cccs, gain: 20)
        let res = bench.solver().step()
        XCTAssertEqual(load.runtimeCurrent, 20 * 0.005, accuracy: 1e-9)
        XCTAssertEqual(bench.voltage(load.pins[0], res), 20 * 0.005 * 200, accuracy: 1e-6)
        XCTAssertEqual(dep.runtimeCurrent, 0.1, accuracy: 1e-9)
    }

    func testCurrentControlledSourcesInPhasorAnalysis() throws {
        let bench = TestBench()
        let v = bench.add(.acVoltageSource, "V1", value: 1, secondary: 1000)
        let c = bench.add(.capacitor, "C1", value: 1e-6)
        let f = bench.add(.cccs, "F1", value: 3)
        let load = bench.add(.resistor, "RL", value: 100)
        bench.wire(v.pins[0], f.pins[2]); bench.wire(f.pins[3], c.pins[0])
        bench.ground(c.pins[1], v.pins[1], f.pins[1], load.pins[1])
        bench.wire(f.pins[0], load.pins[0])
        let ac = try ACSteadyStateAnalyzer.analyze(bench.circuit).get()
        let ic = 2 * Double.pi * 1000 * 1e-6 // |I_C| for 1 V peak
        XCTAssertEqual(ac.phasor(for: load.id)!.peakCurrent, 3 * ic, accuracy: 1e-9)
        // Capacitor current leads the source voltage by 90°.
        XCTAssertEqual(ac.phasor(for: load.id)!.current.angleDegrees, 90, accuracy: 1e-6)
        XCTAssertTrue(SPICEExporter.export(circuit: bench.circuit).contains("VF1_SENSE"))
    }
}
