import Foundation

/// Multisim's control function blocks: ideal single-ended inputs (no loading) and an ideal voltage
/// output to ground. Each block reports its output, linearised in its inputs for Newton:
/// V(out) ≈ value + Σ partials[i]·(u_i − u_i0).
public enum ControlBlocks {
    /// Input terminal names, top to bottom. The output terminal comes after them.
    public static func inputNames(_ kind: ComponentKind) -> [String] {
        switch kind {
        // <inputs>
        case .summerBlock:
            return ["A", "B", "C"]
        case .dividerBlock:
            return ["X", "Y"]
        case .multiplierBlock:
            return ["X", "Y"]
        default:
            return ["IN"]
        }
    }

    /// Input pins on the left on a 20 pt pitch, output on the right.
    static func pins(for kind: ComponentKind) -> [Pin] {
        let names = inputNames(kind)
        let top = -Double(names.count - 1) * 10.0
        var pins = names.enumerated().map { i, name in
            Pin(index: i, name: name, relativeX: -30, relativeY: names.count == 2 ? (i == 0 ? -20 : 20) : top + Double(i) * 20)
        }
        pins.append(Pin(index: names.count, name: "OUT", relativeX: 30, relativeY: 0))
        return pins
    }

    /// Short text drawn inside the block's box.
    public static func label(_ kind: ComponentKind) -> String {
        switch kind {
        // <labels>
        case .summerBlock:
            return "Σ"
        case .dividerBlock:
            return "÷"
        case .multiplierBlock:
            return "×"
        case .gainBlock:
            return "K"
        default:
            return "f"
        }
    }

    public struct Linearized: Equatable {
        public var value: Double
        public var partials: [Double]
    }

    /// Output at the point being solved, given the inputs of the present Newton iterate.
    /// `h` is the step from the last accepted point (0 for a DC operating point).
    static func evaluate(_ comp: CircuitComponent, inputs u: [Double], h: Double) -> Linearized {
        let zero = [Double](repeating: 0, count: u.count)
        switch comp.kind {
        // <eval>
        case .summerBlock:
            // V(out) = K·(ka·A + kb·B + kc·C) + output offset
            let k = comp.value
            let g = [comp.param("aGain"), comp.param("bGain"), comp.param("cGain")]
            let sum = zip(g, u).reduce(0) { $0 + $1.0 * $1.1 }
            return Linearized(value: k * sum + comp.param("outOffset"), partials: g.prefix(u.count).map { k * $0 })
        case .dividerBlock:
            // V(out) = K·[xg·(X + xo)] / [yg·(Y + yo)] + output offset, |denominator| held at or above the lower limit.
            let k = comp.value, xg = comp.param("xGain"), yg = comp.param("yGain")
            let x = xg * (u[0] + comp.param("xOffset"))
            let rawY = yg * (u[1] + comp.param("yOffset"))
            let floor = max(comp.param("yMin"), 1e-15)
            let limited = abs(rawY) < floor
            let y = limited ? (rawY < 0 ? -floor : floor) : rawY
            return Linearized(value: k * x / y + comp.param("outOffset"),
                              partials: [k * xg / y, limited ? 0 : -k * x * yg / (y * y)])
        case .multiplierBlock:
            // V(out) = K·[xg·(X + xo)]·[yg·(Y + yo)] + output offset
            let k = comp.value, xg = comp.param("xGain"), yg = comp.param("yGain")
            let x = xg * (u[0] + comp.param("xOffset")), y = yg * (u[1] + comp.param("yOffset"))
            return Linearized(value: k * x * y + comp.param("outOffset"), partials: [k * xg * y, k * x * yg])
        case .gainBlock:
            // V(out) = K·(u + input offset) + output offset
            let k = comp.value
            return Linearized(value: k * (u[0] + comp.param("inOffset")) + comp.param("outOffset"), partials: [k])
        default:
            return Linearized(value: 0, partials: zero)
        }
    }

    /// Commits a step: stateful blocks remember what they need for the next one.
    static func accept(_ comp: CircuitComponent, inputs u: [Double], output y: Double, h: Double) {
        switch comp.kind {
        // <accept>
        default:
            break
        }
    }

    /// Complex gain from each input to the output at angular frequency ω, or nil when the block has no
    /// linear frequency response. With an operating point (`op`, the DC inputs) non-linear blocks are
    /// linearised there, as in a SPICE small-signal analysis.
    static func acGains(_ comp: CircuitComponent, omega: Double, op: [Double]?) -> [Complex]? {
        switch comp.kind {
        // <ac>
        case .summerBlock:
            let k = comp.value
            return [comp.param("aGain"), comp.param("bGain"), comp.param("cGain")].map { Complex(k * $0) }
        case .gainBlock:
            return [Complex(comp.value)]
        default:
            guard let op else { return nil }
            return evaluate(comp, inputs: op, h: 0).partials.map { Complex($0) }
        }
    }

    /// One-line SPICE equivalent (behavioural B source) for the memoryless blocks, nil otherwise.
    static func spice(_ comp: CircuitComponent, name: String, nodes: [String]) -> String? {
        let ins = nodes.dropLast().map { "V(\($0))" }
        let out = nodes.last ?? "0"
        switch comp.kind {
        // <spice>
        case .summerBlock:
            return "B\(name) \(out) 0 V={\(comp.value)*(\(comp.param("aGain"))*\(ins[0])+\(comp.param("bGain"))*\(ins[1])+\(comp.param("cGain"))*\(ins[2]))+\(comp.param("outOffset"))}"
        case .dividerBlock:
            return "B\(name) \(out) 0 V={\(comp.value)*(\(comp.param("xGain"))*(\(ins[0])+\(comp.param("xOffset"))))/(\(comp.param("yGain"))*(\(ins[1])+\(comp.param("yOffset"))))+\(comp.param("outOffset"))}"
        case .multiplierBlock:
            return "B\(name) \(out) 0 V={\(comp.value)*(\(comp.param("xGain"))*(\(ins[0])+\(comp.param("xOffset"))))*(\(comp.param("yGain"))*(\(ins[1])+\(comp.param("yOffset"))))+\(comp.param("outOffset"))}"
        case .gainBlock:
            return "B\(name) \(out) 0 V={\(comp.value)*(\(ins[0])+\(comp.param("inOffset")))+\(comp.param("outOffset"))}"
        default:
            _ = ins
            _ = out
            return nil
        }
    }

    /// Problem with the block's text setting, if it has one.
    static func textError(_ comp: CircuitComponent) -> String? {
        switch comp.kind {
        // <text>
        default:
            return nil
        }
    }

    /// Clamps `v` into [lo, hi] (either order) and reports whether it was inside.
    static func clamp(_ v: Double, _ a: Double, _ b: Double) -> (Double, Bool) {
        let lo = min(a, b), hi = max(a, b)
        if v > hi { return (hi, false) }
        if v < lo { return (lo, false) }
        return (v, true)
    }
}
