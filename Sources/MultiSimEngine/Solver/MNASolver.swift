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
    /// Integration rule for capacitors and inductors.
    public var integrationMethod: IntegrationMethod = .trapezoidal
    /// True until the first step and right after a source discontinuity: that step uses backward Euler.
    public private(set) var needsBackwardEulerStep = true
    private var shortenNextStep = false
    /// Subdivide each step so the trapezoidal local truncation error stays within tolerance.
    public var adaptiveTimestep = false
    /// SPICE TRTOL: how far the LTE estimate may exceed reltol before a step is rejected.
    public var truncationErrorFactor = 7.0
    /// Current internal step when `adaptiveTimestep` is on.
    public private(set) var adaptiveStep: Double = 0
    private var lteHistory: [(Double, [Double])] = []
    /// Homotopy used by the most recent hard solve (shown by the diagnostics sheet).
    public private(set) var lastConvergenceAid: ConvergenceAid = .none
    /// Newton convergence criteria (SPICE defaults).
    public var tolerances = SolverTolerances()
    /// First auxiliary (branch-current) unknown of each part that has one.
    public private(set) var auxStart: [UUID: Int] = [:]
    /// Number of auxiliary unknowns after the node voltages.
    public private(set) var auxCount: Int = 0
    /// Last accepted solution: node voltages 1...N followed by branch currents.
    public private(set) var solution: [Double] = []

    // Thermal voltage at 300K: kT/q
    static let Vt = 0.02585
    static let diodeIs = 1e-14

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
        needsBackwardEulerStep = true
        shortenNextStep = false
        lteHistory.removeAll()
        adaptiveStep = 0
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

    /// Steps the simulation forward by exactly `dt` seconds.
    ///
    /// Inside the step the solver lands exactly on every source corner (pulse edges, PWL points),
    /// then takes a short backward-Euler step before handing back to the trapezoidal rule.
    public func step(dt: Double? = nil) -> SimulationStepResult {
        let h = dt ?? timeStep
        layoutAuxiliaryUnknowns()

        // If no nodes, return empty result
        if totalNodes == 0 {
            currentTime += h
            return SimulationStepResult(time: currentTime, nodeVoltages: [0: 0.0], converged: true, iterations: 0, isSingular: false)
        }

        let tEnd = currentTime + h
        let minStep = max(h * 1e-9, 1e-15)
        var last = SubstepOutcome(voltages: [0: 0.0], converged: true, singular: false, iterations: 0)
        var iterations = 0
        var allConverged = true
        var substeps = 0
        // Start small after a reset or a corner (no history to estimate the error yet) and let it grow.
        if adaptiveStep <= 0 { adaptiveStep = h * Self.adaptiveStartFraction }
        adaptiveStep = min(adaptiveStep, h)
        let maxSubsteps = adaptiveTimestep ? 20_000 : 256
        while currentTime < tEnd - minStep && substeps < maxSubsteps {
            substeps += 1
            var target = tEnd
            if adaptiveTimestep { target = min(tEnd, currentTime + adaptiveStep) }
            // Just after a corner: a short backward-Euler step, so neither rule smears the edge.
            if shortenNextStep { target = min(target, currentTime + max(h * Self.postBreakpointFraction, minStep)) }
            var landsOnBreakpoint = false
            if let bp = nextBreakpoint(after: currentTime + minStep), bp < target + minStep {
                target = bp > tEnd - minStep ? tEnd : bp
                landsOnBreakpoint = true
            }
            last = advance(to: target, minAdaptiveStep: h * 1e-4)
            iterations += last.iterations
            if last.rejected { continue } // local truncation error too large: retry with the smaller step
            allConverged = allConverged && last.converged
            if last.singular { break }
            shortenNextStep = landsOnBreakpoint
            if landsOnBreakpoint {
                needsBackwardEulerStep = true
                lteHistory.removeAll() // divided differences across a corner mean nothing
                adaptiveStep = h * Self.adaptiveStartFraction
            }
        }
        currentTime = tEnd
        updateWireCurrents()

        return SimulationStepResult(
            time: currentTime,
            nodeVoltages: last.voltages,
            converged: allConverged,
            iterations: iterations,
            isSingular: last.singular
        )
    }

    /// First adaptive sub-step after a reset or corner, as a fraction of the step.
    static let adaptiveStartFraction = 1.0 / 32.0

    /// How many times a sub-step may be halved when Newton fails before falling back to gmin stepping.
    static let maxStepCuts = 5

    /// Length of the backward-Euler step taken right after a breakpoint, as a fraction of the step.
    static let postBreakpointFraction = 0.05

    struct SubstepOutcome {
        var voltages: [Int: Double]
        var converged: Bool
        var singular: Bool
        var iterations: Int
        /// The solve was fine but its truncation error was not; nothing was accepted.
        var rejected = false
    }

    // MARK: - Local truncation error

    /// Trapezoidal LTE estimate: h³/12 · |x'''|, with x''' from the third divided difference
    /// over the last three accepted points and the candidate. Returns (acceptable, suggested step).
    private func truncationCheck(candidate x: [Double], at t: Double, h: Double) -> (Bool, Double) {
        guard lteHistory.count >= 3 else { return (true, h) }
        let pts = Array(lteHistory.suffix(3)) + [(t, Array(x.prefix(totalNodes)))]
        let ts = pts.map { $0.0 }
        guard ts[1] > ts[0], ts[2] > ts[1], ts[3] > ts[2] else { return (true, h) }
        var worstRatio = 0.0
        for i in 0..<totalNodes {
            let xs = pts.map { i < $0.1.count ? $0.1[i] : 0 }
            let d1 = (0..<3).map { (xs[$0 + 1] - xs[$0]) / (ts[$0 + 1] - ts[$0]) }
            let d2 = (0..<2).map { (d1[$0 + 1] - d1[$0]) / (ts[$0 + 2] - ts[$0]) }
            let d3 = (d2[1] - d2[0]) / (ts[3] - ts[0])
            let lte = h * h * h / 12.0 * abs(6.0 * d3)
            let tol = truncationErrorFactor * (tolerances.reltol * max(abs(xs[3]), abs(xs[2])) + tolerances.vntol)
            worstRatio = max(worstRatio, lte / tol)
        }
        let factor = worstRatio > 0 ? 0.9 * pow(1.0 / worstRatio, 1.0 / 3.0) : 2.0
        return (worstRatio <= 1.0, h * min(max(factor, 0.125), 2.0))
    }

    /// Solves the circuit at `target` and accepts it as the new state.
    private func advance(to target: Double, depth: Int = 0, minAdaptiveStep: Double = 0) -> SubstepOutcome {
        let hs = target - currentTime
        let size = totalNodes + auxCount
        // Warm start from the last accepted point: Newton then only has to follow the change over one step.
        let x0 = solution.count == size ? solution : [Double](repeating: 0, count: size)
        let mode: StampMode = (integrationMethod == .backwardEuler || needsBackwardEulerStep) ? .backwardEuler : .trapezoidal
        var outcome = newtonSolve(time: target, h: hs, mode: mode, initial: x0)
        if !outcome.converged && !outcome.singular {
            // Time-step cut: two half steps usually converge where one full step did not.
            if depth < Self.maxStepCuts {
                let mid = currentTime + hs / 2
                let first = advance(to: mid, depth: depth + 1)
                if first.singular { return first }
                let second = advance(to: target, depth: depth + 1)
                return SubstepOutcome(voltages: second.voltages, converged: first.converged && second.converged,
                                      singular: second.singular, iterations: first.iterations + second.iterations + outcome.iterations)
            }
            let (rescued, aid) = robustSolve(time: target, h: hs, mode: mode, initial: x0)
            lastConvergenceAid = aid
            outcome = rescued
        }

        if adaptiveTimestep && depth == 0 && outcome.converged && mode == .trapezoidal {
            let (ok, suggested) = truncationCheck(candidate: outcome.x, at: target, h: hs)
            if !ok && hs > minAdaptiveStep {
                adaptiveStep = max(suggested, minAdaptiveStep)
                return SubstepOutcome(voltages: [:], converged: true, singular: false, iterations: outcome.iterations, rejected: true)
            }
            adaptiveStep = max(suggested, minAdaptiveStep)
        }

        isSolutionValid = !outcome.singular
        if !outcome.singular {
            lteHistory.append((target, Array(outcome.x.prefix(totalNodes))))
            if lteHistory.count > 3 { lteHistory.removeFirst() }
            solution = outcome.x
            needsBackwardEulerStep = false
        }
        currentTime = target
        let x = outcome.singular ? x0 : outcome.x
        let voltages = nodeVoltageMap(x)
        // Update runtime component states (currents, voltages, companion history, instrument readings)
        updateComponentRuntimeStates(voltages: voltages, x: x, dt: hs, mode: mode)
        return SubstepOutcome(voltages: voltages, converged: outcome.converged, singular: outcome.singular, iterations: outcome.iterations)
    }

    /// Earliest source corner strictly after `t`, across every source in the circuit.
    func nextBreakpoint(after t: Double) -> Double? {
        var best: Double?
        for comp in circuit.components {
            if let bp = SourceWaveforms.nextBreakpoint(comp, after: t), bp > t, bp < (best ?? .infinity) {
                best = bp
            }
        }
        return best
    }

    // MARK: - Newton-Raphson

    struct NewtonOutcome {
        var x: [Double]
        var converged: Bool
        var singular: Bool
        var iterations: Int
    }

    /// Solves the (possibly non-linear) circuit equations at one time point.
    /// `gmin` adds a conductance from every node to ground; `sourceScale` scales every independent source.
    func newtonSolve(time t: Double, h: Double, mode: StampMode, initial x0: [Double],
                     gmin: Double = 0, sourceScale: Double = 1) -> NewtonOutcome {
        var x = x0
        let nonlinear = circuit.components.contains { Self.isNonlinear($0.kind) }
        let memory = IterationMemory()
        var iterations = 0
        while iterations < tolerances.maxIterations {
            iterations += 1
            memory.limited = false
            var sys = MNASystem(nodeCount: totalNodes, auxCount: auxCount)
            let ctx = StampContext(x: x, nodeCount: totalNodes, time: t, h: h, mode: mode,
                                   sourceScale: sourceScale, memory: memory)
            for comp in circuit.components {
                stamp(comp, nodes: nodeIndices(for: comp), into: &sys, ctx: ctx)
            }
            sys.shuntAllNodes(gmin)
            guard let xNew = sys.A.solve(b: sys.b) else {
                return NewtonOutcome(x: x, converged: false, singular: true, iterations: iterations)
            }
            // Converged only when nothing moved and no junction step had to be limited (SPICE "noncon").
            let done = !nonlinear || (iterations > 1 && !memory.limited && hasConverged(old: x, new: xNew))
            x = xNew
            if done {
                return NewtonOutcome(x: x, converged: true, singular: false, iterations: iterations)
            }
        }
        return NewtonOutcome(x: x, converged: false, singular: false, iterations: iterations)
    }

    /// Newton with the two SPICE homotopies as fallbacks: gmin stepping, then source stepping.
    func robustSolve(time t: Double, h: Double, mode: StampMode, initial x0: [Double]) -> (NewtonOutcome, ConvergenceAid) {
        let direct = newtonSolve(time: t, h: h, mode: mode, initial: x0)
        if direct.converged || direct.singular { return (direct, .none) }

        // gmin stepping: start with every node shunted by 10 mS and relax the shunt a decade at a time.
        var x = x0
        var total = direct.iterations
        var ok = true
        var g = 1e-2
        while g >= 1e-13 {
            let r = newtonSolve(time: t, h: h, mode: mode, initial: x, gmin: g)
            total += r.iterations
            if !r.converged { ok = false; break }
            x = r.x
            g /= 10
        }
        if ok {
            var r = newtonSolve(time: t, h: h, mode: mode, initial: x)
            r.iterations += total
            if r.converged { return (r, .gminStepping) }
        }

        // Source stepping: ramp every independent source up from zero, halving the step on failure.
        x = [Double](repeating: 0, count: x0.count)
        var scale = 0.0
        var stepSize = 0.1
        while scale < 1 {
            let next = min(1, scale + stepSize)
            let r = newtonSolve(time: t, h: h, mode: mode, initial: x, sourceScale: next)
            total += r.iterations
            if r.converged {
                x = r.x
                scale = next
                stepSize = min(stepSize * 2, 0.25)
            } else {
                stepSize /= 2
                if stepSize < 1e-4 { break }
            }
        }
        if scale >= 1 {
            return (NewtonOutcome(x: x, converged: true, singular: false, iterations: total), .sourceStepping)
        }
        var fail = direct
        fail.iterations = total
        return (fail, .none)
    }

    /// Which homotopy, if any, the last operating point needed.
    public enum ConvergenceAid: String, Sendable {
        case none = "Direct Newton"
        case gminStepping = "gmin stepping"
        case sourceStepping = "Source stepping"
    }

    /// DC operating point (.OP): capacitors open, inductors shorted, sources at their present value.
    ///
    /// Tries plain Newton first, then gmin stepping, then source stepping. With `apply` the result
    /// becomes the initial condition for the transient (capacitor voltages, inductor currents).
    @discardableResult
    public func operatingPoint(apply: Bool = false) -> (result: SimulationStepResult, aid: ConvergenceAid) {
        layoutAuxiliaryUnknowns()
        guard totalNodes > 0 else {
            return (SimulationStepResult(time: currentTime, nodeVoltages: [0: 0], converged: true, iterations: 0, isSingular: false), .none)
        }
        let size = totalNodes + auxCount
        let x0 = solution.count == size ? solution : [Double](repeating: 0, count: size)
        let (outcome, aid) = robustSolve(time: currentTime, h: timeStep, mode: .dc, initial: x0)
        lastConvergenceAid = aid
        let voltages = nodeVoltageMap(outcome.x)
        if apply && outcome.converged {
            solution = outcome.x
            isSolutionValid = true
            updateComponentRuntimeStates(voltages: voltages, x: outcome.x, dt: timeStep, mode: .dc)
            needsBackwardEulerStep = true
        }
        let result = SimulationStepResult(time: currentTime, nodeVoltages: voltages, converged: outcome.converged,
                                          iterations: outcome.iterations, isSingular: outcome.singular)
        return (result, aid)
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
        case .diode, .led, .zenerDiode, .schottkyDiode, .bjtNPN, .bjtPNP, .opAmp, .abmVoltage, .abmCurrent:
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
            // Only one symbol per rail kind drives the shared net; a second ideal source in parallel would be singular.
            if comp.kind.isSupplyRail && !circuit.isDrivingRail(comp) { continue }
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
        case .opAmp, .vcvs, .inductor:
            return 1
        case _ where comp.kind.isWaveformVoltageSource:
            return 1
        case .threePhaseWye:
            return 3
        case .threePhaseDelta:
            return 2
        case .vccRail, .vddRail, .veeRail, .vssRail:
            return 1
        case .ccvs:
            return 2
        case .cccs:
            return 1
        case .abmVoltage:
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
            // Companion model: conductance G in parallel with a history current source.
            //   backward Euler: i = C/h (v - v_n)
            //   trapezoidal:    i = 2C/h (v - v_n) - i_n
            let c = max(comp.value, 1e-15)
            switch ctx.mode {
            case .dc:
                break // open circuit
            case .backwardEuler:
                let geq = c / ctx.h
                sys.conductance(node(0), node(1), geq)
                sys.current(from: node(1), to: node(0), geq * comp.runtimePrevVoltage)
            case .trapezoidal:
                let geq = 2.0 * c / ctx.h
                sys.conductance(node(0), node(1), geq)
                sys.current(from: node(1), to: node(0), geq * comp.runtimePrevVoltage + comp.runtimePrevCurrent)
            }

        case _ where comp.kind.isWaveformCurrentSource:
            // Current leaves the OUT terminal (pin 0), the way the symbol's arrow points.
            sys.current(from: node(1), to: node(0), ctx.sourceScale * SourceWaveforms.value(comp, at: ctx.time))

        case .diode, .led, .schottkyDiode:
            stampJunction(comp, anode: node(0), cathode: node(1), into: &sys, ctx: ctx)

        case .zenerDiode:
            stampZener(comp, anode: node(0), cathode: node(1), into: &sys, ctx: ctx)

        case .bjtNPN, .bjtPNP:
            stampBJT(comp, nodes: [node(0), node(1), node(2)], into: &sys, ctx: ctx, pnp: comp.kind == .bjtPNP)

        case .abmCurrent:
            stampBehavioural(comp, nodes: n, into: &sys, ctx: ctx, branch: nil)
        case .vccs:
            // Voltage-Controlled Current Source: I = gm * (V_ctrl+ - V_ctrl-), pushed out of OUT+
            // (the terminal the diamond's arrow points to).
            sys.transconductance(from: node(1), to: node(0), cp: node(2), cm: node(3), comp.value)

        default:
            break
        }

        guard let k = auxStart[comp.id] else { return }
        switch comp.kind {
        case .inductor:
            // Branch current i (pin 0 -> pin 1) is an unknown, so the inductor is exact at DC (a short):
            //   backward Euler: v - (L/h) i = -(L/h) i_n
            //   trapezoidal:    v - (2L/h) i = -(2L/h) i_n - v_n
            let l = max(comp.value, 1e-12)
            sys.branch(k, plus: node(0), minus: node(1))
            switch ctx.mode {
            case .dc:
                break
            case .backwardEuler:
                sys.branchDependsOnAux(k, aux: k, -l / ctx.h)
                sys.setBranchRHS(k, -l / ctx.h * comp.runtimePrevCurrent)
            case .trapezoidal:
                sys.branchDependsOnAux(k, aux: k, -2.0 * l / ctx.h)
                sys.setBranchRHS(k, -2.0 * l / ctx.h * comp.runtimePrevCurrent - comp.runtimePrevVoltage)
            }

        case _ where comp.kind.isWaveformVoltageSource:
            sys.voltageSource(k, plus: node(0), minus: node(1), value: ctx.sourceScale * SourceWaveforms.value(comp, at: ctx.time))

        case .vcvs:
            // V(out+) - V(out-) = gain * (V(ctrl+) - V(ctrl-))
            sys.branch(k, plus: node(0), minus: node(1))
            sys.branchDependsOnNode(k, node: node(2), -comp.value)
            sys.branchDependsOnNode(k, node: node(3), comp.value)

        case .threePhaseWye:
            // Three phase windings from the neutral: A-N, B-N, C-N.
            for i in 0..<3 {
                sys.voltageSource(k + i, plus: node(i), minus: node(3),
                                  value: ctx.sourceScale * SourceWaveforms.threePhaseValue(comp, phase: i, at: ctx.time))
            }

        case .threePhaseDelta:
            // Windings A-B and B-C; an ideal delta's C-A winding is then fixed (and would make the loop singular).
            for i in 0..<2 {
                sys.voltageSource(k + i, plus: node(i), minus: node(i + 1),
                                  value: ctx.sourceScale * SourceWaveforms.threePhaseValue(comp, phase: i, at: ctx.time))
            }
        case .vccRail, .vddRail, .veeRail, .vssRail:
            sys.voltageSource(k, plus: node(0), minus: 0, value: ctx.sourceScale * comp.value)
        case .ccvs:
            // Row k: sense branch V(I+) - V(I-) = 0, its current i_s is the control.
            // Row k+1: V(OUT+) - V(OUT-) - r·i_s = 0.
            sys.voltageSource(k, plus: node(2), minus: node(3), value: 0)
            sys.branch(k + 1, plus: node(0), minus: node(1))
            sys.branchDependsOnAux(k + 1, aux: k, -comp.value)

        case .cccs:
            // Sense branch, then β·i_s pushed out of OUT+ (the arrow tip).
            sys.voltageSource(k, plus: node(2), minus: node(3), value: 0)
            sys.currentControlledCurrent(from: node(1), to: node(0), auxColumn: k, comp.value)
        case .abmVoltage:
            stampBehavioural(comp, nodes: n, into: &sys, ctx: ctx, branch: k)
        case .opAmp:
            // Macro-model: output driven against ground with open-loop gain A = 1e5, clipped at the rails.
            // In the linear region the gain is stamped as a VCVS so Newton sees the true slope.
            let gain = 1e5
            let rail = comp.secondaryValue > 0 ? comp.secondaryValue : 15.0
            let open = gain * (ctx.v(node(1)) - ctx.v(node(0)))
            if abs(open) < rail {
                sys.branch(k, plus: node(2), minus: 0)
                sys.branchDependsOnNode(k, node: node(1), -gain)
                sys.branchDependsOnNode(k, node: node(0), gain)
            } else {
                sys.voltageSource(k, plus: node(2), minus: 0, value: open > 0 ? rail : -rail)
            }

        case .logicAND, .logicOR, .logicNOT, .logicNAND, .logicNOR, .logicXOR, .logicXNOR, .logicBuffer:
            sys.voltageSource(k, plus: n.last ?? 0, minus: 0, value: evaluateLogicGate(comp: comp, nodes: n, ctx: ctx))

        default:
            break
        }
    }

    // MARK: - Behavioural (ABM) sources

    /// A circuit quantity written as a linear function of the unknowns: Σ coef·x[col] + constant.
    struct LinearForm {
        var terms: [(col: Int, coef: Double)] = []
        var constant: Double = 0

        func value(_ x: [Double]) -> Double {
            terms.reduce(constant) { $0 + $1.coef * ($1.col < x.count ? x[$1.col] : 0) }
        }

        static func - (a: LinearForm, b: LinearForm) -> LinearForm {
            LinearForm(terms: a.terms + b.terms.map { ($0.col, -$0.coef) }, constant: a.constant - b.constant)
        }

        static func node(_ n: Int, count: Int) -> LinearForm {
            n > 0 && n <= count ? LinearForm(terms: [(n - 1, 1)]) : LinearForm()
        }
    }

    /// "R1.0" -> ("R1", 0): a part name with an optional pin index.
    static func splitPinReference(_ name: String) -> (String, Int?) {
        if let dot = name.lastIndex(of: "."), let pin = Int(name[name.index(after: dot)...]) {
            return (String(name[..<dot]), pin)
        }
        return (name, nil)
    }

    /// How an expression reference reads the solution vector.
    func linearForm(for ref: Expression.Reference) -> LinearForm {
        switch ref {
        case .nodeVoltage(let n):
            return .node(n, count: totalNodes)
        case .difference(let a, let b):
            return linearForm(for: a) - linearForm(for: b)
        case .partVoltage(let name):
            let (part, pin) = Self.splitPinReference(name)
            guard let c = circuit.components.first(where: { $0.designator == part }) else { return LinearForm() }
            let n = nodeIndices(for: c)
            if let pin { return pin < n.count ? .node(n[pin], count: totalNodes) : LinearForm() }
            if n.count >= 2 { return .node(n[0], count: totalNodes) - .node(n[1], count: totalNodes) }
            return .node(n.first ?? 0, count: totalNodes)
        case .partCurrent(let name):
            guard let c = circuit.components.first(where: { $0.designator == name }) else { return LinearForm() }
            return currentForm(of: c)
        }
    }

    /// Current of a part in the same sense as its runtimeCurrent (through it pin 0 -> pin 1; delivered for sources).
    private func currentForm(of c: CircuitComponent) -> LinearForm {
        let n = nodeIndices(for: c)
        if let k = auxStart[c.id] {
            let col = totalNodes + k
            switch c.kind {
            case .inductor: return LinearForm(terms: [(col, 1)])
            case .ccvs: return LinearForm(terms: [(col + 1, -1)])
            case .cccs: return LinearForm(terms: [(col, c.value)])
            default: return LinearForm(terms: [(col, -1)])
            }
        }
        if n.count >= 2, c.kind.isLinearResistive || c.kind == .multimeter, let r = resistance(of: c) {
            return LinearForm(terms: [(n[0] - 1, 1 / r), (n[1] - 1, -1 / r)].filter { $0.0 >= 0 })
        }
        if c.kind.isWaveformCurrentSource { return LinearForm(constant: SourceWaveforms.value(c, at: currentTime)) }
        // Anything else (capacitors, junctions) is read from the last accepted step.
        return LinearForm(constant: c.runtimeCurrent)
    }

    /// Value of an ABM expression on a full solution vector.
    func behaviouralValue(_ comp: CircuitComponent, x: [Double], time: Double) -> Double {
        guard let parsed = ExpressionCache.shared.expression(for: comp.textValue) else { return 0 }
        let refs = parsed.references.map { linearForm(for: $0).value(x) }
        return parsed.root.evaluate(refs: refs, time: time)
    }

    /// Newton linearisation of an ABM source: f(x) ≈ f(x0) + Σ ∂f/∂x_j (x_j − x0_j), with the partials
    /// from central differences on each reference. Voltage form on branch `k`, current form otherwise.
    private func stampBehavioural(_ comp: CircuitComponent, nodes n: [Int], into sys: inout MNASystem, ctx: StampContext, branch k: Int?) {
        let outP = n.count > 0 ? n[0] : 0, outM = n.count > 1 ? n[1] : 0
        var gradient: [Int: Double] = [:]
        var f0 = 0.0
        if let parsed = ExpressionCache.shared.expression(for: comp.textValue) {
            let forms = parsed.references.map { linearForm(for: $0) }
            let r0 = forms.map { $0.value(ctx.x) }
            f0 = parsed.root.evaluate(refs: r0, time: ctx.time)
            for (i, form) in forms.enumerated() where !form.terms.isEmpty {
                let d = 1e-6 * max(1, abs(r0[i]))
                var up = r0, down = r0
                up[i] += d; down[i] -= d
                let slope = (parsed.root.evaluate(refs: up, time: ctx.time) - parsed.root.evaluate(refs: down, time: ctx.time)) / (2 * d)
                guard slope.isFinite, slope != 0 else { continue }
                for t in form.terms { gradient[t.col, default: 0] += slope * t.coef }
            }
        }
        let constant = gradient.reduce(f0) { $0 - $1.value * (($1.key < ctx.x.count) ? ctx.x[$1.key] : 0) }
        if let k {
            sys.branch(k, plus: outP, minus: outM)
            for (col, g) in gradient { sys.A[sys.auxIndex(k), col] -= g }
            sys.setBranchRHS(k, constant)
        } else {
            // Current pushed out of OUT (pin 0): flows through the part from pin 1 to pin 0.
            for (col, g) in gradient {
                if outM > 0 { sys.A[outM - 1, col] += g }
                if outP > 0 { sys.A[outP - 1, col] -= g }
            }
            sys.current(from: outM, to: outP, constant)
        }
    }

    // MARK: - Device models

    struct JunctionModel {
        let saturation: Double
        let emissionCoefficient: Double
        var vt: Double { MNASolver.Vt * emissionCoefficient }
        /// Voltage above which SPICE starts limiting Newton steps: vt·ln(vt / (√2·Is)).
        var vcrit: Double { vt * log(vt / (2.0.squareRoot() * saturation)) }

        /// Current and conductance at `vd`, with the exponent capped so a wild iterate cannot overflow.
        func evaluate(_ vd: Double) -> (i: Double, g: Double) {
            let arg = vd / vt
            if arg > 80 {
                // Continue linearly past e^80 so the iterate is still pulled back.
                let e = exp(80.0)
                return (saturation * (e * (1 + arg - 80) - 1), saturation / vt * e)
            }
            let e = exp(arg)
            return (saturation * (e - 1), saturation / vt * e)
        }
    }

    static func junctionModel(for comp: CircuitComponent) -> JunctionModel {
        switch comp.kind {
        case .led:
            // Is chosen so the knee sits at the colour's forward voltage (about 10 mA there).
            let vf = comp.ledColor.forwardVoltage
            return JunctionModel(saturation: 0.01 / exp(vf / (Vt * 2.0)), emissionCoefficient: 2.0)
        case .schottkyDiode:
            return JunctionModel(saturation: 1e-8, emissionCoefficient: 1.0)
        default:
            return JunctionModel(saturation: diodeIs, emissionCoefficient: 1.0)
        }
    }

    /// Minimum conductance SPICE puts across every junction so a reverse-biased one never floats.
    static let junctionGmin = 1e-12

    /// SPICE pnjlim: keeps a Newton step on an exponential junction from overshooting.
    static func limitJunctionVoltage(_ vnew: Double, old vold: Double, vt: Double, vcrit: Double) -> (Double, Bool) {
        guard vnew > vcrit, abs(vnew - vold) > 2 * vt else { return (vnew, false) }
        if vold > 0 {
            let arg = 1 + (vnew - vold) / vt
            return (arg > 0 ? vold + vt * log(arg) : vcrit, true)
        }
        return (vt * log(vnew / vt), true)
    }

    /// Junction voltage for this iteration after limiting against the last one.
    private func limitedJunction(_ comp: CircuitComponent, slot: Int, raw: Double, model: JunctionModel, ctx: StampContext) -> Double {
        var v = raw
        if let old = ctx.memory.junction(comp.id, slot) {
            let (lim, didLimit) = Self.limitJunctionVoltage(raw, old: old, vt: model.vt, vcrit: model.vcrit)
            if didLimit { ctx.memory.limited = true }
            v = lim
        }
        ctx.memory.setJunction(comp.id, slot, v)
        return v
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
        let vd = limitedJunction(comp, slot: 0, raw: ctx.v(nA) - ctx.v(nK), model: model, ctx: ctx)
        let (id, gd) = model.evaluate(vd)
        let g = gd + Self.junctionGmin
        sys.conductance(nA, nK, g)
        sys.current(from: nA, to: nK, id + Self.junctionGmin * vd - g * vd)
    }

    /// Zener: forward PN junction plus an exponential reverse breakdown of 1 mA at Vz.
    static let zenerBreakdownCurrent = 1e-3

    static func zenerCurrent(_ vd: Double, vz: Double) -> (i: Double, g: Double) {
        let fwd = junctionModel(for: CircuitComponent(kind: .diode, designator: "")).evaluate(vd)
        let arg = min(-(vd + vz) / Vt, 80)
        let e = exp(arg)
        let iRev = zenerBreakdownCurrent * e
        return (fwd.i - iRev + junctionGmin * vd, fwd.g + zenerBreakdownCurrent / Vt * e + junctionGmin)
    }

    private func stampZener(_ comp: CircuitComponent, anode nA: Int, cathode nK: Int, into sys: inout MNASystem, ctx: StampContext) {
        let vz = comp.secondaryValue > 0 ? comp.secondaryValue : 5.1
        let raw = ctx.v(nA) - ctx.v(nK)
        var vd = raw
        if let old = ctx.memory.junction(comp.id, 0) {
            if raw < min(0, -vz + 10 * Self.Vt) {
                // Limit the breakdown junction the same way, measured from -Vz (SPICE does this too).
                let vcritRev = Self.Vt * log(Self.Vt / (2.0.squareRoot() * Self.zenerBreakdownCurrent))
                let (lim, did) = Self.limitJunctionVoltage(-(raw + vz), old: -(old + vz), vt: Self.Vt, vcrit: vcritRev)
                vd = -(lim + vz)
                if did { ctx.memory.limited = true }
            } else {
                let model = Self.junctionModel(for: CircuitComponent(kind: .diode, designator: ""))
                let (lim, did) = Self.limitJunctionVoltage(raw, old: old, vt: model.vt, vcrit: model.vcrit)
                vd = lim
                if did { ctx.memory.limited = true }
            }
        }
        ctx.memory.setJunction(comp.id, 0, vd)
        let (i, g) = Self.zenerCurrent(vd, vz: vz)
        sys.conductance(nA, nK, g)
        sys.current(from: nA, to: nK, i - g * vd)
    }

    /// Transistor: base-emitter junction plus a collector current β·I_B, linearised for Newton.
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
        let model = JunctionModel(saturation: 1e-14, emissionCoefficient: 1.0)
        // Work with the forward junction voltage: V_BE for NPN, V_EB for PNP.
        let (jp, jn) = pnp ? (nE, nB) : (nB, nE)
        let vj = limitedJunction(comp, slot: 0, raw: ctx.v(jp) - ctx.v(jn), model: model, ctx: ctx)
        let (ib, gj) = model.evaluate(vj)
        let g = gj + Self.junctionGmin
        sys.conductance(jp, jn, g)
        sys.current(from: jp, to: jn, ib + Self.junctionGmin * vj - g * vj)
        // I_C = β·I_B(v_j) ≈ β·(I_B0 + g_j·(v_j − v_j0)), flowing C -> E (NPN) or E -> C (PNP).
        let (from, to) = pnp ? (nE, nC) : (nC, nE)
        sys.current(from: from, to: to, beta * (ib - gj * vj))
        sys.transconductance(from: from, to: to, cp: jp, cm: jn, beta * gj)
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

    private func updateComponentRuntimeStates(voltages: [Int: Double], x: [Double], dt: Double, mode: StampMode) {
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
                switch mode {
                case .dc: comp.runtimeCurrent = 0
                case .backwardEuler: comp.runtimeCurrent = c * (vDrop - comp.runtimePrevVoltage) / dt
                case .trapezoidal: comp.runtimeCurrent = 2.0 * c * (vDrop - comp.runtimePrevVoltage) / dt - comp.runtimePrevCurrent
                }
                comp.runtimePrevVoltage = vDrop
                comp.runtimePrevCurrent = comp.runtimeCurrent

            case .inductor:
                if let k = auxStart[comp.id], totalNodes + k < x.count {
                    comp.runtimeCurrent = x[totalNodes + k]
                }
                comp.runtimePrevCurrent = comp.runtimeCurrent
                comp.runtimePrevVoltage = vDrop

            case .diode, .led, .schottkyDiode:
                comp.runtimeCurrent = Self.junctionModel(for: comp).evaluate(vDrop).i
                comp.runtimePrevVoltage = vDrop

            case .zenerDiode:
                let vz = comp.secondaryValue > 0 ? comp.secondaryValue : 5.1
                comp.runtimeCurrent = Self.zenerCurrent(vDrop, vz: vz).i
                comp.runtimePrevVoltage = vDrop

            case .threePhaseWye, .threePhaseDelta:
                // Line currents delivered out of A, B, C.
                if let k = auxStart[comp.id], totalNodes + k + (comp.kind == .threePhaseWye ? 2 : 1) < x.count {
                    let a = x[totalNodes + k], b = x[totalNodes + k + 1]
                    if comp.kind == .threePhaseWye {
                        comp.runtimeState = [-a, -b, -x[totalNodes + k + 2]]
                    } else {
                        comp.runtimeState = [-a, a - b, b]
                    }
                    comp.runtimeCurrent = comp.runtimeState[0]
                }
            case .vccRail, .vddRail, .veeRail, .vssRail:
                comp.runtimeVoltageDrop = v(0)
                if let k = auxStart[comp.id], totalNodes + k < x.count {
                    comp.runtimeCurrent = -x[totalNodes + k]
                } else {
                    comp.runtimeCurrent = 0
                }
            case .ccvs, .cccs:
                if let k = auxStart[comp.id], totalNodes + k + (comp.kind == .ccvs ? 1 : 0) < x.count {
                    let sense = x[totalNodes + k]
                    comp.runtimeState = [sense]
                    comp.runtimeCurrent = comp.kind == .ccvs ? -x[totalNodes + k + 1] : comp.value * sense
                }
            case .abmVoltage:
                if let k = auxStart[comp.id], totalNodes + k < x.count { comp.runtimeCurrent = -x[totalNodes + k] }
                comp.runtimeReading = vDrop

            case .abmCurrent:
                comp.runtimeCurrent = behaviouralValue(comp, x: x, time: currentTime)
                comp.runtimeReading = comp.runtimeCurrent
            case .ohmmeter:
                let test = ohmmeterTestCurrent(for: comp)
                comp.runtimeCurrent = test
                comp.runtimeReading = abs(vDrop) / test

            case .probe:
                comp.runtimeCurrent = 0.0
                comp.runtimeReading = v(0)

            case _ where comp.kind.isWaveformCurrentSource:
                comp.runtimeCurrent = SourceWaveforms.value(comp, at: currentTime)

            case _ where comp.kind.isWaveformVoltageSource || comp.kind == .vcvs:
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
    }

    /// Wire currents drive the moving-dot animation; refreshed once per step.
    private func updateWireCurrents() {
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

    /// Averaging time for AC meters: five periods of the slowest periodic source, or nil in a DC circuit.
    var acAveragingWindow: Double? {
        let freqs = circuit.components.compactMap { SourceWaveforms.fundamentalFrequency($0) }
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
