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
