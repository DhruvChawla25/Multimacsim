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
        case .polynomialBlock:
            return "P(x)"
        case .slewRateBlock:
            return "SR"
        case .hysteresisBlock:
            return "hys"
        case .limiterBlock:
            return "lim"
        case .differentiatorBlock:
            return "d/dt"
        case .integratorBlock:
            return "∫"
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
        case .polynomialBlock:
            // V(out) = a0 + a1·u + a2·u² + ... (Horner, with the derivative alongside)
            let a = coefficients(comp.textValue) ?? [0]
            var y = 0.0, dy = 0.0
            for c in a.reversed() {
                dy = dy * u[0] + y
                y = y * u[0] + c
            }
            return Linearized(value: y, partials: [dy])
        case .slewRateBlock:
            // Output follows the input but moves at most SR·h per step (rising and falling rates separately).
            let yPrev = comp.runtimeState.first ?? u[0]
            guard h > 0 else { return Linearized(value: u[0], partials: [1]) }
            let step = u[0] - yPrev
            let up = comp.value * h, down = comp.param("fallRate") * h
            if step > up { return Linearized(value: yPrev + up, partials: [0]) }
            if step < -down { return Linearized(value: yPrev - down, partials: [0]) }
            return Linearized(value: u[0], partials: [1])
        case .hysteresisBlock:
            // Schmitt trigger: goes high above the upper threshold, low below the lower one, otherwise holds.
            return Linearized(value: hysteresisLevel(comp, input: u[0]).value, partials: [0])
        case .limiterBlock:
            // V(out) = K·u clipped to [lower, upper]
            let (y, inside) = clamp(comp.value * u[0], comp.param("lower"), comp.param("upper"))
            return Linearized(value: y, partials: [inside ? comp.value : 0])
        case .differentiatorBlock:
            // y = K·du/dt, backward difference (y = K·(u − u_n)/h): trapezoidal differentiation would ring.
            guard h > 0, let uPrev = comp.runtimeState.first else { return Linearized(value: 0, partials: [0]) }
            let k = comp.value
            let (y, inside) = clamp(k * (u[0] - uPrev) / h, comp.param("lower"), comp.param("upper"))
            return Linearized(value: y, partials: [inside ? k / h : 0])
        case .integratorBlock:
            // y(t) = K·∫(u + input offset)dt + V0, trapezoidal: y = y_n + K·h/2·(u_n + u), held inside the limits.
            let k = comp.value, off = comp.param("inOffset")
            let yPrev = comp.runtimeState.count >= 2 ? comp.runtimeState[0] : comp.param("initial")
            let uPrev = comp.runtimeState.count >= 2 ? comp.runtimeState[1] : u[0] // input taken as constant over the first step
            guard h > 0 else { return Linearized(value: yPrev, partials: [0]) }
            let raw = yPrev + k * h / 2 * (uPrev + off + u[0] + off)
            let (y, inside) = clamp(raw, comp.param("lower"), comp.param("upper"))
            return Linearized(value: y, partials: [inside ? k * h / 2 : 0])
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
        case .slewRateBlock:
            comp.runtimeState = [y]
        case .hysteresisBlock:
            comp.runtimeState = [hysteresisLevel(comp, input: u[0]).high ? 1 : 0]
        case .differentiatorBlock:
            comp.runtimeState = [u[0]]
        case .integratorBlock:
            comp.runtimeState = [y, u[0]]
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
        case .slewRateBlock:
            guard op != nil else { return nil }
            return [Complex(1)] // a small signal is never slew limited
        case .differentiatorBlock:
            // K·jω
            return [Complex(0, comp.value * omega)]
        case .integratorBlock:
            // K / jω
            return [Complex(comp.value) / Complex(0, max(omega, 1e-30))]
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
        case .polynomialBlock:
            let a = coefficients(comp.textValue) ?? [0]
            let terms = a.enumerated().map { "\($0.element)*pow(\(ins[0]),\($0.offset))" }.joined(separator: "+")
            return "B\(name) \(out) 0 V={\(terms)}"
        case .limiterBlock:
            let lo = min(comp.param("lower"), comp.param("upper")), hi = max(comp.param("lower"), comp.param("upper"))
            return "B\(name) \(out) 0 V={min(max(\(comp.value)*\(ins[0]),\(lo)),\(hi))}"
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
        case .polynomialBlock:
            return coefficients(comp.textValue) == nil ? "Enter one or more numbers, lowest power first (e.g. 0, 1, 0.5)." : nil
        default:
            return nil
        }
    }

    /// Output level of the hysteresis block for input `u`, starting from its last accepted state.
    static func hysteresisLevel(_ comp: CircuitComponent, input u: Double) -> (high: Bool, value: Double) {
        let upper = max(comp.param("upperThreshold"), comp.param("lowerThreshold"))
        let lower = min(comp.param("upperThreshold"), comp.param("lowerThreshold"))
        var high: Bool
        if let s = comp.runtimeState.first { high = s > 0.5 } else { high = u > (upper + lower) / 2 }
        if high && u < lower { high = false }
        if !high && u > upper { high = true }
        return (high, high ? comp.param("outHigh") : comp.param("outLow"))
    }

    /// Polynomial coefficients, lowest power first; nil if the text is not a list of numbers.
    public static func coefficients(_ text: String) -> [Double]? {
        let tokens = text.split(whereSeparator: { " ,;\n\t".contains($0) })
        guard !tokens.isEmpty else { return nil }
        var out: [Double] = []
        for t in tokens {
            guard let v = EngineeringUnitParser.parse(String(t)) else { return nil }
            out.append(v)
        }
        return out
    }

    /// Clamps `v` into [lo, hi] (either order) and reports whether it was inside.
    static func clamp(_ v: Double, _ a: Double, _ b: Double) -> (Double, Bool) {
        let lo = min(a, b), hi = max(a, b)
        if v > hi { return (hi, false) }
        if v < lo { return (lo, false) }
        return (v, true)
    }
}
