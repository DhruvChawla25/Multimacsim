import Foundation

/// SPICE-style convergence criteria for the Newton-Raphson loop.
public struct SolverTolerances: Sendable, Equatable {
    /// Relative tolerance on every unknown (SPICE RELTOL).
    public var reltol: Double = 1e-3
    /// Absolute tolerance on node voltages, volts (SPICE VNTOL).
    public var vntol: Double = 1e-6
    /// Absolute tolerance on branch currents, amps (SPICE ABSTOL).
    public var abstol: Double = 1e-12
    /// Newton iterations allowed at one time point before the step is retried.
    public var maxIterations: Int = 100

    public init() {}
}

/// How capacitors and inductors are discretised in time.
public enum IntegrationMethod: String, CaseIterable, Sendable {
    /// First order, heavily damped: rings never, but bleeds energy out of LC circuits.
    case backwardEuler = "Backward Euler"
    /// Second order and energy-conserving (SPICE default). The solver still takes one
    /// backward-Euler step at start-up and after every source edge, so it does not ring.
    case trapezoidal = "Trapezoidal"
}

/// What the reactive parts look like for one solve.
enum StampMode: Equatable {
    /// DC operating point: capacitors open, inductors short.
    case dc
    case backwardEuler
    case trapezoidal
}

/// The linear system A·x = b assembled for one Newton iteration.
///
/// Unknowns are ordered node 1...N (index node-1), then the auxiliary branch currents.
/// Node 0 is ground and never appears in the matrix.
struct MNASystem {
    var A: Matrix
    var b: [Double]
    let nodeCount: Int

    init(nodeCount: Int, auxCount: Int) {
        let size = nodeCount + auxCount
        self.nodeCount = nodeCount
        self.A = Matrix(rows: size, cols: size)
        self.b = [Double](repeating: 0, count: size)
    }

    /// Matrix index of an auxiliary unknown.
    @inline(__always) func auxIndex(_ k: Int) -> Int { nodeCount + k }

    /// Adds `value` at (row, col) where both are node numbers (0 = ground, skipped).
    @inline(__always) mutating func addNode(_ r: Int, _ c: Int, _ value: Double) {
        guard r > 0, c > 0 else { return }
        A[r - 1, c - 1] += value
    }

    /// Conductance g between two nodes.
    mutating func conductance(_ n1: Int, _ n2: Int, _ g: Double) {
        addNode(n1, n1, g)
        addNode(n2, n2, g)
        addNode(n1, n2, -g)
        addNode(n2, n1, -g)
    }

    /// A constant current `i` flowing through an element from node `from` to node `to`
    /// (it leaves the `from` net and is delivered into the `to` net).
    mutating func current(from: Int, to: Int, _ i: Double) {
        if from > 0 { b[from - 1] -= i }
        if to > 0 { b[to - 1] += i }
    }

    /// Current gm·(V(cp) − V(cm)) flowing through an element from `from` to `to`.
    mutating func transconductance(from: Int, to: Int, cp: Int, cm: Int, _ gm: Double) {
        addNode(from, cp, gm)
        addNode(from, cm, -gm)
        addNode(to, cp, -gm)
        addNode(to, cm, gm)
    }

    /// Current k·x[aux j] flowing through an element from `from` to `to`.
    mutating func currentControlledCurrent(from: Int, to: Int, auxColumn j: Int, _ k: Double) {
        let c = auxIndex(j)
        if from > 0 { A[from - 1, c] += k }
        if to > 0 { A[to - 1, c] -= k }
    }

    /// Ties branch-current unknown `k` to the nodes it flows between (into `plus`, out of `minus`)
    /// and writes V(plus) − V(minus) on the left of row k. The caller fills in the rest of the row.
    mutating func branch(_ k: Int, plus: Int, minus: Int) {
        let r = auxIndex(k)
        if plus > 0 {
            A[plus - 1, r] += 1
            A[r, plus - 1] += 1
        }
        if minus > 0 {
            A[minus - 1, r] -= 1
            A[r, minus - 1] -= 1
        }
    }

    /// Ideal voltage source V(plus) − V(minus) = value on branch k.
    mutating func voltageSource(_ k: Int, plus: Int, minus: Int, value: Double) {
        branch(k, plus: plus, minus: minus)
        b[auxIndex(k)] = value
    }

    /// Adds `coef`·V(node) to the left side of branch row k.
    mutating func branchDependsOnNode(_ k: Int, node: Int, _ coef: Double) {
        guard node > 0 else { return }
        A[auxIndex(k), node - 1] += coef
    }

    /// Adds `coef`·x[aux j] to the left side of branch row k.
    mutating func branchDependsOnAux(_ k: Int, aux j: Int, _ coef: Double) {
        A[auxIndex(k), auxIndex(j)] += coef
    }

    mutating func setBranchRHS(_ k: Int, _ value: Double) {
        b[auxIndex(k)] = value
    }

    /// Tiny conductance from every node to ground (gmin stepping / floating-node guard).
    mutating func shuntAllNodes(_ g: Double) {
        guard g > 0 else { return }
        for i in 0..<nodeCount { A[i, i] += g }
    }
}

/// Everything a device needs to stamp itself for one Newton iteration.
struct StampContext {
    /// Current Newton iterate.
    let x: [Double]
    let nodeCount: Int
    /// Time of the point being solved (t_{n+1}).
    let time: Double
    /// Step size from the last accepted point.
    let h: Double
    let mode: StampMode

    @inline(__always) func v(_ node: Int) -> Double { node > 0 && node - 1 < x.count ? x[node - 1] : 0 }
    @inline(__always) func aux(_ k: Int) -> Double { nodeCount + k < x.count ? x[nodeCount + k] : 0 }
}
