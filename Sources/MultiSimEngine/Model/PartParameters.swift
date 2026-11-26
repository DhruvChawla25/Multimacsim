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
        default:
            return []
        }
    }

    /// Free-text setting, if the part has one.
    public var textParameter: TextParameter? {
        switch self {
        default:
            return nil
        }
    }
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
        nil
    }
}
