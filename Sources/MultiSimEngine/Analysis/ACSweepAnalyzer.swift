import Foundation

/// A voltage the sweep measures: V(plus) − V(minus), node numbers from the solver (0 = ground).
public struct ACSweepProbe: Equatable, Hashable, Sendable {
    public let plus: Int
    public let minus: Int
    public let label: String

    public init(plus: Int, minus: Int = 0, label: String) {
        self.plus = plus
        self.minus = minus
        self.label = label
    }

    /// The voltage across a part (pin 0 minus pin 1), or on its only pin.
    public static func across(_ comp: CircuitComponent, in circuit: Circuit) -> ACSweepProbe {
        let map = circuit.resolveNodes().pinToNode
        let n = comp.pins.map { map[$0.id] ?? 0 }
        return ACSweepProbe(plus: n.first ?? 0, minus: n.count > 1 ? n[1] : 0, label: "V(\(comp.designator))")
    }
}

public struct ACSweepPoint: Equatable, Sendable {
    public let frequency: Double
    /// H = V(out) / V(in) at this frequency.
    public let response: Complex
    public var magnitudeDB: Double { 20 * log10(max(response.magnitude, 1e-300)) }
    /// Phase in degrees, unwrapped along the sweep so it does not jump by 360°.
    public let phaseDegrees: Double
}

public struct ACSweepResult: Sendable {
    public let points: [ACSweepPoint]
    public let input: ACSweepProbe
    public let output: ACSweepProbe

    /// Frequency where the magnitude first falls 3 dB below its value at the start of the sweep.
    public var lowPassCutoff: Double? { crossing(of: (points.first?.magnitudeDB ?? 0) - 3.0103) }

    /// Linear interpolation (in log f) of where the magnitude crosses `db`.
    public func crossing(of db: Double) -> Double? {
        for (a, b) in zip(points, points.dropFirst()) where (a.magnitudeDB - db) * (b.magnitudeDB - db) <= 0 && a.magnitudeDB != b.magnitudeDB {
            let f = (db - a.magnitudeDB) / (b.magnitudeDB - a.magnitudeDB)
            return pow(10, log10(a.frequency) + f * (log10(b.frequency) - log10(a.frequency)))
        }
        return nil
    }

    /// Response at the sweep point nearest `frequency`.
    public func nearest(_ frequency: Double) -> ACSweepPoint? {
        points.min { abs(log10($0.frequency / frequency)) < abs(log10($1.frequency / frequency)) }
    }
}

/// AC sweep (SPICE `.AC DEC`): solves the phasor circuit at log-spaced frequencies with every AC source
/// driven at that frequency. Non-linear parts are linearised at the DC operating point first.
public enum ACSweepAnalyzer {
    public static func frequencies(start: Double, stop: Double, pointsPerDecade: Int) -> [Double] {
        let lo = max(min(start, stop), 1e-6), hi = max(start, stop)
        let n = max(pointsPerDecade, 1)
        let decades = log10(hi / lo)
        let count = max(Int((decades * Double(n)).rounded()), 1)
        return (0...count).map { lo * pow(10, decades * Double($0) / Double(count)) }
    }

    public static func sweep(_ circuit: Circuit, input: ACSweepProbe, output: ACSweepProbe,
                             start: Double = 10, stop: Double = 100_000, pointsPerDecade: Int = 20) -> Result<ACSweepResult, ACAnalysisError> {
        // Small-signal operating point (only matters if the circuit has non-linear parts).
        let solver = MNASolver(circuit: circuit, timeStep: 1e-4)
        let op = solver.operatingPoint(apply: false).result.nodeVoltages
        var points: [ACSweepPoint] = []
        var lastPhase: Double?
        for f in frequencies(start: start, stop: stop, pointsPerDecade: pointsPerDecade) {
            switch ACSteadyStateAnalyzer.analyze(circuit, frequency: f, linearizedAt: op) {
            case .failure(let e):
                return .failure(e)
            case .success(let ac):
                let vin = ac.nodeVoltage(input.plus) - ac.nodeVoltage(input.minus)
                let vout = ac.nodeVoltage(output.plus) - ac.nodeVoltage(output.minus)
                let h = vin.magnitude > 1e-300 ? vout / vin : Complex(0)
                var phase = h.angleDegrees
                if let last = lastPhase {
                    while phase - last > 180 { phase -= 360 }
                    while phase - last < -180 { phase += 360 }
                }
                lastPhase = phase
                points.append(ACSweepPoint(frequency: f, response: h, phaseDegrees: phase))
            }
        }
        return .success(ACSweepResult(points: points, input: input, output: output))
    }
}
