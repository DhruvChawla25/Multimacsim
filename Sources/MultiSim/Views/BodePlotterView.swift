import SwiftUI
import MultiSimEngine

/// Bode plotter: magnitude (dB) and phase (degrees) of V(out)/V(in) against log frequency, from the AC sweep.
public struct BodePlotterView: View {
    @ObservedObject var viewModel: CircuitEditorViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var startText = "10"
    @State private var stopText = "100k"
    @State private var pointsPerDecade = 40
    @State private var inputKey = ""
    @State private var outputKey = ""
    @State private var hoverFraction: Double?

    /// Every voltage the plotter can measure, keyed for the pickers.
    private var probes: [(key: String, probe: ACSweepProbe)] {
        let c = viewModel.circuit
        var list: [(String, ACSweepProbe)] = []
        for comp in c.components where comp.kind == .bodePlotter {
            if let pair = ACSweepProbe.bodePairs(comp, in: c) {
                list.append(("\(comp.id)-in", pair.input))
                list.append(("\(comp.id)-out", pair.output))
            }
        }
        for comp in c.components where comp.pins.count >= 2 && !comp.kind.isInstrument && comp.kind != .ground {
            list.append(("\(comp.id)", ACSweepProbe.across(comp, in: c)))
        }
        let nodes = c.resolveNodes().totalNodes
        if nodes > 0 {
            for n in 1...nodes { list.append(("node-\(n)", ACSweepProbe(plus: n, label: "Node \(n)"))) }
        }
        return list
    }

    private func probe(_ key: String) -> ACSweepProbe? { probes.first { $0.key == key }?.probe }

    /// Sensible starting choice: a Bode plotter's own pairs, else the AC source in and the last R / C out.
    private func defaultKeys() -> (String, String) {
        let c = viewModel.circuit
        if let bp = c.components.first(where: { $0.kind == .bodePlotter }) { return ("\(bp.id)-in", "\(bp.id)-out") }
        let src = c.components.first { ACSteadyStateAnalyzer.acDriveFrequency($0) != nil && $0.pins.count == 2 }
        let out = c.components.last { [.capacitor, .resistor, .inductor].contains($0.kind) }
        return (src.map { "\($0.id)" } ?? probes.first?.key ?? "", out.map { "\($0.id)" } ?? probes.last?.key ?? "")
    }

    private var start: Double { EngineeringUnitParser.parse(startText, unit: "Hz") ?? 10 }
    private var stop: Double { EngineeringUnitParser.parse(stopText, unit: "Hz") ?? 1e5 }

    private var result: Result<ACSweepResult, ACAnalysisError>? {
        guard let i = probe(inputKey), let o = probe(outputKey), start > 0, stop > start else { return nil }
        return ACSweepAnalyzer.sweep(viewModel.circuit, input: i, output: o, start: start, stop: stop, pointsPerDecade: pointsPerDecade)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Bode Plotter - AC Sweep", systemImage: "chart.xyaxis.line")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            controls
            switch result {
            case .none:
                Spacer()
                Text("Pick an input and an output, and a start frequency below the stop frequency.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            case .failure(let e):
                Spacer()
                Label(e.description, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            case .success(let sweep):
                plots(sweep)
            }
        }
        .padding(18)
        .frame(width: 780, height: 640)
        .onAppear {
            let (i, o) = defaultKeys()
            inputKey = i
            outputKey = o
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("In", selection: $inputKey) {
                ForEach(probes, id: \.key) { Text($0.probe.label).tag($0.key) }
            }
            .frame(width: 190)
            Picker("Out", selection: $outputKey) {
                ForEach(probes, id: \.key) { Text($0.probe.label).tag($0.key) }
            }
            .frame(width: 190)
            HStack(spacing: 4) {
                Text("From").font(.caption)
                TextField("10", text: $startText).frame(width: 58)
                Text("to").font(.caption)
                TextField("100k", text: $stopText).frame(width: 58)
                Text("Hz").font(.caption)
            }
            .textFieldStyle(.roundedBorder)
            Picker("Pts/dec", selection: $pointsPerDecade) {
                ForEach([10, 20, 40, 100], id: \.self) { Text("\($0)").tag($0) }
            }
            .frame(width: 110)
        }
        .controlSize(.small)
    }

    // MARK: - Plots

    private func plots(_ sweep: ACSweepResult) -> some View {
        let mags = sweep.points.map(\.magnitudeDB)
        let phases = sweep.points.map(\.phaseDegrees)
        let magRange = Self.niceRange(mags, step: 10)
        let phaseRange = Self.niceRange(phases, step: 45)
        let cursor = hoverFraction.flatMap { f -> ACSweepPoint? in
            let freq = pow(10, log10(start) + f * (log10(stop) - log10(start)))
            return sweep.nearest(freq)
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                if let p = cursor {
                    Text(String(format: "f = %@   |H| = %.2f dB (%.4g)   ∠H = %.1f°",
                                EngineeringFormatter.units(p.frequency, "Hz"), p.magnitudeDB, p.response.magnitude, p.phaseDegrees))
                } else {
                    Text("Hover over a plot to read the cursor.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let fc = sweep.lowPassCutoff {
                    Text("-3 dB at \(EngineeringFormatter.units(fc, "Hz"))")
                        .foregroundStyle(.orange)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            chart(values: mags, range: magRange, step: 10, unit: "dB", color: .green, cursor: hoverFraction)
            chart(values: phases, range: phaseRange, step: 45, unit: "°", color: .cyan, cursor: hoverFraction)
        }
    }

    private func chart(values: [Double], range: ClosedRange<Double>, step: Double, unit: String, color: Color, cursor: Double?) -> some View {
        let lo = log10(start), hi = log10(stop)
        return Canvas { ctx, size in
            let left: CGFloat = 46, bottom: CGFloat = 18
            let w = size.width - left - 8, h = size.height - bottom - 6
            func x(_ frac: Double) -> CGFloat { left + CGFloat(frac) * w }
            func y(_ v: Double) -> CGFloat { 6 + CGFloat((range.upperBound - v) / (range.upperBound - range.lowerBound)) * h }
            ctx.fill(Path(CGRect(x: left, y: 6, width: w, height: h)), with: .color(.black.opacity(0.85)))
            // Decade grid and labels
            var decade = floor(lo)
            while decade <= hi {
                for m in 1...9 {
                    let f = log10(Double(m)) + decade
                    guard f >= lo, f <= hi else { continue }
                    let gx = x((f - lo) / (hi - lo))
                    var p = Path(); p.move(to: CGPoint(x: gx, y: 6)); p.addLine(to: CGPoint(x: gx, y: 6 + h))
                    ctx.stroke(p, with: .color(.white.opacity(m == 1 ? 0.28 : 0.08)), lineWidth: 1)
                    if m == 1 {
                        ctx.draw(Text(EngineeringFormatter.units(pow(10, decade), "Hz")).font(.system(size: 9)).foregroundColor(.secondary),
                                 at: CGPoint(x: gx, y: size.height - 8))
                    }
                }
                decade += 1
            }
            var v = range.lowerBound
            while v <= range.upperBound + 1e-9 {
                var p = Path(); p.move(to: CGPoint(x: left, y: y(v))); p.addLine(to: CGPoint(x: left + w, y: y(v)))
                ctx.stroke(p, with: .color(.white.opacity(0.12)), lineWidth: 1)
                ctx.draw(Text(String(format: "%.0f%@", v, unit)).font(.system(size: 9)).foregroundColor(.secondary),
                         at: CGPoint(x: left - 22, y: y(v)))
                v += step
            }
            // Trace
            var trace = Path()
            for (i, value) in values.enumerated() {
                let pt = CGPoint(x: x(Double(i) / Double(max(values.count - 1, 1))), y: y(min(max(value, range.lowerBound), range.upperBound)))
                if i == 0 { trace.move(to: pt) } else { trace.addLine(to: pt) }
            }
            ctx.stroke(trace, with: .color(color), lineWidth: 1.8)
            if let c = cursor {
                var p = Path(); p.move(to: CGPoint(x: x(c), y: 6)); p.addLine(to: CGPoint(x: x(c), y: 6 + h))
                ctx.stroke(p, with: .color(.red), lineWidth: 1)
            }
        }
        .frame(height: 230)
        .onContinuousHover { phase in
            switch phase {
            case .active(let loc):
                hoverFraction = min(max(Double((loc.x - 46) / max(1, 780 - 36 - 46 - 8)), 0), 1)
            case .ended:
                hoverFraction = nil
            }
        }
    }

    /// Range covering every value, snapped out to multiples of `step` (at least one step tall).
    static func niceRange(_ values: [Double], step: Double) -> ClosedRange<Double> {
        let finite = values.filter(\.isFinite)
        guard let lo = finite.min(), let hi = finite.max() else { return -step...step }
        var a = floor(lo / step) * step, b = ceil(hi / step) * step
        if b - a < step { a -= step; b += step }
        // Do not let one deep notch squash everything: show at most 12 steps.
        if (b - a) / step > 12 { a = b - 12 * step }
        return a...b
    }
}
