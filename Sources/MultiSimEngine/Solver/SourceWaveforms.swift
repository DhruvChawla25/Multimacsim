import Foundation

/// SPICE PULSE(V1 V2 TD TR TF PW PER): trapezoidal pulse train with exact corner times.
public struct PulseShape: Sendable, Equatable {
    public var v1: Double
    public var v2: Double
    public var delay: Double
    public var rise: Double
    public var fall: Double
    /// Time spent at V2, not counting the edges.
    public var width: Double
    /// Repetition period; zero or negative means a single pulse.
    public var period: Double

    public init(v1: Double, v2: Double, delay: Double = 0, rise: Double, fall: Double, width: Double, period: Double) {
        self.v1 = v1
        self.v2 = v2
        self.delay = max(delay, 0)
        self.rise = max(rise, 0)
        self.fall = max(fall, 0)
        self.width = max(width, 0)
        self.period = period
    }

    /// Edge time used for "ideal" square waves so the solver still has a corner to land on.
    public static let idealEdge = 1e-9

    /// Square wave between `low` and `high` at `frequency`, high for `duty` of each period, starting high.
    public static func square(low: Double, high: Double, frequency: Double, duty: Double = 0.5, delay: Double = 0) -> PulseShape {
        let period = 1.0 / max(frequency, 1e-12)
        let edge = min(idealEdge, period * 1e-3)
        let d = min(max(duty, 0.001), 0.999)
        return PulseShape(v1: low, v2: high, delay: delay, rise: edge, fall: edge,
                          width: max(period * d - edge, 0), period: period)
    }

    private var corners: [Double] { [0, rise, rise + width, rise + width + fall] }

    public func value(at t: Double) -> Double {
        guard t >= delay else { return v1 }
        var local = t - delay
        if period > 0 { local = local.truncatingRemainder(dividingBy: period) }
        if local < rise { return rise > 0 ? v1 + (v2 - v1) * local / rise : v2 }
        if local < rise + width { return v2 }
        if local < rise + width + fall { return fall > 0 ? v2 + (v1 - v2) * (local - rise - width) / fall : v1 }
        return v1
    }

    /// First corner strictly after `t`.
    public func nextBreakpoint(after t: Double) -> Double? {
        if t < delay { return delay }
        let local = t - delay
        if period > 0 {
            let k = floor(local / period)
            for cycle in [k, k + 1] {
                for c in corners {
                    let bp = delay + cycle * period + c
                    if bp > t * (1 + 1e-12) + 1e-15 { return bp }
                }
            }
            return nil
        }
        return corners.map { delay + $0 }.first { $0 > t * (1 + 1e-12) + 1e-15 }
    }
}

/// Time-domain value and discontinuities of every independent source.
enum SourceWaveforms {
    static func frequency(_ comp: CircuitComponent, fallback: Double) -> Double {
        comp.secondaryValue > 0 ? comp.secondaryValue : fallback
    }

    /// Pulse description for sources that switch, nil for smooth ones.
    static func pulse(for comp: CircuitComponent) -> PulseShape? {
        switch comp.kind {
        case .clockSource:
            return .square(low: 0, high: comp.value, frequency: frequency(comp, fallback: 1000))
        case .functionGenerator where GeneratorWaveform(rawValue: comp.modeIndex) == .square:
            let off = comp.param("offset")
            return .square(low: off - comp.value, high: off + comp.value, frequency: frequency(comp, fallback: 1000),
                           duty: comp.param("duty") / 100)
        default:
            return nil
        }
    }

    /// Instantaneous voltage (or current) of an independent source.
    static func value(_ comp: CircuitComponent, at t: Double) -> Double {
        if let p = pulse(for: comp) { return p.value(at: t) }
        switch comp.kind {
        case .amVoltage:
            // Multisim AM: v = Vc·(1 + m·sin 2πf_m t)·sin 2πf_c t
            let fc = frequency(comp, fallback: 500), fm = comp.param("modFreq"), m = comp.param("modIndex")
            return comp.value * (1 + m * sin(2 * .pi * fm * t)) * sin(2 * .pi * fc * t)
        case .fmVoltage:
            return fm(comp, at: t)
        case .exponentialVoltage:
            return exponential(comp, at: t)
        case .pwlVoltage:
            return pwl(comp, at: t)
        case .dcVoltageSource, .dcCurrentSource:
            return comp.value
        case .acVoltageSource:
            return comp.value * sin(2.0 * .pi * frequency(comp, fallback: 60) * t)
        case .functionGenerator:
            return functionGenerator(comp, at: t)
        default:
            return 0.0
        }
    }

    // MARK: - Three-phase

    /// Peak voltage of one winding: phase voltage √2·V_L/√3 for a wye, line voltage √2·V_L for a delta.
    static func threePhasePeak(_ comp: CircuitComponent) -> Double {
        let lineRMS = max(comp.value, 0)
        return comp.kind == .threePhaseWye ? 2.0.squareRoot() * lineRMS / 3.0.squareRoot() : 2.0.squareRoot() * lineRMS
    }

    /// Winding angles in degrees: A (or AB) at the set angle, then -120° and +120° (positive sequence).
    static func threePhaseAngles(_ comp: CircuitComponent) -> [Double] {
        let p = comp.param("phase")
        return [p, p - 120, p + 120]
    }

    /// Instantaneous voltage of winding `phase` (0 = A / AB, 1 = B / BC, 2 = C / CA).
    static func threePhaseValue(_ comp: CircuitComponent, phase: Int, at t: Double) -> Double {
        let f = frequency(comp, fallback: 50)
        let ang = threePhaseAngles(comp)[phase] * .pi / 180
        return threePhasePeak(comp) * sin(2 * .pi * f * t + ang)
    }

    /// SPICE source specification for the signal sources that have no hand-written export.
    static func spiceSpec(_ comp: CircuitComponent) -> String? {
        switch comp.kind {
        case .pwlVoltage:
            return pwlSpice(comp)
        case .exponentialVoltage:
            return exponentialSpice(comp)
        case .fmVoltage:
            // SPICE SFFM(VO VA FC MDI FS)
            return "SFFM(\(comp.param("offset")) \(comp.value) \(frequency(comp, fallback: 500)) \(comp.param("modIndex")) \(comp.param("modFreq")))"
        case .amVoltage:
            // ngspice AM(VA VO MF FC TD) = VA·(VO + sin MF)·sin FC
            let m = comp.param("modIndex"), fc = frequency(comp, fallback: 500)
            guard m > 0 else { return "SIN(0 \(comp.value) \(fc))" }
            return "AM(\(comp.value * m) \(1 / m) \(comp.param("modFreq")) \(fc) 0)"
        default:
            return nil
        }
    }

    /// Multisim / SPICE SFFM: v = V_off + V_a·sin(2πf_c t + β·sin 2πf_m t). Shared with the FM current source.
    static func fm(_ comp: CircuitComponent, at t: Double) -> Double {
        let fc = frequency(comp, fallback: 500)
        return comp.param("offset") + comp.value * sin(2 * .pi * fc * t + comp.param("modIndex") * sin(2 * .pi * comp.param("modFreq") * t))
    }

    /// SPICE EXP(V1 V2 TD1 TAU1 TD2 TAU2): rises from V1 toward V2 after TD1, decays back after TD2.
    static func exponential(_ comp: CircuitComponent, at t: Double) -> Double {
        let v1 = comp.param("v1"), v2 = comp.value
        let td1 = comp.param("td1"), tau1 = max(comp.param("tau1"), 1e-12)
        let td2 = max(comp.param("td2"), td1), tau2 = max(comp.param("tau2"), 1e-12)
        guard t >= td1 else { return v1 }
        var v = v1 + (v2 - v1) * (1 - exp(-(t - td1) / tau1))
        if t >= td2 { v += (v1 - v2) * (1 - exp(-(t - td2) / tau2)) }
        return v
    }

    static func exponentialBreakpoint(_ comp: CircuitComponent, after t: Double) -> Double? {
        let td1 = comp.param("td1"), td2 = max(comp.param("td2"), td1)
        return [td1, td2].first { $0 > t + max(abs(t) * 1e-12, 1e-15) }
    }

    static func exponentialSpice(_ comp: CircuitComponent) -> String {
        "EXP(\(comp.param("v1")) \(comp.value) \(comp.param("td1")) \(comp.param("tau1")) \(max(comp.param("td2"), comp.param("td1"))) \(comp.param("tau2")))"
    }

    /// Piecewise-linear source, optionally repeating every `period` seconds.
    static func pwl(_ comp: CircuitComponent, at t: Double) -> Double {
        guard let table = PWLCache.shared.table(for: comp.textValue) else { return 0 }
        let period = comp.param("period")
        guard period > 0, period >= table.duration, t > period else { return table.value(at: t) }
        return table.value(at: t.truncatingRemainder(dividingBy: period))
    }

    static func pwlBreakpoint(_ comp: CircuitComponent, after t: Double) -> Double? {
        guard let table = PWLCache.shared.table(for: comp.textValue) else { return nil }
        let period = comp.param("period")
        guard period > 0, period >= table.duration else { return table.nextCorner(after: t) }
        let cycle = floor(t / period)
        for k in [cycle, cycle + 1] {
            let base = k * period
            if let c = table.nextCorner(after: t - base) { return base + c }
            // The wrap back to the first point is a corner too.
            if base + period > t + max(abs(t) * 1e-12, 1e-15) { return base + period }
        }
        return nil
    }

    static func pwlSpice(_ comp: CircuitComponent) -> String? {
        guard let table = PWLCache.shared.table(for: comp.textValue) else { return nil }
        var pts = table.points.map { "\($0.t) \($0.v)" }
        let period = comp.param("period")
        if period > 0, period >= table.duration {
            if period > table.duration, let first = table.points.first { pts.append("\(period) \(first.v)") }
            return "PWL(\(pts.joined(separator: " "))) r=0"
        }
        return "PWL(\(pts.joined(separator: " ")))"
    }

    /// Fastest frequency a source contains, for the "too few samples per cycle" warning.
    static func highestFrequency(_ comp: CircuitComponent) -> Double? {
        if comp.kind == .fmVoltage { return frequency(comp, fallback: 500) + (comp.param("modIndex") + 1) * comp.param("modFreq") }
        if comp.kind == .amVoltage { return frequency(comp, fallback: 500) + comp.param("modFreq") }
        return fundamentalFrequency(comp)
    }

    /// Repetition frequency of a periodic source, used to size the AC meters' averaging window.
    static func fundamentalFrequency(_ comp: CircuitComponent) -> Double? {
        switch comp.kind {
        case .pwlVoltage:
            return comp.param("period") > 0 ? 1 / comp.param("period") : nil
        case .fmVoltage:
            return min(frequency(comp, fallback: 500), max(comp.param("modFreq"), 1e-3))
        case .amVoltage:
            return min(frequency(comp, fallback: 500), max(comp.param("modFreq"), 1e-3))
        case .acVoltageSource, .threePhaseWye, .threePhaseDelta:
            return frequency(comp, fallback: 50)
        case .functionGenerator, .clockSource:
            return frequency(comp, fallback: 1000)
        default:
            return nil
        }
    }

    /// Earliest waveform corner of this source strictly after `t`.
    static func nextBreakpoint(_ comp: CircuitComponent, after t: Double) -> Double? {
        if comp.kind == .pwlVoltage { return pwlBreakpoint(comp, after: t) }
        if comp.kind == .exponentialVoltage { return exponentialBreakpoint(comp, after: t) }
        if let p = pulse(for: comp) { return p.nextBreakpoint(after: t) }
        if comp.kind == .functionGenerator, GeneratorWaveform(rawValue: comp.modeIndex) == .triangle {
            // Peaks sit at phase ±d/2 around each rising zero crossing.
            let f = frequency(comp, fallback: 1000)
            let d = min(max(comp.param("duty") / 100, 0.01), 0.99)
            return periodicCorners([-d / 2, d / 2], frequency: f, after: t)
        }
        return nil
    }

    /// Next time after `t` whose phase (fraction of a period) is one of `phases`.
    static func periodicCorners(_ phases: [Double], frequency f: Double, after t: Double) -> Double? {
        guard f > 0 else { return nil }
        let k = floor(t * f)
        var best = Double.infinity
        for cycle in [k - 1, k, k + 1, k + 2] {
            for p in phases {
                let bp = (cycle + p) / f
                if bp > t + max(abs(t) * 1e-12, 1e-15) && bp < best { best = bp }
            }
        }
        return best.isFinite ? best : nil
    }

    /// Function generator: amplitude in volts peak about the DC offset. Square and triangle use the duty
    /// cycle; every shape crosses its offset going up at t = 0, so they line up with the sine.
    static func functionGenerator(_ comp: CircuitComponent, at t: Double) -> Double {
        let a = comp.value
        let off = comp.param("offset")
        let f = frequency(comp, fallback: 1000)
        let d = min(max(comp.param("duty") / 100, 0.01), 0.99)
        switch GeneratorWaveform(rawValue: comp.modeIndex) ?? .sine {
        case .sine:
            return off + a * sin(2.0 * .pi * f * t)
        case .square:
            return pulse(for: comp)?.value(at: t) ?? off
        case .triangle:
            var p = (t * f + d / 2).truncatingRemainder(dividingBy: 1.0)
            if p < 0 { p += 1 }
            return p < d ? off - a + 2 * a * p / d : off + a - 2 * a * (p - d) / (1 - d)
        }
    }
}
