import Foundation

/// Result of a single simulation time step.
public struct SimulationStepResult {
    public let time: Double
    public let nodeVoltages: [Int: Double]
    public let converged: Bool
    public let iterations: Int
    /// True when the MNA matrix could not be factored (floating node or a source shorted across itself).
    public let isSingular: Bool
}

/// The core Modified Nodal Analysis (MNA) solver.
/// Solves both DC operating points and time-domain transient differential equations.
public final class MNASolver {
    public let circuit: Circuit
    public var currentTime: Double = 0.0
    public var timeStep: Double = 1e-4 // 100 microseconds default

    // Pin to Node mapping resolved from circuit graph
    public private(set) var pinToNode: [UUID: Int] = [:]
    public private(set) var totalNodes: Int = 0
    /// True when the last solve produced a usable operating point.
    public private(set) var isSolutionValid = false
    /// Newton convergence criteria (SPICE defaults).
    public var tolerances = SolverTolerances()
    /// First auxiliary (branch-current) unknown of each part that has one.
    public private(set) var auxStart: [UUID: Int] = [:]
    /// Number of auxiliary unknowns after the node voltages.
    public private(set) var auxCount: Int = 0
    /// Last accepted solution: node voltages 1...N followed by branch currents.
    public private(set) var solution: [Double] = []

    // Thermal voltage at 300K: kT/q
    private static let Vt = 0.02585
    private static let diodeIs = 1e-14

    // Instrument / switch modelling constants
    static let idealAmmeterResistance = 1e-3
    static let idealVoltmeterResistance = 1e7
    static let openCircuitResistance = 1e9
    static let closedContactResistance = 1e-4
    static let ohmmeterTestCurrent = 1e-3
    static let thermistorBeta = 3950.0
    private static let thermistorReferenceKelvin = 298.15 // 25 C

    public init(circuit: Circuit, timeStep: Double = 1e-4) {
        self.circuit = circuit
        self.timeStep = timeStep
        rebuildNetlist()
    }

    /// Rebuilds electrical nodes whenever components or wires are added, moved, or deleted.
    public func rebuildNetlist() {
        let resolution = circuit.resolveNodes()
        self.pinToNode = resolution.pinToNode
        self.totalNodes = resolution.totalNodes
        layoutAuxiliaryUnknowns()
    }

    /// Resets all internal component states (capacitors discharged, inductors zero current).
    public func reset() {
        currentTime = 0.0
        isSolutionValid = false
        solution = []
        for comp in circuit.components {
            comp.runtimeVoltageDrop = 0.0
            comp.runtimeCurrent = 0.0
            comp.runtimePrevVoltage = 0.0
            comp.runtimePrevCurrent = 0.0
            comp.runtimeReading = 0.0
            comp.runtimeAverage = 0.0
        }
        for i in 0..<circuit.wires.count {
            circuit.wires[i].runtimeCurrent = 0.0
        }
    }

    /// Steps the simulation forward by `dt` seconds using Newton-Raphson iteration.
    public func step(dt: Double? = nil) -> SimulationStepResult {
        let h = dt ?? timeStep
        currentTime += h
        layoutAuxiliaryUnknowns()

        // If no nodes, return empty result
        if totalNodes == 0 {
            return SimulationStepResult(time: currentTime, nodeVoltages: [0: 0.0], converged: true, iterations: 0, isSingular: false)
        }

        let size = totalNodes + auxCount
        // Warm start from the last accepted point: Newton then only has to follow the change over one step.
        let x0 = solution.count == size ? solution : [Double](repeating: 0, count: size)
        let outcome = newtonSolve(time: currentTime, h: h, initial: x0)

        isSolutionValid = !outcome.singular
        if !outcome.singular { solution = outcome.x }
        let voltages = nodeVoltageMap(outcome.singular ? x0 : outcome.x)

        // Update runtime component states (currents, voltages, companion history, instrument readings)
        updateComponentRuntimeStates(voltages: voltages, x: outcome.singular ? x0 : outcome.x, dt: h)

        return SimulationStepResult(
            time: currentTime,
            nodeVoltages: voltages,
            converged: outcome.converged,
            iterations: outcome.iterations,
            isSingular: outcome.singular
        )
    }

    // MARK: - Newton-Raphson

    struct NewtonOutcome {
        var x: [Double]
        var converged: Bool
        var singular: Bool
        var iterations: Int
    }

    /// Solves the (possibly non-linear) circuit equations at one time point.
    func newtonSolve(time t: Double, h: Double, initial x0: [Double]) -> NewtonOutcome {
        var x = x0
        let nonlinear = circuit.components.contains { Self.isNonlinear($0.kind) }
        var iterations = 0
        while iterations < tolerances.maxIterations {
            iterations += 1
            var sys = MNASystem(nodeCount: totalNodes, auxCount: auxCount)
            let ctx = StampContext(x: x, nodeCount: totalNodes, time: t, h: h)
            for comp in circuit.components {
                stamp(comp, nodes: nodeIndices(for: comp), into: &sys, ctx: ctx)
            }
            guard let xNew = sys.A.solve(b: sys.b) else {
                return NewtonOutcome(x: x, converged: false, singular: true, iterations: iterations)
            }
            let done = !nonlinear || hasConverged(old: x, new: xNew)
            x = xNew
            if done {
                return NewtonOutcome(x: x, converged: true, singular: false, iterations: iterations)
            }
        }
        return NewtonOutcome(x: x, converged: false, singular: false, iterations: iterations)
    }

    /// SPICE convergence test: every node voltage within reltol·|v| + vntol, every branch current within reltol·|i| + abstol.
    func hasConverged(old: [Double], new: [Double]) -> Bool {
        for i in 0..<new.count {
            let a = new[i], b = i < old.count ? old[i] : 0
            let floor = i < totalNodes ? tolerances.vntol : tolerances.abstol
            if abs(a - b) > tolerances.reltol * max(abs(a), abs(b)) + floor { return false }
        }
        return true
    }

    /// Parts whose stamp depends on the present solution, so Newton has to iterate.
    static func isNonlinear(_ kind: ComponentKind) -> Bool {
        switch kind {
        case .diode, .led, .zenerDiode, .schottkyDiode, .bjtNPN, .bjtPNP, .opAmp:
            return true
        default:
            return kind.isLogicGate
        }
    }

    private func nodeVoltageMap(_ x: [Double]) -> [Int: Double] {
        var map: [Int: Double] = [0: 0.0]
        for i in 1...max(totalNodes, 1) where i <= totalNodes {
            map[i] = i - 1 < x.count ? x[i - 1] : 0
        }
        return map
    }

    // MARK: - Node helpers

    private func nodeIndices(for comp: CircuitComponent) -> [Int] {
        comp.pins.map { pinToNode[$0.id] ?? 0 }
    }

    private func voltage(of node: Int, in voltages: [Int: Double]) -> Double {
        if node == 0 { return 0.0 }
        return voltages[node] ?? 0.0
    }

    /// Assigns each part that needs branch-current unknowns its first auxiliary row.
    func layoutAuxiliaryUnknowns() {
        var next = 0
        var map: [UUID: Int] = [:]
        for comp in circuit.components {
            let count = Self.auxiliaryRowCount(for: comp)
            guard count > 0 else { continue }
            map[comp.id] = next
            next += count
        }
        auxStart = map
        auxCount = next
    }

    /// How many auxiliary MNA variables a part needs (1 for each ideal source / constraint).
    static func auxiliaryRowCount(for comp: CircuitComponent) -> Int {
        switch comp.kind {
        case .dcVoltageSource, .acVoltageSource, .clockSource, .functionGenerator, .opAmp, .vcvs:
            return 1
        case .logicAND, .logicOR, .logicNOT, .logicNAND, .logicNOR, .logicXOR, .logicXNOR, .logicBuffer:
            return 1
        default:
            return 0
        }
    }

    // MARK: - Stamping

    private func stamp(_ comp: CircuitComponent, nodes n: [Int], into sys: inout MNASystem, ctx: StampContext) {
        func node(_ i: Int) -> Int { i < n.count ? n[i] : 0 }

        switch comp.kind {
        case .resistor, .switchSPST, .rheostat, .lamp, .fuse, .thermistor, .photoResistor,
             .ammeter, .voltmeter, .galvanometer:
            if let r = resistance(of: comp) {
                sys.conductance(node(0), node(1), 1.0 / r)
            }

        case .multimeter:
            switch MeterMode(rawValue: comp.modeIndex) ?? .voltage {
            case .voltage, .current:
                sys.conductance(node(0), node(1), 1.0 / multimeterResistance(comp))
            case .resistance:
                // Ohmmeter: forces a known test current through whatever is hooked across it.
                sys.current(from: node(1), to: node(0), ohmmeterTestCurrent(for: comp))
            }

        case .ohmmeter:
            sys.current(from: node(1), to: node(0), ohmmeterTestCurrent(for: comp))

        case .potentiometer:
            let total = max(comp.value, 1e-6)
            let ratio = Self.wiperRatio(of: comp)
            guard n.count >= 3 else {
                // Files saved before the 3-terminal divider: behave as a variable resistor.
                sys.conductance(node(0), node(1), 1.0 / max(total * ratio, 1e-6))
                return
            }
            // Track split at the wiper: A-W and W-B resistors.
            sys.conductance(node(0), node(2), 1.0 / max(total * ratio, 1e-6))
            sys.conductance(node(2), node(1), 1.0 / max(total * (1.0 - ratio), 1e-6))

        case .wattmeter:
            // Current coil in series (pin 0 -> 1), pressure coil across the load (pin 2 -> 3).
            sys.conductance(node(0), node(1), 1.0 / max(comp.value > 0 ? comp.value : 0.05, 1e-4))
            let pcR = comp.secondaryValue > 0 ? comp.secondaryValue : 1e6
            sys.conductance(node(2), node(3), 1.0 / pcR)

        case .capacitor, .electrolyticCapacitor, .trimmerCapacitor:
            // Backward Euler companion model: G = C/dt in parallel with a history source.
            let c = max(comp.value, 1e-15)
            let geq = c / ctx.h
            sys.conductance(node(0), node(1), geq)
            sys.current(from: node(1), to: node(0), geq * comp.runtimePrevVoltage)

        case .inductor:
            // Backward Euler companion model: G = dt/L in parallel with a history source.
            let l = max(comp.value, 1e-12)
            sys.conductance(node(0), node(1), ctx.h / l)
            sys.current(from: node(0), to: node(1), comp.runtimePrevCurrent)

        case .dcCurrentSource:
            // Current leaves the OUT terminal (pin 0), the way the symbol's arrow points.
            sys.current(from: node(1), to: node(0), comp.value)

        case .diode, .led, .schottkyDiode:
            stampJunction(comp, anode: node(0), cathode: node(1), into: &sys, ctx: ctx)

        case .zenerDiode:
            let nA = node(0), nK = node(1)
            let vd = ctx.v(nA) - ctx.v(nK)
            let vz = comp.secondaryValue > 0 ? comp.secondaryValue : 5.1
            if vd < -vz {
                // Reverse breakdown: modelled as a 10 ohm impedance clamped at Vz.
                let gz = 1.0 / 10.0
                sys.conductance(nA, nK, gz)
                sys.current(from: nA, to: nK, -gz * (-vd - vz))
            } else if vd > 0.6 {
                sys.conductance(nA, nK, 1.0 / 0.1)
            } else {
                sys.conductance(nA, nK, 1e-12)
            }

        case .bjtNPN, .bjtPNP:
            stampBJT(comp, nodes: [node(0), node(1), node(2)], into: &sys, ctx: ctx, pnp: comp.kind == .bjtPNP)

        case .vccs:
            // Voltage-Controlled Current Source: I = gm * (V_ctrl+ - V_ctrl-), pushed out of OUT+
            // (the terminal the diamond's arrow points to).
            sys.transconductance(from: node(1), to: node(0), cp: node(2), cm: node(3), comp.value)

        default:
            break
        }

        guard let k = auxStart[comp.id] else { return }
        switch comp.kind {
        case .dcVoltageSource, .acVoltageSource, .clockSource, .functionGenerator:
            sys.voltageSource(k, plus: node(0), minus: node(1), value: sourceTargetVoltage(comp, time: ctx.time))

        case .vcvs:
            // V(out+) - V(out-) = gain * (V(ctrl+) - V(ctrl-))
            sys.branch(k, plus: node(0), minus: node(1))
            sys.branchDependsOnNode(k, node: node(2), -comp.value)
            sys.branchDependsOnNode(k, node: node(3), comp.value)

        case .opAmp:
            // Macro-model: output pin driven as a source against ground with finite open-loop gain and rails.
            let vPlus = ctx.v(node(1))
            let vMinus = ctx.v(node(0))
            let rail = comp.secondaryValue > 0 ? comp.secondaryValue : 15.0
            let target = min(max((vPlus - vMinus) * 1e5, -rail), rail)
            sys.voltageSource(k, plus: node(2), minus: 0, value: target)

        case .logicAND, .logicOR, .logicNOT, .logicNAND, .logicNOR, .logicXOR, .logicXNOR, .logicBuffer:
            sys.voltageSource(k, plus: n.last ?? 0, minus: 0, value: evaluateLogicGate(comp: comp, nodes: n, ctx: ctx))

        default:
            break
        }
    }

    /// Instantaneous target value for an independent source.
    private func sourceTargetVoltage(_ comp: CircuitComponent, time t: Double) -> Double {
        switch comp.kind {
        case .dcVoltageSource:
            return comp.value
        case .acVoltageSource:
            let freq = comp.secondaryValue > 0 ? comp.secondaryValue : 60.0
            return comp.value * sin(2.0 * .pi * freq * t)
        case .clockSource:
            let freq = comp.secondaryValue > 0 ? comp.secondaryValue : 1000.0
            let period = 1.0 / freq
            return t.truncatingRemainder(dividingBy: period) < period * 0.5 ? comp.value : 0.0
        case .functionGenerator:
            let freq = comp.secondaryValue > 0 ? comp.secondaryValue : 1000.0
            let phase = (t * freq).truncatingRemainder(dividingBy: 1.0)
            switch GeneratorWaveform(rawValue: comp.modeIndex) ?? .sine {
            case .sine:
                return comp.value * sin(2.0 * .pi * phase)
            case .square:
                return phase < 0.5 ? comp.value : -comp.value
            case .triangle:
                // phase 0 -> +V, 0.5 -> -V, 1 -> +V
                let p = phase < 0.5 ? phase * 2.0 : (phase - 0.5) * 2.0
                return comp.value * (p < 0.5 ? (4.0 * p - 1.0) : (3.0 - 4.0 * p))
            }
        default:
            return 0.0
        }
    }

    // MARK: - Device models

    private struct JunctionModel {
        let saturation: Double
        let emissionCoefficient: Double
        let maxForwardVoltage: Double
    }

    private static func junctionModel(for comp: CircuitComponent) -> JunctionModel {
        switch comp.kind {
        case .led:
            return JunctionModel(saturation: 1e-18, emissionCoefficient: 2.0, maxForwardVoltage: comp.ledColor.forwardVoltage + 0.3)
        case .schottkyDiode:
            return JunctionModel(saturation: 1e-12, emissionCoefficient: 1.0, maxForwardVoltage: 0.45)
        default:
            return JunctionModel(saturation: diodeIs, emissionCoefficient: 1.0, maxForwardVoltage: 0.82)
        }
    }

    /// Newton-Raphson linearisation of a PN junction (diode / LED / Schottky).
    private func stampJunction(
        _ comp: CircuitComponent,
        anode nA: Int,
        cathode nK: Int,
        into sys: inout MNASystem,
        ctx: StampContext
    ) {
        let model = Self.junctionModel(for: comp)
        let vt = Self.Vt * model.emissionCoefficient

        var vd = ctx.v(nA) - ctx.v(nK)

        // Seed the first iterate near the conduction knee so the exponential does not start at zero.
        if comp.runtimePrevVoltage >= 0.1 {
            vd = comp.runtimePrevVoltage
        } else if vd < 0.1 {
            vd = (model.maxForwardVoltage - 0.3) * 0.85
        }
        vd = min(max(vd, -5.0), model.maxForwardVoltage)

        let expTerm = exp(vd / vt)
        let id = model.saturation * (expTerm - 1.0)
        let gd = max((model.saturation / vt) * expTerm, 1e-12)

        sys.conductance(nA, nK, gd)
        sys.current(from: nA, to: nK, id - gd * vd)
    }

    private func stampBJT(
        _ comp: CircuitComponent,
        nodes n: [Int],
        into sys: inout MNASystem,
        ctx: StampContext,
        pnp: Bool
    ) {
        guard n.count >= 3 else { return }
        let nB = n[0], nC = n[1], nE = n[2]
        let beta = comp.secondaryValue > 0 ? comp.secondaryValue : 100.0
        let vB = ctx.v(nB)
        let vE = ctx.v(nE)

        if pnp {
            let vEB = min(max(vE - vB, -5.0), 0.8)
            let ib = 1e-14 * (exp(vEB / Self.Vt) - 1.0)
            let geb = max((1e-14 / Self.Vt) * exp(vEB / Self.Vt), 1e-12)
            sys.conductance(nE, nB, geb)
            sys.current(from: nE, to: nB, ib - geb * vEB)
            sys.current(from: nE, to: nC, max(beta * ib, 0.0))
        } else {
            let vBE = min(max(vB - vE, -5.0), 0.8)
            let ib = 1e-14 * (exp(vBE / Self.Vt) - 1.0)
            let gbe = max((1e-14 / Self.Vt) * exp(vBE / Self.Vt), 1e-12)
            sys.conductance(nB, nE, gbe)
            sys.current(from: nB, to: nE, ib - gbe * vBE)
            sys.current(from: nC, to: nE, max(beta * ib, 0.0))
        }
    }

    // MARK: - Parameter resolution

    /// Wiper position as a 0...1 fraction.
    public static func wiperRatio(of comp: CircuitComponent) -> Double {
        guard comp.secondaryValue > 0 else { return 0.5 }
        return min(max(comp.secondaryValue, 0.001), 0.999)
    }

    private func multimeterResistance(_ comp: CircuitComponent) -> Double {
        switch MeterMode(rawValue: comp.modeIndex) ?? .voltage {
        case .voltage: return comp.value > 0 ? comp.value : Self.idealVoltmeterResistance
        case .current: return comp.value > 0 ? max(comp.value, 1e-6) : Self.idealAmmeterResistance
        case .resistance: return Self.openCircuitResistance
        }
    }

    private func ohmmeterTestCurrent(for comp: CircuitComponent) -> Double {
        comp.value > 0 ? comp.value : Self.ohmmeterTestCurrent
    }

    /// Effective resistance of a simple two-terminal resistive part.
    func resistance(of comp: CircuitComponent) -> Double? {
        switch comp.kind {
        case .resistor:
            return max(comp.value, 1e-6)

        case .switchSPST:
            return comp.stateBool ? Self.closedContactResistance : Self.openCircuitResistance

        case .rheostat:
            return max(comp.value * Self.wiperRatio(of: comp), 1e-6)

        case .lamp:
            // Cold filament resistance; brightness is driven off the solved current.
            return max(comp.value > 0 ? comp.value : 10.0, 1e-3)

        case .fuse:
            return comp.stateBool ? max(comp.value > 0 ? comp.value : 0.05, 1e-4) : Self.openCircuitResistance

        case .thermistor:
            // NTC: R(T) = R25 * exp(B * (1/T - 1/298.15))
            let r25 = max(comp.value > 0 ? comp.value : 10_000.0, 1e-3)
            let kelvin = max((comp.secondaryValue > -270 ? comp.secondaryValue : 25.0) + 273.15, 1.0)
            return r25 * exp(Self.thermistorBeta * (1.0 / kelvin - 1.0 / Self.thermistorReferenceKelvin))

        case .photoResistor:
            // CdS cell: roughly R = R(10 lux) * (lux / 10) ^ -0.7
            let base = max(comp.value > 0 ? comp.value : 5_000.0, 1e-3)
            let lux = max(comp.secondaryValue > 0 ? comp.secondaryValue : 10.0, 0.1)
            return base * pow(lux / 10.0, -0.7)

        case .ammeter:
            return comp.value > 0 ? max(comp.value, 1e-6) : Self.idealAmmeterResistance

        case .voltmeter:
            return comp.value > 0 ? comp.value : Self.idealVoltmeterResistance

        case .galvanometer:
            return comp.value > 0 ? comp.value : 100.0

        case .multimeter:
            return multimeterResistance(comp)

        default:
            return nil
        }
    }

    // MARK: - Logic

    /// High = 5.0V, Low = 0.0V. Threshold = 2.5V.
    private func evaluateLogicGate(comp: CircuitComponent, nodes n: [Int], ctx: StampContext) -> Double {
        let in1 = ctx.v(n.first ?? 0) > 2.5
        let in2 = n.count > 1 ? ctx.v(n[1]) > 2.5 : false

        let result: Bool
        switch comp.kind {
        case .logicAND: result = in1 && in2
        case .logicOR: result = in1 || in2
        case .logicNAND: result = !(in1 && in2)
        case .logicNOR: result = !(in1 || in2)
        case .logicXOR: result = in1 != in2
        case .logicXNOR: result = in1 == in2
        case .logicNOT: result = !in1
        case .logicBuffer: result = in1
        default: result = false
        }
        return result ? 5.0 : 0.0
    }

    // MARK: - Runtime state

    private func updateComponentRuntimeStates(voltages: [Int: Double], x: [Double], dt: Double) {
        for comp in circuit.components {
            let n = nodeIndices(for: comp)
            func v(_ i: Int) -> Double { i < n.count ? voltage(of: n[i], in: voltages) : 0.0 }

            let vDrop = v(0) - v(1)
            comp.runtimeVoltageDrop = vDrop

            switch comp.kind {
            case .resistor, .switchSPST, .rheostat, .lamp, .fuse, .thermistor, .photoResistor,
                 .ammeter, .voltmeter, .galvanometer:
                let r = resistance(of: comp) ?? 1.0
                comp.runtimeCurrent = vDrop / r

            case .multimeter:
                if MeterMode(rawValue: comp.modeIndex) == .resistance {
                    comp.runtimeCurrent = ohmmeterTestCurrent(for: comp)
                } else {
                    comp.runtimeCurrent = vDrop / multimeterResistance(comp)
                }

            case .potentiometer:
                // Report the A-W segment, which is what the wiper delivers to the circuit.
                let rAW = max(comp.value * Self.wiperRatio(of: comp), 1e-6)
                if n.count >= 3 {
                    comp.runtimeVoltageDrop = v(0) - v(2)
                    comp.runtimeCurrent = (v(0) - v(2)) / rAW
                } else {
                    comp.runtimeCurrent = vDrop / rAW
                }

            case .wattmeter:
                let ccR = max(comp.value > 0 ? comp.value : 0.05, 1e-4)
                let iCC = (v(0) - v(1)) / ccR
                let vPC = v(2) - v(3)
                comp.runtimeCurrent = iCC
                comp.runtimeVoltageDrop = vPC
                comp.runtimeReading = abs(iCC * vPC)

            case .capacitor, .electrolyticCapacitor, .trimmerCapacitor:
                let c = max(comp.value, 1e-15)
                comp.runtimeCurrent = c * (vDrop - comp.runtimePrevVoltage) / dt
                comp.runtimePrevVoltage = vDrop

            case .inductor:
                let l = max(comp.value, 1e-12)
                let newI = comp.runtimePrevCurrent + (vDrop * dt / l)
                comp.runtimeCurrent = newI
                comp.runtimePrevCurrent = newI

            case .diode, .led, .schottkyDiode:
                let model = Self.junctionModel(for: comp)
                let vt = Self.Vt * model.emissionCoefficient
                let clampedVd = min(max(vDrop, -10.0), 1.5)
                comp.runtimeCurrent = model.saturation * (exp(clampedVd / vt) - 1.0)
                comp.runtimePrevVoltage = vDrop

            case .zenerDiode:
                let vz = comp.secondaryValue > 0 ? comp.secondaryValue : 5.1
                if vDrop < -vz {
                    comp.runtimeCurrent = -(-vDrop - vz) / 10.0
                } else {
                    comp.runtimeCurrent = vDrop > 0.6 ? vDrop / 0.1 : 0.0
                }
                comp.runtimePrevVoltage = vDrop

            case .ohmmeter:
                let test = ohmmeterTestCurrent(for: comp)
                comp.runtimeCurrent = test
                comp.runtimeReading = abs(vDrop) / test

            case .probe:
                comp.runtimeCurrent = 0.0
                comp.runtimeReading = v(0)

            case .dcVoltageSource, .acVoltageSource, .clockSource, .functionGenerator, .vcvs:
                // MNA's branch unknown flows into the + terminal; report the current delivered out of it.
                if let k = auxStart[comp.id], totalNodes + k < x.count {
                    comp.runtimeCurrent = -x[totalNodes + k]
                }

            default:
                break
            }

            updateInstrumentReading(comp)
            if let tau = acAveragingWindow {
                averageACReading(comp, alpha: min(1.0, dt / tau))
            }
        }

        blowFuses()

        // Update runtime current on wires for visual animation
        for i in 0..<circuit.wires.count {
            let wire = circuit.wires[i]
            if let comp = circuit.components.first(where: { c in c.pins.contains { $0.id == wire.startPinId } }) {
                circuit.wires[i].runtimeCurrent = comp.runtimeCurrent
            }
        }
    }

    /// Instruments publish their measured quantity in `runtimeReading` so the faceplate can show it.
    private func updateInstrumentReading(_ comp: CircuitComponent) {
        switch comp.kind {
        case .ammeter, .galvanometer:
            comp.runtimeReading = abs(comp.runtimeCurrent)
        case .multimeter:
            switch MeterMode(rawValue: comp.modeIndex) ?? .voltage {
            case .voltage:
                comp.runtimeReading = abs(comp.runtimeVoltageDrop)
            case .current:
                comp.runtimeReading = abs(comp.runtimeCurrent)
            case .resistance:
                comp.runtimeReading = comp.runtimeCurrent > 1e-12 ? abs(comp.runtimeVoltageDrop) / comp.runtimeCurrent : 0
            }
        case .voltmeter:
            comp.runtimeReading = abs(comp.runtimeVoltageDrop)
        case .probe:
            break
        default:
            break
        }
    }

    /// Averaging time for AC meters: five periods of the slowest AC source, or nil in a DC circuit.
    var acAveragingWindow: Double? {
        let freqs = circuit.components.filter { $0.kind == .acVoltageSource }
            .map { $0.secondaryValue > 0 ? $0.secondaryValue : 50.0 }
        guard let slowest = freqs.min() else { return nil }
        return 5.0 / slowest
    }

    /// Real AC meters are not fast enough to follow the waveform: an ammeter or voltmeter
    /// shows the RMS value and a wattmeter the average power. Both come from a running average.
    private func averageACReading(_ comp: CircuitComponent, alpha: Double) {
        let sample: Double
        let isPower: Bool
        switch comp.kind {
        case .ammeter:
            sample = comp.runtimeCurrent; isPower = false
        case .voltmeter:
            sample = comp.runtimeVoltageDrop; isPower = false
        case .multimeter:
            switch MeterMode(rawValue: comp.modeIndex) ?? .voltage {
            case .voltage: sample = comp.runtimeVoltageDrop
            case .current: sample = comp.runtimeCurrent
            case .resistance: return
            }
            isPower = false
        case .wattmeter:
            sample = comp.runtimeCurrent * comp.runtimeVoltageDrop; isPower = true
        default:
            return
        }
        let x = isPower ? sample : sample * sample
        comp.runtimeAverage += alpha * (x - comp.runtimeAverage)
        comp.runtimeReading = isPower ? abs(comp.runtimeAverage) : max(comp.runtimeAverage, 0).squareRoot()
    }

    /// A fuse that carries more than its rating opens permanently, exactly like the real part.
    private func blowFuses() {
        for comp in circuit.components where comp.kind == .fuse && comp.stateBool {
            let rating = comp.secondaryValue > 0 ? comp.secondaryValue : 1.0
            if abs(comp.runtimeCurrent) > rating {
                comp.stateBool = false
            }
        }
    }

    /// Resets a blown fuse so the experiment can be repeated.
    public func resetFuses() {
        for comp in circuit.components where comp.kind == .fuse {
            comp.stateBool = true
        }
    }

    // MARK: - Public lookups used by the UI

    /// Node voltage at a pin, for probe badges and instrument faces.
    public func nodeVoltage(atPin pinId: UUID, in voltages: [Int: Double]) -> Double {
        voltage(of: pinToNode[pinId] ?? 0, in: voltages)
    }

    /// Galvanometer needle position, 0...1 of full-scale deflection.
    public static func galvanometerDeflection(of comp: CircuitComponent) -> Double {
        let fullScale = comp.secondaryValue > 0 ? comp.secondaryValue : 1e-3
        guard fullScale > 0 else { return 0 }
        return min(max(abs(comp.runtimeCurrent) / fullScale, 0), 1)
    }
}
