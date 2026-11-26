import Foundation

/// A complex number for phasor arithmetic.
public struct Complex: Equatable {
    public var re: Double
    public var im: Double

    public init(_ re: Double, _ im: Double = 0) {
        self.re = re
        self.im = im
    }

    public static let zero = Complex(0, 0)

    public var magnitude: Double { (re * re + im * im).squareRoot() }
    /// Angle in degrees, in (-180, 180].
    public var angleDegrees: Double { atan2(im, re) * 180.0 / .pi }

    public static func + (a: Complex, b: Complex) -> Complex { Complex(a.re + b.re, a.im + b.im) }
    public static func - (a: Complex, b: Complex) -> Complex { Complex(a.re - b.re, a.im - b.im) }
    public static func * (a: Complex, b: Complex) -> Complex {
        Complex(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re)
    }
    public static func / (a: Complex, b: Complex) -> Complex {
        let d = b.re * b.re + b.im * b.im
        return Complex((a.re * b.re + a.im * b.im) / d, (a.im * b.re - a.re * b.im) / d)
    }
    public static prefix func - (a: Complex) -> Complex { Complex(-a.re, -a.im) }
    public static func += (a: inout Complex, b: Complex) { a = a + b }
    public static func -= (a: inout Complex, b: Complex) { a = a - b }
}

/// Steady-state phasor of one part: voltage across pin 0 -> pin 1 and current entering pin 0.
/// Magnitudes are peak values; angles are relative to the reference source voltage.
public struct ComponentPhasor: Identifiable {
    public let id: UUID
    public let designator: String
    public let kind: ComponentKind
    public let voltage: Complex
    public let current: Complex

    public var peakVoltage: Double { voltage.magnitude }
    public var rmsVoltage: Double { voltage.magnitude / 2.0.squareRoot() }
    public var peakCurrent: Double { current.magnitude }
    public var rmsCurrent: Double { current.magnitude / 2.0.squareRoot() }
    /// Average power dissipated (W), using peak phasors: P = ½ Re(V·I*).
    public var averagePower: Double { 0.5 * (voltage.re * current.re + voltage.im * current.im) }
}

/// The impedance a part presents at the analysis frequency.
public struct ReactanceEntry: Identifiable {
    public let id: UUID
    public let designator: String
    public let kind: ComponentKind
    /// R in ohms, L in henries, C in farads.
    public let value: Double
    /// Complex impedance Z = R + jX.
    public let impedance: Complex
}

/// Complete AC steady-state solution of a linear circuit driven at one frequency.
public struct ACSteadyStateResult {
    public let frequency: Double
    public var omega: Double { 2.0 * .pi * frequency }
    /// The source every phase angle is measured against.
    public let referenceSource: ComponentPhasor
    /// Current delivered by the reference source (flowing out of its + terminal).
    public let sourceCurrent: Complex
    public let parts: [ComponentPhasor]
    public let reactances: [ReactanceEntry]

    /// Impedance seen by the reference source.
    public var totalImpedance: Complex { referenceSource.voltage / sourceCurrent }
    /// Phase of the source current relative to the source voltage (negative = lagging).
    public var currentPhaseDegrees: Double { sourceCurrent.angleDegrees - referenceSource.voltage.angleDegrees }
    public var powerFactor: Double { cos(totalImpedance.angleDegrees * .pi / 180.0) }
    public var apparentPower: Double { 0.5 * referenceSource.voltage.magnitude * sourceCurrent.magnitude }
    public var activePower: Double {
        let v = referenceSource.voltage, i = sourceCurrent
        return 0.5 * (v.re * i.re + v.im * i.im)
    }
    public var reactivePower: Double {
        let v = referenceSource.voltage, i = sourceCurrent
        return 0.5 * (v.im * i.re - v.re * i.im)
    }

    public func phasor(for id: UUID) -> ComponentPhasor? { parts.first { $0.id == id } }
}

public enum ACAnalysisError: Error, Equatable, CustomStringConvertible {
    case noACSource
    case mixedFrequencies
    case unsupportedPart(String)
    case singular

    public var description: String {
        switch self {
        case .noACSource: return "Add an AC voltage source to run AC steady-state analysis."
        case .mixedFrequencies: return "Every AC source must run at the same frequency."
        case .unsupportedPart(let name): return "\(name) is non-linear or time-varying, so phasor analysis does not apply."
        case .singular: return "The circuit has a floating node or a shorted source."
        }
    }
}

/// Exact sinusoidal steady-state analysis using complex Modified Nodal Analysis.
///
/// Every R, L and C becomes an impedance (R, jωL, 1/jωC), every AC source a phasor,
/// and the resulting complex linear system is solved directly - no time stepping and
/// no start-up transient, so the numbers match a hand calculation.
public enum ACSteadyStateAnalyzer {
    public static func analyze(_ circuit: Circuit) -> Result<ACSteadyStateResult, ACAnalysisError> {
        let acSources = circuit.components.filter { $0.kind == .acVoltageSource }
        guard let reference = acSources.first else { return .failure(.noACSource) }
        let frequency = reference.secondaryValue > 0 ? reference.secondaryValue : 50.0
        if acSources.contains(where: { abs(($0.secondaryValue > 0 ? $0.secondaryValue : 50.0) - frequency) > 1e-9 }) {
            return .failure(.mixedFrequencies)
        }
        let omega = 2.0 * .pi * frequency

        let probeSolver = MNASolver(circuit: circuit)
        let pinToNode = probeSolver.pinToNode
        let nodeCount = probeSolver.totalNodes
        func nodes(_ c: CircuitComponent) -> [Int] { c.pins.map { pinToNode[$0.id] ?? 0 } }

        // Classify every part before building the matrix.
        var impedances: [UUID: Complex] = [:]
        // Wattmeters: current coil impedance (pins 0-1) and pressure coil impedance (pins 2-3).
        var wattmeters: [UUID: (cc: Complex, pc: Complex)] = [:]
        var sources: [CircuitComponent] = []
        var reactances: [ReactanceEntry] = []
        for comp in circuit.components {
            switch comp.kind {
            case .ground, .probe:
                continue
            case .acVoltageSource, .dcVoltageSource:
                // A DC source carries no AC signal: it is a 0 V phasor (a short for AC).
                sources.append(comp)
            case .resistor:
                let z = Complex(max(comp.value, 1e-6))
                impedances[comp.id] = z
                reactances.append(ReactanceEntry(id: comp.id, designator: comp.designator, kind: comp.kind, value: comp.value, impedance: z))
            case .inductor:
                let z = Complex(0, omega * max(comp.value, 1e-12))
                impedances[comp.id] = z
                reactances.append(ReactanceEntry(id: comp.id, designator: comp.designator, kind: comp.kind, value: comp.value, impedance: z))
            case .capacitor, .electrolyticCapacitor, .trimmerCapacitor:
                let z = Complex(0, -1.0 / (omega * max(comp.value, 1e-15)))
                impedances[comp.id] = z
                reactances.append(ReactanceEntry(id: comp.id, designator: comp.designator, kind: comp.kind, value: comp.value, impedance: z))
            case .wattmeter:
                let cc = max(comp.value > 0 ? comp.value : 0.05, 1e-4)
                let pc = comp.secondaryValue > 0 ? comp.secondaryValue : 1e6
                wattmeters[comp.id] = (Complex(cc), Complex(pc))
            case .switchSPST, .rheostat, .lamp, .fuse, .thermistor, .photoResistor,
                 .ammeter, .voltmeter, .galvanometer, .multimeter:
                guard comp.kind != .multimeter || MeterMode(rawValue: comp.modeIndex) != .resistance,
                      let r = probeSolver.resistance(of: comp) else {
                    return .failure(.unsupportedPart(comp.designator))
                }
                impedances[comp.id] = Complex(r)
            default:
                return .failure(.unsupportedPart(comp.designator))
            }
        }

        // Complex MNA: node rows first, then one row per voltage source.
        let size = nodeCount + sources.count
        guard size > 0 else { return .failure(.singular) }
        var a = [[Complex]](repeating: [Complex](repeating: .zero, count: size), count: size)
        var b = [Complex](repeating: .zero, count: size)

        func stamp(_ n1: Int, _ n2: Int, _ z: Complex) {
            let y = Complex(1) / z
            if n1 > 0 { a[n1 - 1][n1 - 1] += y }
            if n2 > 0 { a[n2 - 1][n2 - 1] += y }
            if n1 > 0 && n2 > 0 {
                a[n1 - 1][n2 - 1] -= y
                a[n2 - 1][n1 - 1] -= y
            }
        }
        for comp in circuit.components {
            let n = nodes(comp)
            if let z = impedances[comp.id] {
                stamp(n.count > 0 ? n[0] : 0, n.count > 1 ? n[1] : 0, z)
            } else if let w = wattmeters[comp.id], n.count >= 4 {
                stamp(n[0], n[1], w.cc)
                stamp(n[2], n[3], w.pc)
            }
        }

        for (k, src) in sources.enumerated() {
            let row = nodeCount + k
            let n = nodes(src)
            let np = n[0], nm = n[1]
            if np > 0 { a[np - 1][row] += Complex(1); a[row][np - 1] += Complex(1) }
            if nm > 0 { a[nm - 1][row] -= Complex(1); a[row][nm - 1] -= Complex(1) }
            // The source waveform is value * sin(ωt): a phasor of `value` at 0°.
            b[row] = src.kind == .acVoltageSource ? Complex(src.value) : .zero
        }

        guard let x = solve(a, b) else { return .failure(.singular) }
        func v(_ node: Int) -> Complex { node == 0 ? .zero : x[node - 1] }

        var parts: [ComponentPhasor] = []
        var referencePhasor: ComponentPhasor?
        var referenceCurrent = Complex.zero
        for comp in circuit.components {
            let n = nodes(comp)
            guard n.count >= 2 else { continue }
            let drop = v(n[0]) - v(n[1])
            if let w = wattmeters[comp.id], n.count >= 4 {
                // Voltage = pressure-coil voltage, current = current-coil current,
                // so `averagePower` is exactly what the wattmeter reads.
                let ccCurrent = (v(n[0]) - v(n[1])) / w.cc
                parts.append(ComponentPhasor(id: comp.id, designator: comp.designator, kind: comp.kind,
                                             voltage: v(n[2]) - v(n[3]), current: ccCurrent))
            } else if let z = impedances[comp.id] {
                parts.append(ComponentPhasor(id: comp.id, designator: comp.designator, kind: comp.kind, voltage: drop, current: drop / z))
            } else if let k = sources.firstIndex(where: { $0.id == comp.id }) {
                // MNA's source current flows into the + node; the delivered current is its negative.
                let delivered = -x[nodeCount + k]
                let phasor = ComponentPhasor(id: comp.id, designator: comp.designator, kind: comp.kind, voltage: drop, current: delivered)
                parts.append(phasor)
                if comp.id == reference.id {
                    referencePhasor = phasor
                    referenceCurrent = delivered
                }
            }
        }

        guard let refPhasor = referencePhasor, referenceCurrent.magnitude > 1e-15 else { return .failure(.singular) }
        return .success(ACSteadyStateResult(
            frequency: frequency,
            referenceSource: refPhasor,
            sourceCurrent: referenceCurrent,
            parts: parts,
            reactances: reactances
        ))
    }

    /// Gaussian elimination with partial pivoting over complex numbers.
    static func solve(_ matrix: [[Complex]], _ rhs: [Complex]) -> [Complex]? {
        var a = matrix
        var b = rhs
        let n = b.count
        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<max(n, col + 1) where a[r][col].magnitude > a[pivot][col].magnitude {
                pivot = r
            }
            guard a[pivot][col].magnitude > 1e-14 else { return nil }
            if pivot != col {
                a.swapAt(pivot, col)
                b.swapAt(pivot, col)
            }
            for r in (col + 1)..<max(n, col + 1) {
                let f = a[r][col] / a[col][col]
                if f.magnitude == 0 { continue }
                for c in col..<n { a[r][c] -= f * a[col][c] }
                b[r] -= f * b[col]
            }
        }
        var x = [Complex](repeating: .zero, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for c in (r + 1)..<max(n, r + 1) { s -= a[r][c] * x[c] }
            x[r] = s / a[r][r]
        }
        return x
    }
}
