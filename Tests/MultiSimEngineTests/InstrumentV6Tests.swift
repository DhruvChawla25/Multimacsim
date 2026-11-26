import XCTest
@testable import MultiSimEngine

/// v6 instruments: function generator, frequency counter, Bode plotter.
final class FunctionGeneratorTests: XCTestCase {
    private func generator(_ wave: GeneratorWaveform, amp: Double = 2, f: Double = 1000, duty: Double = 50, offset: Double = 0) -> CircuitComponent {
        CircuitComponent(kind: .functionGenerator, designator: "XFG1", value: amp, secondaryValue: f,
                         modeIndex: wave.rawValue, parameters: ["duty": duty, "offset": offset])
    }

    func testSineHasAmplitudeInVoltsPeakAndOffset() {
        let g = generator(.sine, amp: 2, offset: 1)
        XCTAssertEqual(SourceWaveforms.value(g, at: 0.25e-3), 3, accuracy: 1e-9)
        XCTAssertEqual(SourceWaveforms.value(g, at: 0.75e-3), -1, accuracy: 1e-9)
    }

    func testTriangleRepeatsAtTheSetFrequency() {
        let g = generator(.triangle, amp: 2)
        XCTAssertEqual(SourceWaveforms.value(g, at: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(SourceWaveforms.value(g, at: 0.25e-3), 2, accuracy: 1e-9)
        XCTAssertEqual(SourceWaveforms.value(g, at: 0.75e-3), -2, accuracy: 1e-9)
        XCTAssertEqual(SourceWaveforms.value(g, at: 1.25e-3), 2, accuracy: 1e-9)
        XCTAssertEqual(SourceWaveforms.nextBreakpoint(g, after: 0)!, 0.25e-3, accuracy: 1e-12)
    }

    func testSquareDutyCycle() {
        let g = generator(.square, amp: 5, duty: 20, offset: 5) // 0 ... 10 V, high 20 %
        XCTAssertEqual(SourceWaveforms.value(g, at: 0.1e-3), 10, accuracy: 1e-9)
        XCTAssertEqual(SourceWaveforms.value(g, at: 0.3e-3), 0, accuracy: 1e-9)
        var high = 0
        for k in 0..<1000 where SourceWaveforms.value(g, at: Double(k) * 1e-6 + 0.5e-6) > 5 { high += 1 }
        XCTAssertEqual(high, 200, accuracy: 2)
    }

    func testSawtoothFromTriangleDuty() {
        let g = generator(.triangle, amp: 1, duty: 99)
        // Rises nearly the whole period, snaps back in 1 %.
        XCTAssertEqual(SourceWaveforms.value(g, at: 0.25e-3), 0.5, accuracy: 0.02)
    }
}

final class FrequencyCounterTests: XCTestCase {
    private func count(_ src: CircuitComponent, dt: Double, steps: Int, level: Double = 0, auto: Bool = true) -> CircuitComponent {
        let bench = TestBench()
        bench.components.append(src)
        let fc = bench.add(.frequencyCounter, "XFC1", value: level, closed: auto)
        let r = bench.add(.resistor, "R1", value: 1000)
        bench.wire(src.pins[0], r.pins[0]); bench.wire(src.pins[0], fc.pins[0]); bench.ground(src.pins[1], r.pins[1])
        let solver = bench.solver(dt: dt)
        for _ in 0..<steps { _ = solver.step() }
        return fc
    }

    func testCountsASineToSubStepAccuracy() {
        let g = CircuitComponent(kind: .functionGenerator, designator: "XFG1", value: 1, secondaryValue: 1234)
        let fc = count(g, dt: 1e-5, steps: 2000) // 81 samples per cycle, crossings interpolated
        XCTAssertEqual(fc.runtimeReading, 1234, accuracy: 1234 * 1e-3)
        XCTAssertEqual(FrequencyCounter.reading(fc).edges, 24, accuracy: 1)
    }

    func testPulseWidthAndDutyOfAClock() {
        let clk = CircuitComponent(kind: .clockSource, designator: "CLK", value: 5, secondaryValue: 500, parameters: ["duty": 25])
        let fc = count(clk, dt: 1e-4, steps: 200, level: 2.5, auto: false)
        let autoFC = count(clk, dt: 1e-4, steps: 200) // a 0 ... 5 V clock never crosses 0 V: auto level finds 2.5 V
        XCTAssertEqual(autoFC.runtimeReading, 500, accuracy: 0.5)
        XCTAssertEqual(FrequencyCounter.triggerLevel(autoFC), 2.5, accuracy: 0.1)
        let r = FrequencyCounter.reading(fc)
        XCTAssertEqual(r.frequency, 500, accuracy: 0.5)
        XCTAssertEqual(r.dutyCycle, 0.25, accuracy: 0.01)
    }

    func testStoppedSignalReadsZero() {
        let v = CircuitComponent(kind: .dcVoltageSource, designator: "V1", value: 3)
        XCTAssertEqual(count(v, dt: 1e-4, steps: 100).runtimeReading, 0)
    }
}
