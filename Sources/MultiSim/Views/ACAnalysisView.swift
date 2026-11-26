import SwiftUI
import MultiSimEngine

/// AC steady-state report: reactance table, peak / RMS / phase summary and the ideal waveforms.
/// Numbers come from an exact phasor solve, so they match a hand calculation of the lab sheet.
public struct ACAnalysisView: View {
    @ObservedObject var viewModel: CircuitEditorViewModel
    @Environment(\.dismiss) private var dismiss
    /// Traces the user flipped away from their default (part voltages start hidden).
    @State private var toggledTraces: Set<String> = []

    private var result: Result<ACSteadyStateResult, ACAnalysisError> {
        ACSteadyStateAnalyzer.analyze(viewModel.circuit)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AC Steady-State Analysis", systemImage: "function")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            switch result {
            case .failure(let error):
                Spacer()
                Label(error.description, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            case .success(let ac):
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        waveformSection(ac)
                        reactanceSection(ac)
                        summarySection(ac)
                        meterSection(ac)
                        powerSection(ac)
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(18)
        .frame(width: 760, height: 720)
    }

    // MARK: - Waveforms

    private struct Trace: Identifiable {
        let id: String
        let label: String
        let phasor: Complex
        let isCurrent: Bool
        let color: Color
        var startsVisible: Bool { !id.hasPrefix("v-") }
    }

    private static let palette: [Color] = [.green, .orange, .pink, .purple, .mint, .yellow, .teal]

    private func traces(_ ac: ACSteadyStateResult) -> [Trace] {
        var list = [
            Trace(id: "vs", label: "v\u{209B} (\(ac.referenceSource.designator))", phasor: ac.referenceSource.voltage, isCurrent: false, color: .blue),
            Trace(id: "is", label: "i (source)", phasor: ac.sourceCurrent, isCurrent: true, color: .red),
        ]
        // One current trace per resistor: in a lab sheet the resistors identify the branches.
        let resistors = ac.parts.filter { $0.kind == .resistor }
        if resistors.count > 1 {
            for (k, part) in resistors.enumerated() {
                list.append(Trace(id: "i-\(part.id)", label: "i through \(part.designator)", phasor: part.current,
                                  isCurrent: true, color: Self.palette[k % Self.palette.count]))
            }
        }
        for (k, part) in Self.elements(ac).enumerated() {
            list.append(Trace(id: "v-\(part.id)", label: "v across \(part.designator)", phasor: part.voltage,
                              isCurrent: false, color: Self.palette[(k + 3) % Self.palette.count]))
        }
        return list
    }

    private func waveformSection(_ ac: ACSteadyStateResult) -> some View {
        let all = traces(ac)
        let visible = all.filter { $0.startsVisible != toggledTraces.contains($0.id) }
        let vMax = max(visible.filter { !$0.isCurrent }.map(\.phasor.magnitude).max() ?? 1, 1e-12)
        let iMax = max(visible.filter(\.isCurrent).map(\.phasor.magnitude).max() ?? 1, 1e-12)

        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Waveforms (steady state, two cycles)")
            Canvas { context, size in
                let mid = size.height / 2
                let amp = size.height / 2 * 0.88
                var axis = Path()
                axis.move(to: CGPoint(x: 0, y: mid))
                axis.addLine(to: CGPoint(x: size.width, y: mid))
                for k in 0...4 {
                    let x = size.width * CGFloat(k) / 4
                    axis.move(to: CGPoint(x: x, y: 0))
                    axis.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(axis, with: .color(.secondary.opacity(0.25)), lineWidth: 0.8)

                for trace in visible {
                    let scale = trace.isCurrent ? iMax : vMax
                    let peak = trace.phasor.magnitude / scale
                    let phase = trace.phasor.angleDegrees * .pi / 180
                    var path = Path()
                    let steps = 400
                    for s in 0...steps {
                        let theta = 4 * Double.pi * Double(s) / Double(steps)
                        let y = mid - CGFloat(peak * sin(theta + phase)) * amp
                        let pt = CGPoint(x: size.width * CGFloat(s) / CGFloat(steps), y: y)
                        if s == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    context.stroke(path, with: .color(trace.color), lineWidth: 1.8)
                }

                context.draw(Text(String(format: "±%.4g V", vMax)).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary),
                             at: CGPoint(x: 4, y: 8), anchor: .leading)
                context.draw(Text(String(format: "±%.4g A", iMax)).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary),
                             at: CGPoint(x: size.width - 4, y: 8), anchor: .trailing)
            }
            .frame(height: 190)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            FlowChips(traces: all.map { ($0.id, $0.label, $0.color) }, visible: Set(visible.map(\.id)), toggled: $toggledTraces)
            Text("Voltages share the left scale and currents the right one, so each kind uses the full height.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Tables

    private func reactanceSection(_ ac: ACSteadyStateResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(String(format: "Component Parameters & Reactances (f = %.4g Hz, ω = %.2f rad/s)", ac.frequency, ac.omega))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    header("Part"); header("Value"); header("Formula"); header("Impedance")
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(ac.reactances) { entry in
                    GridRow {
                        mono(entry.designator)
                        mono(valueText(entry))
                        mono(formula(entry))
                        mono(impedanceText(entry.impedance))
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    mono("Z (seen by \(ac.referenceSource.designator))")
                    mono("")
                    mono("Z = V\u{209B} / I")
                    mono(String(format: "%@  |Z| = %.2f Ω  θ = %+.2f°",
                                complexText(ac.totalImpedance, unit: "Ω"),
                                ac.totalImpedance.magnitude, ac.totalImpedance.angleDegrees))
                }
            }
        }
    }

    private func summarySection(_ ac: ACSteadyStateResult) -> some View {
        let ref = ac.referenceSource.voltage.angleDegrees
        func phase(_ c: Complex) -> String {
            var d = c.angleDegrees - ref
            while d > 180 { d -= 360 }
            while d <= -180 { d += 360 }
            if c.magnitude < 1e-12 { return "-" }
            let nature = abs(d) < 0.05 ? "in phase" : (d < 0 ? "lagging" : "leading")
            return String(format: "%+.2f° (%@)", d, nature)
        }

        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Electrical Summary Table (phase relative to V\u{209B})")
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    header("Quantity"); header("Peak"); header("RMS"); header("Phase")
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    mono("Source voltage (\(ac.referenceSource.designator))")
                    mono(EngineeringFormatter.voltage(ac.referenceSource.peakVoltage))
                    mono(EngineeringFormatter.voltage(ac.referenceSource.rmsVoltage))
                    mono(phase(ac.referenceSource.voltage))
                }
                GridRow {
                    mono("Source current (I)")
                    mono(EngineeringFormatter.current(ac.sourceCurrent.magnitude))
                    mono(EngineeringFormatter.current(ac.sourceCurrent.magnitude / 2.0.squareRoot()))
                    mono(phase(ac.sourceCurrent))
                }
                ForEach(Self.elements(ac)) { part in
                    GridRow {
                        mono("Current through \(part.designator)")
                        mono(EngineeringFormatter.current(part.peakCurrent))
                        mono(EngineeringFormatter.current(part.rmsCurrent))
                        mono(phase(part.current))
                    }
                    GridRow {
                        mono("Voltage across \(part.designator)")
                        mono(EngineeringFormatter.voltage(part.peakVoltage))
                        mono(EngineeringFormatter.voltage(part.rmsVoltage))
                        mono(phase(part.voltage))
                    }
                }
            }
        }
    }

    private func powerSection(_ ac: ACSteadyStateResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Power")
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow { header("Quantity"); header("Value") }
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow { mono("Active power P"); mono(String(format: "%.3f W", ac.activePower)) }
                GridRow { mono("Reactive power Q"); mono(String(format: "%+.3f VAR", ac.reactivePower)) }
                GridRow { mono("Apparent power S"); mono(String(format: "%.3f VA", ac.apparentPower)) }
                GridRow {
                    mono("Power factor cos θ")
                    mono(String(format: "%.4f %@", ac.powerFactor,
                                abs(ac.totalImpedance.angleDegrees) < 0.05 ? "(unity)"
                                    : (ac.totalImpedance.angleDegrees > 0 ? "(lagging, inductive)" : "(leading, capacitive)")))
                }
                ForEach(ac.parts.filter { $0.kind == .resistor }) { part in
                    GridRow { mono("Power in \(part.designator)"); mono(String(format: "%.3f W", part.averagePower)) }
                }
            }
        }
    }

    /// The R, L and C parts - what the lab tables report on.
    private static func elements(_ ac: ACSteadyStateResult) -> [ComponentPhasor] {
        ac.parts.filter { [.resistor, .inductor, .capacitor, .electrolyticCapacitor, .trimmerCapacitor].contains($0.kind) }
    }

    @ViewBuilder
    private func meterSection(_ ac: ACSteadyStateResult) -> some View {
        let meters = ac.parts.filter { [.ammeter, .voltmeter, .wattmeter].contains($0.kind) }
        if !meters.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Meter Readings (what the AC meters show once settled)")
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow { header("Meter"); header("Reads") }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(meters) { m in
                        GridRow {
                            mono("\(m.designator) (\(m.kind.rawValue))")
                            switch m.kind {
                            case .ammeter: mono(EngineeringFormatter.current(m.rmsCurrent) + " RMS")
                            case .voltmeter: mono(EngineeringFormatter.voltage(m.rmsVoltage) + " RMS")
                            default: mono(String(format: "%.3f W", m.averagePower))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Formatting helpers

    private func valueText(_ e: ReactanceEntry) -> String {
        switch e.kind {
        case .resistor: return EngineeringFormatter.resistance(e.value)
        case .inductor: return EngineeringFormatter.inductance(e.value)
        default: return EngineeringFormatter.capacitance(e.value)
        }
    }

    private func formula(_ e: ReactanceEntry) -> String {
        switch e.kind {
        case .resistor: return "Z = R"
        case .inductor: return "X\u{2097} = ωL"
        default: return "X\u{1D04} = 1/(ωC)"
        }
    }

    private func impedanceText(_ z: Complex) -> String {
        if abs(z.im) < 1e-12 { return String(format: "%.2f Ω", z.re) }
        return String(format: "%@j%.2f Ω", z.im < 0 ? "−" : "+", abs(z.im))
    }

    private func complexText(_ z: Complex, unit: String) -> String {
        String(format: "%.2f %@ j%.2f %@", z.re, z.im < 0 ? "−" : "+", abs(z.im), unit)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.subheadline.bold())
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.caption.bold()).foregroundStyle(.secondary)
    }

    private func mono(_ text: String) -> some View {
        Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
    }
}

/// Toggle chips for the waveform legend.
private struct FlowChips: View {
    let traces: [(id: String, label: String, color: Color)]
    let visible: Set<String>
    @Binding var toggled: Set<String>

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(traces, id: \.id) { trace in
                let isHidden = !visible.contains(trace.id)
                Button {
                    if toggled.contains(trace.id) { toggled.remove(trace.id) } else { toggled.insert(trace.id) }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(trace.color.opacity(isHidden ? 0.25 : 1)).frame(width: 8, height: 8)
                        Text(trace.label)
                            .font(.caption)
                            .foregroundStyle(isHidden ? .tertiary : .primary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help(isHidden ? "Show this trace" : "Hide this trace")
            }
        }
    }
}
