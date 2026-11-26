import Foundation

/// Frequency counter instrument: times rising crossings of the trigger level (with hysteresis so noise
/// cannot double-count), interpolating each crossing between solver points for sub-step accuracy.
public enum FrequencyCounter {
    // runtimeState layout
    private static let prevV = 0, prevT = 1, armed = 2, lastRise = 3, period = 4, width = 5, isHigh = 6, count = 7, hi = 8, lo = 9
    private static let stateSize = 10
    /// How fast the auto-trigger peak detectors forget an old swing.
    static let autoLevelTimeConstant = 0.2

    public struct Reading: Equatable, Sendable {
        public let frequency: Double
        public let period: Double
        /// Time spent above the trigger level per cycle.
        public let pulseWidth: Double
        public var dutyCycle: Double { period > 0 ? pulseWidth / period : 0 }
        /// Rising edges counted since the last reset.
        public let edges: Int
    }

    /// Trigger level in use: the set level, or (auto, `stateBool`) the middle of the recent swing.
    public static func triggerLevel(_ comp: CircuitComponent) -> Double {
        guard comp.stateBool, comp.runtimeState.count == stateSize else { return comp.value }
        return (comp.runtimeState[hi] + comp.runtimeState[lo]) / 2
    }

    static func sample(_ comp: CircuitComponent, voltage v: Double, time t: Double) {
        if comp.runtimeState.count != stateSize {
            // [prevV, prevT, armed, lastRise, period, width, isHigh, edges, hi, lo]
            comp.runtimeState = [v, t, 0, -1, 0, 0, 0, 0, v, v]
            return
        }
        var s = comp.runtimeState
        // Peak detectors for the auto trigger level: jump to new extremes, relax slowly toward the signal.
        let relax = min((t - s[prevT]) / autoLevelTimeConstant, 1)
        s[hi] = max(v, s[hi] + (v - s[hi]) * relax)
        s[lo] = min(v, s[lo] + (v - s[lo]) * relax)
        let auto = comp.stateBool
        let level = auto ? (s[hi] + s[lo]) / 2 : comp.value
        let hysteresis = max(comp.param("hysteresis"), auto ? 0.05 * (s[hi] - s[lo]) : 0)
        if auto && s[hi] - s[lo] < 1e-9 { s[prevV] = v; s[prevT] = t; comp.runtimeState = s; comp.runtimeReading = 0; return }
        func crossing(_ target: Double) -> Double {
            let dv = v - s[prevV]
            return abs(dv) > 1e-300 ? s[prevT] + (target - s[prevV]) / dv * (t - s[prevT]) : t
        }
        if s[armed] > 0.5 && v >= level && s[prevV] < level {
            let tc = crossing(level)
            if s[lastRise] >= 0 { s[period] = tc - s[lastRise] }
            s[lastRise] = tc
            s[armed] = 0
            s[isHigh] = 1
            s[count] += 1
        } else if s[armed] > 0.5 && v >= level {
            // Re-armed below the band and now above it within one step.
            s[armed] = 0
        }
        if s[isHigh] > 0.5 && v < level && s[prevV] >= level {
            if s[lastRise] >= 0 { s[width] = crossing(level) - s[lastRise] }
            s[isHigh] = 0
        }
        if v < level - hysteresis { s[armed] = 1 }
        // A signal that stopped toggling reads 0 Hz after three of its own periods.
        if s[period] > 0, t - s[lastRise] > 3 * s[period] { s[period] = 0 }
        s[prevV] = v
        s[prevT] = t
        comp.runtimeState = s
        comp.runtimeReading = s[period] > 0 ? 1 / s[period] : 0
    }

    public static func reading(_ comp: CircuitComponent) -> Reading {
        guard comp.kind == .frequencyCounter, comp.runtimeState.count == stateSize else {
            return Reading(frequency: 0, period: 0, pulseWidth: 0, edges: 0)
        }
        let p = comp.runtimeState[period]
        return Reading(frequency: p > 0 ? 1 / p : 0, period: p, pulseWidth: comp.runtimeState[width],
                       edges: Int(comp.runtimeState[count]))
    }
}
