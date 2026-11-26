import XCTest
@testable import MultiSimEngine

/// Newton-Raphson robustness: junction limiting, homotopies and SPICE-style convergence.
final class NewtonTests: XCTestCase {

    private func diodeChain(supply: Double, count: Int) -> (TestBench, [CircuitComponent]) {
        let bench = TestBench()
        let v = bench.add(.dcVoltageSource, "V1", value: supply)
        let r = bench.add(.resistor, "R1", value: 100)
        bench.wire(v.pins[0], r.pins[0])
        var prev = r.pins[1]
        var diodes: [CircuitComponent] = []
        for k in 0..<count {
            let d = bench.add(.diode, "D\(k)")
            bench.wire(prev, d.pins[0])
            prev = d.pins[1]
            diodes.append(d)
        }
        bench.ground(v.pins[1], prev)
        return (bench, diodes)
    }

    func testJunctionLimitingConvergesFromColdStart() {
        let (bench, diodes) = diodeChain(supply: 100, count: 3)
        let res = bench.solver().step()
        XCTAssertTrue(res.converged)
        XCTAssertLessThan(res.iterations, 100)
        let vd = diodes[0].runtimeVoltageDrop
        XCTAssertGreaterThan(vd, 0.7)
        XCTAssertLessThan(vd, 0.95)
        // KCL: the series current is the diode current.
        XCTAssertEqual(diodes[0].runtimeCurrent, (100 - 3 * vd) / 100, accuracy: 0.002)
    }

    func testPnjlimCompressesLargeSteps() {
        let (v, limited) = MNASolver.limitJunctionVoltage(5.0, old: 0.6, vt: 0.02585, vcrit: 0.6)
        XCTAssertTrue(limited)
        XCTAssertLessThan(v, 0.8)
        let (same, no) = MNASolver.limitJunctionVoltage(0.61, old: 0.6, vt: 0.02585, vcrit: 0.6)
        XCTAssertFalse(no)
        XCTAssertEqual(same, 0.61)
    }

    func testOperatingPointFallsBackToHomotopy() {
        let (bench, diodes) = diodeChain(supply: 1000, count: 4)
        let solver = bench.solver()
        solver.tolerances.maxIterations = 5 // too few for a cold start: forces gmin / source stepping
        let (res, aid) = solver.operatingPoint(apply: true)
        XCTAssertTrue(res.converged)
        XCTAssertNotEqual(aid, .none, "iterations \(res.iterations)")
        XCTAssertGreaterThan(diodes[0].runtimeVoltageDrop, 0.8)
        XCTAssertLessThan(diodes[0].runtimeVoltageDrop, 1.1)
    }

    func testOperatingPointTreatsCapacitorOpenAndInductorShort() {
        let bench = TestBench()
        let v = bench.add(.dcVoltageSource, "V1", value: 12)
        let r1 = bench.add(.resistor, "R1", value: 1000)
        let l = bench.add(.inductor, "L1", value: 1)
        let r2 = bench.add(.resistor, "R2", value: 2000)
        let c = bench.add(.capacitor, "C1", value: 1e-6)
        bench.wire(v.pins[0], r1.pins[0]); bench.wire(r1.pins[1], l.pins[0])
        bench.wire(l.pins[1], r2.pins[0]); bench.wire(l.pins[1], c.pins[0])
        bench.ground(v.pins[1], r2.pins[1], c.pins[1])
        let solver = bench.solver()
        let (res, _) = solver.operatingPoint(apply: true)
        XCTAssertEqual(bench.voltage(c.pins[0], res), 8.0, accuracy: 1e-6)
        XCTAssertEqual(l.runtimeCurrent, 0.004, accuracy: 1e-9)
        // Starting the transient from the operating point: nothing moves.
        let next = solver.step()
        XCTAssertEqual(bench.voltage(c.pins[0], next), 8.0, accuracy: 1e-6)
    }

    func testZenerRegulates() {
        let bench = TestBench()
        let v = bench.add(.dcVoltageSource, "V1", value: 12)
        let r = bench.add(.resistor, "R1", value: 1000)
        let z = bench.add(.zenerDiode, "Z1", secondary: 5.1)
        bench.wire(v.pins[0], r.pins[0]); bench.wire(r.pins[1], z.pins[1]) // cathode to the supply
        bench.ground(v.pins[1], z.pins[0])
        let res = bench.solver().step()
        XCTAssertTrue(res.converged)
        let vz = bench.voltage(z.pins[1], res)
        XCTAssertGreaterThan(vz, 5.1)
        XCTAssertLessThan(vz, 5.35)
    }

    func testOpAmpInvertingAmplifierConverges() {
        let bench = TestBench()
        let v = bench.add(.dcVoltageSource, "V1", value: 0.5)
        let rin = bench.add(.resistor, "Rin", value: 1000)
        let rf = bench.add(.resistor, "Rf", value: 10_000)
        let u = bench.add(.opAmp, "U1")
        bench.wire(v.pins[0], rin.pins[0]); bench.wire(rin.pins[1], u.pins[0])
        bench.wire(u.pins[0], rf.pins[0]); bench.wire(rf.pins[1], u.pins[2])
        bench.ground(v.pins[1], u.pins[1])
        let res = bench.solver().step()
        XCTAssertTrue(res.converged)
        XCTAssertEqual(bench.voltage(u.pins[2], res), -5.0, accuracy: 1e-3)
    }

    func testLEDDropsItsColourVoltage() {
        let bench = TestBench()
        let v = bench.add(.dcVoltageSource, "V1", value: 5)
        let r = bench.add(.resistor, "R1", value: 220)
        let d = bench.add(.led, "LED1")
        bench.wire(v.pins[0], r.pins[0]); bench.wire(r.pins[1], d.pins[0])
        bench.ground(v.pins[1], d.pins[1])
        let res = bench.solver().step()
        XCTAssertTrue(res.converged)
        XCTAssertEqual(d.runtimeVoltageDrop, LEDColor.red.forwardVoltage, accuracy: 0.15)
        XCTAssertGreaterThan(d.runtimeCurrent, 0.01)
    }
}
