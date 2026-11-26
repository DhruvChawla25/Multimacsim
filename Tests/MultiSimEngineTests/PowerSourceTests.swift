import XCTest
@testable import MultiSimEngine

/// Supply rails and digital ground.
final class PowerSourceTests: XCTestCase {
    func testRailSymbolsShareOneGlobalNet() {
        let bench = TestBench()
        let vcc1 = bench.add(.vccRail, "VCC1")
        let vcc2 = bench.add(.vccRail, "VCC2")
        let r1 = bench.add(.resistor, "R1", value: 1000)
        let r2 = bench.add(.resistor, "R2", value: 1000)
        bench.wire(vcc1.pins[0], r1.pins[0]); bench.ground(r1.pins[1])
        bench.wire(vcc2.pins[0], r2.pins[0]); bench.ground(r2.pins[1])
        // A third VCC wired straight onto the first one's net must not short two ideal sources together.
        let vcc3 = bench.add(.vccRail, "VCC3")
        bench.wire(vcc3.pins[0], r1.pins[0])
        let res = bench.solver().step()
        XCTAssertFalse(res.isSingular)
        XCTAssertEqual(bench.node(vcc1.pins[0]), bench.node(vcc2.pins[0]))
        XCTAssertEqual(bench.voltage(r2.pins[0], res), 5, accuracy: 1e-9)
        XCTAssertEqual(vcc1.runtimeCurrent, 0.010, accuracy: 1e-9) // supplies both loads
    }

    func testNegativeRailAndDigitalGround() {
        let bench = TestBench()
        let vee = bench.add(.veeRail, "VEE")
        let dg = bench.add(.digitalGround, "DGND")
        let r = bench.add(.resistor, "R1", value: 500)
        bench.wire(vee.pins[0], r.pins[0]); bench.wire(r.pins[1], dg.pins[0])
        let res = bench.solver().step()
        XCTAssertEqual(bench.node(dg.pins[0]), 0)
        XCTAssertEqual(bench.voltage(r.pins[0], res), -5, accuracy: 1e-9)
        XCTAssertEqual(r.runtimeCurrent, -0.01, accuracy: 1e-9)
    }

    func testRailIsAnACShort() throws {
        let bench = TestBench()
        let v = bench.add(.acVoltageSource, "V1", value: 1, secondary: 1000)
        let r1 = bench.add(.resistor, "R1", value: 1000)
        let r2 = bench.add(.resistor, "R2", value: 1000)
        let vcc = bench.add(.vccRail, "VCC")
        bench.wire(v.pins[0], r1.pins[0]); bench.wire(r1.pins[1], r2.pins[0]); bench.wire(r2.pins[1], vcc.pins[0])
        bench.ground(v.pins[1])
        let ac = try ACSteadyStateAnalyzer.analyze(bench.circuit).get()
        XCTAssertEqual(ac.nodeVoltage(bench.node(r1.pins[1])).magnitude, 0.5, accuracy: 1e-9)
    }

    func testSPICEExportDrivesEachRailOnce() {
        let bench = TestBench()
        let a = bench.add(.vddRail, "VDD1"), b = bench.add(.vddRail, "VDD2")
        let r = bench.add(.resistor, "R1")
        bench.wire(a.pins[0], r.pins[0]); bench.ground(r.pins[1]); _ = b
        let net = SPICEExporter.export(circuit: bench.circuit)
        XCTAssertEqual(net.components(separatedBy: "VVDD ").count - 1, 1)
    }
}
