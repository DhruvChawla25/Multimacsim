import Foundation

/// A complex number for phasor arithmetic.
public struct Complex: Equatable, Sendable {
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
    /// Peak phasor of every node voltage (node 0 = ground).
    public let nodeVoltages: [Int: Complex]
    /// Per-phase report of every three-phase source.
    public let threePhase: [ThreePhaseReport]

    /// Impedance seen by the reference source.
    public var totalImpedance: Complex {
        sourceCurrent.magnitude < 1e-15 ? Complex(.infinity, 0) : referenceSource.voltage / sourceCurrent
    }
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
    public func nodeVoltage(_ node: Int) -> Complex { node == 0 ? .zero : nodeVoltages[node] ?? .zero }
}

/// Phase-by-phase quantities of one three-phase source (peak phasors).
public struct ThreePhaseReport: Identifiable {
    public let id: UUID
    public let designator: String
    public let isWye: Bool
    /// Line currents delivered out of terminals A, B, C.
    public let lineCurrents: [Complex]
    /// Phase-to-neutral voltages (wye) or winding voltages AB, BC, CA (delta).
    public let phaseVoltages: [Complex]
    /// Line-to-line voltages AB, BC, CA.
    public let lineVoltages: [Complex]
    /// Current returning through the neutral terminal (wye only, zero for delta).
    public var neutralCurrent: Complex { isWye ? lineCurrents.reduce(.zero, +) : .zero }
    /// Total complex power S = P + jQ delivered (from peak phasors: ½ Σ V·I*).
    public let complexPower: Complex
    /// Largest line current over smallest; 1 for a balanced load.
    public var currentUnbalance: Double {
        let m = lineCurrents.map(\.magnitude)
        guard let lo = m.min(), let hi = m.max(), lo > 1e-15 else { return .infinity }
        return hi / lo
    }
}

public enum ACAnalysisError: Error, Equatable, CustomStringConvertible {
    case noACSource
    case mixedFrequencies
    case unsupportedPart(String)
    case singular

    public var description: String {
        switch self {
        case .noACSource: return "Add an AC source (sine, three-phase, AC current or a sine function generator) to run AC analysis."
        case .mixedFrequencies: return "Every AC source must run at the same frequency."
        case .unsupportedPart(let name): return "\(name) is non-linear or time-varying, so phasor analysis does not apply."
        case .singular: return "The circuit has a floating node or a shorted source."
        }
    }
}

/// Complex MNA system: node rows first, then one row per branch-current unknown.
struct ComplexSystem {
    var a: [[Complex]]
    var b: [Complex]
    let nodeCount: Int

    init(nodeCount: Int, auxCount: Int) {
        let n = nodeCount + auxCount
        self.nodeCount = nodeCount
        a = [[Complex]](repeating: [Complex](repeating: .zero, count: n), count: n)
        b = [Complex](repeating: .zero, count: n)
    }

    func aux(_ k: Int) -> Int { nodeCount + k }

    mutating func add(_ node: Int, _ col: Int, _ v: Complex) {
        guard node > 0, col > 0 else { return }
        a[node - 1][col - 1] += v
    }

    mutating func admittance(_ n1: Int, _ n2: Int, _ y: Complex) {
        add(n1, n1, y); add(n2, n2, y); add(n1, n2, -y); add(n2, n1, -y)
    }

    mutating func impedance(_ n1: Int, _ n2: Int, _ z: Complex) { admittance(n1, n2, Complex(1) / z) }

    /// Phasor current flowing through an element from `from` to `to`.
    mutating func current(from: Int, to: Int, _ i: Complex) {
        if from > 0 { b[from - 1] -= i }
        if to > 0 { b[to - 1] += i }
    }

    mutating func transadmittance(from: Int, to: Int, cp: Int, cm: Int, _ g: Complex) {
        add(from, cp, g); add(from, cm, -g); add(to, cp, -g); add(to, cm, g)
    }

    mutating func auxControlledCurrent(from: Int, to: Int, aux j: Int, _ k: Complex) {
        if from > 0 { a[from - 1][aux(j)] += k }
        if to > 0 { a[to - 1][aux(j)] -= k }
    }

    mutating func branch(_ k: Int, plus: Int, minus: Int) {
        let r = aux(k)
        if plus > 0 { a[plus - 1][r] += Complex(1); a[r][plus - 1] += Complex(1) }
        if minus > 0 { a[minus - 1][r] -= Complex(1); a[r][minus - 1] -= Complex(1) }
    }

    mutating func voltageSource(_ k: Int, plus: Int, minus: Int, _ v: Complex) {
        branch(k, plus: plus, minus: minus)
        b[aux(k)] = v
    }

    mutating func branchNode(_ k: Int, node: Int, _ c: Complex) {
        guard node > 0 else { return }
        a[aux(k)][node - 1] += c
    }

    mutating func branchAux(_ k: Int, aux j: Int, _ c: Complex) {
        a[aux(k)][aux(j)] += c
    }
}

/// Exact sinusoidal steady-state analysis using complex Modified Nodal Analysis.
///
/// Every R, L and C becomes an impedance (R, jωL, 1/jωC), every AC source a phasor,
/// and the resulting complex linear system is solved directly - no time stepping and
/// no start-up transient, so the numbers match a hand calculation.
///
/// With `frequency` every AC source is driven at that frequency instead (AC sweep). With an
/// operating point, diodes and transistors are replaced by their small-signal conductances
/// and DC / pulse sources become AC shorts, as in a SPICE `.AC` analysis.
public enum ACSteadyStateAnalyzer {
    public static func analyze(_ circuit: Circuit, frequency override: Double? = nil,
                               linearizedAt op: [Int: Double]? = nil) -> Result<ACSteadyStateResult, ACAnalysisError> {
        let drives = circuit.components.filter { acDriveFrequency($0) != nil }
        guard let reference = drives.first(where: { !isCurrentDrive($0.kind) }) ?? drives.first else {
            return .failure(.noACSource)
        }
        let frequency = override ?? acDriveFrequency(reference)!
        if override == nil, drives.contains(where: { abs(acDriveFrequency($0)! - frequency) > 1e-9 }) {
            return .failure(.mixedFrequencies)
        }
        let omega = 2.0 * .pi * frequency
        let smallSignal = op != nil

        let probeSolver = MNASolver(circuit: circuit)
        let pinToNode = probeSolver.pinToNode
        let nodeCount = probeSolver.totalNodes
        func nodes(_ c: CircuitComponent) -> [Int] { c.pins.map { pinToNode[$0.id] ?? 0 } }
        func opVoltage(_ n: Int) -> Double { n == 0 ? 0 : op?[n] ?? 0 }

        // Branch-current unknowns.
        var auxStart: [UUID: Int] = [:]
        var auxCount = 0
        for comp in circuit.components {
            if comp.kind.isSupplyRail && !circuit.isDrivingRail(comp) { continue }
            let k = auxRows(comp, smallSignal: smallSignal)
            guard k > 0 else { continue }
            auxStart[comp.id] = auxCount
            auxCount += k
        }
        guard nodeCount + auxCount > 0 else { return .failure(.singular) }

        var sys = ComplexSystem(nodeCount: nodeCount, auxCount: auxCount)
        var impedances: [UUID: Complex] = [:]
        var wattmeters: [UUID: (cc: Complex, pc: Complex)] = [:]
        var reactances: [ReactanceEntry] = []
        /// Phasor current through a part (pin 0 -> pin 1 sense) that is neither an impedance nor a branch.
        var fixedCurrents: [UUID: Complex] = [:]
        var transconductances: [UUID: (g: Complex, cp: Int, cm: Int)] = [:]

        for comp in circuit.components {
            let n = nodes(comp)
            func node(_ i: Int) -> Int { i < n.count ? n[i] : 0 }
            let k = auxStart[comp.id] ?? 0
            switch comp.kind {
            case .ground, .probe, .digitalGround, .frequencyCounter, .bodePlotter:
                continue
            case .vccRail, .vddRail, .veeRail, .vssRail:
                // A DC rail is an AC short to ground.
                if circuit.isDrivingRail(comp) { sys.voltageSource(k, plus: node(0), minus: 0, .zero) }
            case _ where comp.kind.isWaveformVoltageSource:
                // DC carries no AC signal: a 0 V phasor (a short for AC). Pulses, noise etc. only make
                // sense in a small-signal sweep, where they are AC shorts too.
                if !smallSignal && !isDC(comp) && acDriveFrequency(comp) == nil {
                    return .failure(.unsupportedPart(comp.designator))
                }
                sys.voltageSource(k, plus: node(0), minus: node(1), sourcePhasor(comp))
            case _ where comp.kind.isWaveformCurrentSource:
                if !smallSignal && !isDC(comp) && acDriveFrequency(comp) == nil {
                    return .failure(.unsupportedPart(comp.designator))
                }
                // Leaves pin 0 (the arrow tip); DC and non-sine current sources are open circuits for AC.
                let i = sourcePhasor(comp)
                sys.current(from: node(1), to: node(0), i)
                fixedCurrents[comp.id] = i
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
            case .potentiometer:
                let total = max(comp.value, 1e-6), ratio = MNASolver.wiperRatio(of: comp)
                if n.count >= 3 {
                    sys.impedance(node(0), node(2), Complex(max(total * ratio, 1e-6)))
                    sys.impedance(node(2), node(1), Complex(max(total * (1 - ratio), 1e-6)))
                } else {
                    impedances[comp.id] = Complex(max(total * ratio, 1e-6))
                }
            case .threePhaseWye, .threePhaseDelta:
                let peak = SourceWaveforms.threePhasePeak(comp)
                let ang = SourceWaveforms.threePhaseAngles(comp)
                if comp.kind == .threePhaseWye {
                    for i in 0..<3 { sys.voltageSource(k + i, plus: node(i), minus: node(3), polar(peak, degrees: ang[i])) }
                } else {
                    for i in 0..<2 { sys.voltageSource(k + i, plus: node(i), minus: node(i + 1), polar(peak, degrees: ang[i])) }
                }
            case .vcvs:
                sys.branch(k, plus: node(0), minus: node(1))
                sys.branchNode(k, node: node(2), Complex(-comp.value))
                sys.branchNode(k, node: node(3), Complex(comp.value))
            case .vccs:
                // Pushed out of OUT+, as in the transient solver.
                sys.transadmittance(from: node(1), to: node(0), cp: node(2), cm: node(3), Complex(comp.value))
                transconductances[comp.id] = (Complex(-comp.value), node(2), node(3))
            case _ where comp.kind.isDigitalSource:
                if comp.kind == .digitalClock && !smallSignal { return .failure(.unsupportedPart(comp.designator)) }
                sys.voltageSource(k, plus: node(0), minus: 0, .zero)
            case _ where comp.kind.isControlBlock:
                let inputs = Array(n.dropLast())
                guard let gains = ControlBlocks.acGains(comp, omega: omega, op: smallSignal ? inputs.map(opVoltage) : nil) else {
                    return .failure(.unsupportedPart(comp.designator))
                }
                sys.branch(k, plus: n.last ?? 0, minus: 0)
                for (i, inNode) in inputs.enumerated() where i < gains.count { sys.branchNode(k, node: inNode, -gains[i]) }
            case .ccvs:
                sys.voltageSource(k, plus: node(2), minus: node(3), .zero)
                sys.branch(k + 1, plus: node(0), minus: node(1))
                sys.branchAux(k + 1, aux: k, Complex(-comp.value))
            case .cccs:
                sys.voltageSource(k, plus: node(2), minus: node(3), .zero)
                sys.auxControlledCurrent(from: node(1), to: node(0), aux: k, Complex(comp.value))
            case .opAmp:
                // Linear region of the macro-model: an open-loop gain of 1e5.
                sys.branch(k, plus: node(2), minus: 0)
                sys.branchNode(k, node: node(1), Complex(-1e5))
                sys.branchNode(k, node: node(0), Complex(1e5))
            case .diode, .led, .schottkyDiode, .zenerDiode:
                guard smallSignal else { return .failure(.unsupportedPart(comp.designator)) }
                let vd = opVoltage(node(0)) - opVoltage(node(1))
                let g: Double
                if comp.kind == .zenerDiode {
                    g = MNASolver.zenerCurrent(vd, vz: comp.secondaryValue > 0 ? comp.secondaryValue : 5.1).g
                } else {
                    g = MNASolver.junctionModel(for: comp).evaluate(vd).g + MNASolver.junctionGmin
                }
                impedances[comp.id] = Complex(1 / g)
            case .bjtNPN, .bjtPNP:
                guard smallSignal else { return .failure(.unsupportedPart(comp.designator)) }
                let pnp = comp.kind == .bjtPNP
                let beta = comp.secondaryValue > 0 ? comp.secondaryValue : 100.0
                let (jp, jn) = pnp ? (node(2), node(0)) : (node(0), node(2))
                let model = MNASolver.JunctionModel(saturation: 1e-14, emissionCoefficient: 1)
                let g = model.evaluate(opVoltage(jp) - opVoltage(jn)).g
                sys.admittance(jp, jn, Complex(g + MNASolver.junctionGmin))
                let (from, to) = pnp ? (node(2), node(1)) : (node(1), node(2))
                sys.transadmittance(from: from, to: to, cp: jp, cm: jn, Complex(beta * g))
            default:
                return .failure(.unsupportedPart(comp.designator))
            }
        }

        for comp in circuit.components {
            let n = nodes(comp)
            if let z = impedances[comp.id] {
                sys.impedance(n.count > 0 ? n[0] : 0, n.count > 1 ? n[1] : 0, z)
            } else if let w = wattmeters[comp.id], n.count >= 4 {
                sys.impedance(n[0], n[1], w.cc)
                sys.impedance(n[2], n[3], w.pc)
            }
        }

        guard let x = solve(sys.a, sys.b) else { return .failure(.singular) }
        func v(_ node: Int) -> Complex { node == 0 ? .zero : x[node - 1] }
        func auxValue(_ comp: CircuitComponent, _ i: Int = 0) -> Complex { x[nodeCount + (auxStart[comp.id] ?? 0) + i] }

        var parts: [ComponentPhasor] = []
        var referencePhasor: ComponentPhasor?
        var referenceCurrent = Complex.zero
        var threePhase: [ThreePhaseReport] = []
        for comp in circuit.components {
            let n = nodes(comp)
            guard n.count >= 2 else { continue }
            let drop = v(n[0]) - v(n[1])
            var current: Complex?
            var voltage = drop
            if comp.kind == .threePhaseWye || comp.kind == .threePhaseDelta {
                let wye = comp.kind == .threePhaseWye
                let a = auxValue(comp, 0), b = auxValue(comp, 1)
                let lines = wye ? [-a, -b, -auxValue(comp, 2)] : [-a, a - b, b]
                let lineV = [v(n[0]) - v(n[1]), v(n[1]) - v(n[2]), v(n[2]) - v(n[0])]
                let phaseV = wye ? (0..<3).map { v(n[$0]) - v(n[3]) } : lineV
                // Delta winding currents are indeterminate for ideal windings; power comes from the line side.
                let s: Complex = wye
                    ? (0..<3).reduce(Complex.zero) { $0 + phaseV[$1] * conj(lines[$1]) }
                    : (v(n[0]) - v(n[2])) * conj(lines[0]) + (v(n[1]) - v(n[2])) * conj(lines[1])
                threePhase.append(ThreePhaseReport(id: comp.id, designator: comp.designator, isWye: wye,
                                                   lineCurrents: lines, phaseVoltages: phaseV, lineVoltages: lineV,
                                                   complexPower: Complex(0.5 * s.re, 0.5 * s.im)))
                // As a single part: phase A voltage and line A current.
                voltage = phaseV[0]
                current = lines[0]
            } else if comp.kind == .ccvs {
                current = -auxValue(comp, 1)
            } else if comp.kind == .cccs {
                current = Complex(comp.value) * auxValue(comp, 0)
            } else if let w = wattmeters[comp.id], n.count >= 4 {
                // Voltage = pressure-coil voltage, current = current-coil current,
                // so `averagePower` is exactly what the wattmeter reads.
                voltage = v(n[2]) - v(n[3])
                current = (v(n[0]) - v(n[1])) / w.cc
            } else if let z = impedances[comp.id] {
                current = drop / z
            } else if auxStart[comp.id] != nil {
                // MNA's branch current flows into the + node; the delivered current is its negative.
                current = -auxValue(comp)
            } else if let i = fixedCurrents[comp.id] {
                current = i
            } else if let t = transconductances[comp.id] {
                current = t.g * (v(t.cp) - v(t.cm))
            }
            guard let i = current else { continue }
            let phasor = ComponentPhasor(id: comp.id, designator: comp.designator, kind: comp.kind, voltage: voltage, current: i)
            parts.append(phasor)
            if comp.id == reference.id {
                referencePhasor = phasor
                referenceCurrent = i
            }
        }

        var nodeMap: [Int: Complex] = [0: .zero]
        for k in 0..<nodeCount { nodeMap[k + 1] = x[k] }

        // An unloaded reference source (e.g. driving only ideal block inputs) is fine: its current is just 0.
        guard let refPhasor = referencePhasor else { return .failure(.singular) }
        return .success(ACSteadyStateResult(
            frequency: frequency,
            referenceSource: refPhasor,
            sourceCurrent: referenceCurrent,
            parts: parts,
            reactances: reactances,
            nodeVoltages: nodeMap,
            threePhase: threePhase
        ))
    }

    /// Frequency of a sinusoidal source, or nil if the part does not drive the circuit with a sine.
    public static func acDriveFrequency(_ comp: CircuitComponent) -> Double? {
        switch comp.kind {
        case .acVoltageSource:
            return comp.secondaryValue > 0 ? comp.secondaryValue : 50.0
        case .functionGenerator where (GeneratorWaveform(rawValue: comp.modeIndex) ?? .sine) == .sine:
            return comp.secondaryValue > 0 ? comp.secondaryValue : 1000.0
        case .threePhaseWye, .threePhaseDelta:
            return comp.secondaryValue > 0 ? comp.secondaryValue : 50.0
        case .acCurrentSource:
            return comp.secondaryValue > 0 ? comp.secondaryValue : 1000.0
        default:
            return nil
        }
    }

    static func isCurrentDrive(_ kind: ComponentKind) -> Bool { kind.isWaveformCurrentSource }

    /// Sources that never change, so they carry no AC signal.
    static func isDC(_ comp: CircuitComponent) -> Bool {
        comp.kind == .dcVoltageSource || comp.kind == .dcCurrentSource
    }

    /// Branch-current unknowns a part needs in the phasor system.
    static func auxRows(_ comp: CircuitComponent, smallSignal: Bool) -> Int {
        switch comp.kind {
        case .vcvs, .opAmp, .cccs:
            return 1
        case _ where comp.kind.isControlBlock:
            return 1
        case _ where comp.kind.isDigitalSource:
            return 1
        case .ccvs:
            return 2
        case _ where comp.kind.isWaveformVoltageSource:
            return 1
        case .threePhaseWye:
            return 3
        case .threePhaseDelta:
            return 2
        case .vccRail, .vddRail, .veeRail, .vssRail:
            return 1
        default:
            return 0
        }
    }

    /// Phasor of an independent source: value·sin(ωt + φ) becomes value∠φ. Non-sine sources are 0.
    static func sourcePhasor(_ comp: CircuitComponent) -> Complex {
        guard acDriveFrequency(comp) != nil else { return .zero }
        return Complex(comp.value)
    }

    static func conj(_ z: Complex) -> Complex { Complex(z.re, -z.im) }

    public static func polar(_ magnitude: Double, degrees: Double) -> Complex {
        let r = degrees * .pi / 180
        return Complex(magnitude * cos(r), magnitude * sin(r))
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
