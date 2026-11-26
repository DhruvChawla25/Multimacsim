import Foundation

/// A named setting beyond a part's primary / secondary value (duty cycle, offset, rise time ...).
public struct ExtraParameter: Sendable, Equatable {
    public let key: String
    public let spec: ParameterSpec
    public let defaultValue: Double

    public init(_ key: String, _ spec: ParameterSpec, default defaultValue: Double) {
        self.key = key
        self.spec = spec
        self.defaultValue = defaultValue
    }
}

/// A free-text setting such as a PWL point list or an ABM expression.
public struct TextParameter: Sendable, Equatable {
    public let label: String
    public let defaultText: String
    public let help: String
}

extension ParameterSpec {
    /// Plain linear number.
    static func linear(_ label: String, _ unit: String, _ range: ClosedRange<Double>, slider: ClosedRange<Double>? = nil) -> ParameterSpec {
        ParameterSpec(label: label, unit: unit, range: range, sliderRange: slider ?? range, isLogarithmic: false, usesESeries: false)
    }

    /// Value that spans decades (time, frequency, resistance).
    static func log(_ label: String, _ unit: String, _ range: ClosedRange<Double>, slider: ClosedRange<Double>? = nil, eSeries: Bool = false) -> ParameterSpec {
        ParameterSpec(label: label, unit: unit, range: range, sliderRange: slider ?? range, isLogarithmic: true, usesESeries: eSeries)
    }
}

extension ComponentKind {
    /// Settings edited in the inspector below the primary / secondary values.
    public var extraParameters: [ExtraParameter] {
        switch self {
        case .functionGenerator:
            return [
                ExtraParameter("duty", .linear("Duty Cycle (square / triangle rise):", "%", 1...99), default: 50),
                ExtraParameter("offset", .linear("DC Offset:", "V", -100...100, slider: -10...10), default: 0),
            ]
        case .clockSource:
            return [
                ExtraParameter("duty", .linear("Duty Cycle:", "%", 1...99), default: 50),
                ExtraParameter("delay", .linear("Start Delay:", "s", 0...100, slider: 0...0.01), default: 0),
                ExtraParameter("edge", .log("Rise / Fall Time:", "s", 1e-12...1, slider: 1e-9...1e-3), default: 1e-9),
            ]
        case .threePhaseWye, .threePhaseDelta:
            return [ExtraParameter("phase", .linear("Phase A Angle:", "°", -360...360, slider: -180...180), default: 0)]
        case .amVoltage:
            return [
                ExtraParameter("modIndex", .linear("Modulation Index m:", "", 0...10, slider: 0...2), default: 0.5),
                ExtraParameter("modFreq", .log("Modulating Frequency:", "Hz", 1e-3...1e6, slider: 0.1...1e4, eSeries: true), default: 50),
            ]
        case .fmVoltage:
            return [
                ExtraParameter("modIndex", .linear("Modulation Index β:", "", 0...100, slider: 0...20), default: 5),
                ExtraParameter("modFreq", .log("Modulating Frequency:", "Hz", 1e-3...1e6, slider: 0.1...1e4, eSeries: true), default: 50),
                ExtraParameter("offset", .linear("DC Offset:", "V", -100...100, slider: -10...10), default: 0),
            ]
        case .exponentialVoltage:
            return [
                ExtraParameter("v1", .linear("Initial Value V1:", "V", -1000...1000, slider: -24...24), default: 0),
                ExtraParameter("td1", .linear("Rise Delay TD1:", "s", 0...100, slider: 0...0.05), default: 0),
                ExtraParameter("tau1", .log("Rise Time Constant τ1:", "s", 1e-9...100, slider: 1e-6...1), default: 1e-3),
                ExtraParameter("td2", .linear("Fall Delay TD2:", "s", 0...100, slider: 0...0.05), default: 5e-3),
                ExtraParameter("tau2", .log("Fall Time Constant τ2:", "s", 1e-9...100, slider: 1e-6...1), default: 1e-3),
            ]
        case .pwlVoltage:
            return [
                ExtraParameter("period", .linear("Repeat Period (0 = hold the last value):", "s", 0...1000, slider: 0...0.1), default: 4e-3),
            ]
        case .pulseVoltage:
            return [
                ExtraParameter("v1", .linear("Initial Value V1:", "V", -1000...1000, slider: -24...24), default: 0),
                ExtraParameter("delay", .linear("Delay Time TD:", "s", 0...100, slider: 0...0.01), default: 0),
                ExtraParameter("rise", .log("Rise Time TR:", "s", 1e-12...10, slider: 1e-9...1e-2), default: 1e-6),
                ExtraParameter("fall", .log("Fall Time TF:", "s", 1e-12...10, slider: 1e-9...1e-2), default: 1e-6),
                ExtraParameter("width", .log("Pulse Width PW:", "s", 1e-12...100, slider: 1e-6...1), default: 0.5e-3),
                ExtraParameter("period", .log("Period PER:", "s", 1e-12...1000, slider: 1e-5...1), default: 1e-3),
            ]
        case .bipolarVoltage:
            return [
                ExtraParameter("duty", .linear("Positive Duty Cycle:", "%", 1...99), default: 50),
                ExtraParameter("edge", .log("Rise / Fall Time:", "s", 1e-12...1, slider: 1e-9...1e-3), default: 1e-9),
            ]
        case .whiteNoiseVoltage:
            return [
                ExtraParameter("seed", .linear("Random Seed:", "", 0...1_000_000, slider: 0...100), default: 1),
                ExtraParameter("offset", .linear("DC Offset:", "V", -100...100, slider: -10...10), default: 0),
            ]
        case .clockCurrentSource:
            return [
                ExtraParameter("duty", .linear("Duty Cycle:", "%", 1...99), default: 50),
                ExtraParameter("edge", .log("Rise / Fall Time:", "s", 1e-12...1, slider: 1e-9...1e-3), default: 1e-9),
            ]
        case .exponentialCurrentSource:
            return [
                ExtraParameter("v1", .linear("Initial Value I1:", "A", -100...100, slider: -0.1...0.1), default: 0),
                ExtraParameter("td1", .linear("Rise Delay TD1:", "s", 0...100, slider: 0...0.05), default: 0),
                ExtraParameter("tau1", .log("Rise Time Constant τ1:", "s", 1e-9...100, slider: 1e-6...1), default: 1e-3),
                ExtraParameter("td2", .linear("Fall Delay TD2:", "s", 0...100, slider: 0...0.05), default: 5e-3),
                ExtraParameter("tau2", .log("Fall Time Constant τ2:", "s", 1e-9...100, slider: 1e-6...1), default: 1e-3),
            ]
        case .fmCurrentSource:
            return [
                ExtraParameter("modIndex", .linear("Modulation Index β:", "", 0...100, slider: 0...20), default: 5),
                ExtraParameter("modFreq", .log("Modulating Frequency:", "Hz", 1e-3...1e6, slider: 0.1...1e4, eSeries: true), default: 50),
                ExtraParameter("offset", .linear("DC Offset:", "A", -100...100, slider: -0.1...0.1), default: 0),
            ]
        case .pwlCurrentSource:
            return [
                ExtraParameter("period", .linear("Repeat Period (0 = hold the last value):", "s", 0...1000, slider: 0...0.1), default: 4e-3),
            ]
        default:
            return []
        }
    }

    /// Free-text setting, if the part has one.
    public var textParameter: TextParameter? {
        switch self {
        case .abmVoltage, .abmCurrent:
            return TextParameter(label: self == .abmVoltage ? "Output voltage V(+,-) =" : "Output current (out of OUT) =",
                                 defaultText: self == .abmVoltage ? "5*sin(2*pi*50*time)" : "1m*sin(2*pi*50*time)",
                                 help: "Use V(3) for node 3, V(R1) for the voltage across R1, V(a,b) for a difference, I(R1) for a part's current, time, pi, + - * / ^ and sin cos tan exp log log10 abs sqrt min max limit(x,lo,hi).")
        case .pwlCurrentSource:
            return TextParameter(label: "Points (time current, one pair per line):", defaultText: "0 0\n1m 10m\n2m 10m\n3m 0",
                                 help: "Straight lines join the points. Current in amps: 10m = 10 mA. Times: 1m = 1 ms.")
        case .pwlVoltage:
            return TextParameter(label: "Points (time value, one pair per line):", defaultText: "0 0\n1m 5\n2m 5\n3m 0",
                                 help: "Straight lines join the points. Use engineering suffixes: 1m = 1 ms, 2.5u = 2.5 µs.")
        default:
            return nil
        }
    }
}

extension ComponentKind {
    /// Sources whose text setting is a PWL point list.
    public var usesPWLText: Bool { self == .pwlVoltage || self == .pwlCurrentSource }
}

extension CircuitComponent {
    /// Value of a named setting, falling back to the kind's default.
    public func param(_ key: String) -> Double {
        if let v = parameters[key], v.isFinite { return v }
        return kind.extraParameters.first { $0.key == key }?.defaultValue ?? 0
    }

    /// The free-text setting, or the kind's default text when nothing was entered.
    public var textValue: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (kind.textParameter?.defaultText ?? "") : text
    }

    /// Problem with the free-text setting, or nil when it is usable.
    public var textValidationError: String? {
        switch kind {
        case _ where kind.usesPWLText:
            if case .failure(let e) = PWLTable.parse(textValue) { return e.description }
            return nil
        case .abmVoltage, .abmCurrent:
            if case .failure(let e) = Expression.parse(textValue) { return e.description }
            return nil
        default:
            return nil
        }
    }
}
