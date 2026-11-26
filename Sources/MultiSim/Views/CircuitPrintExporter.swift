import SwiftUI
import AppKit
import MultiSimEngine

/// Renders each lab circuit to a print-ready PNG: white background, no grid, title and values.
@MainActor
enum CircuitPrintExporter {
    /// Pixels per point: 3x gives roughly 300 dpi when printed at the drawn size.
    static let scale: CGFloat = 3
    private static let margin: Double = 70

    /// Returns a process exit code (0 on success).
    static func exportAll(to folder: URL) -> Int32 {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("Cannot create \(folder.path): \(error)\n".utf8))
            return 1
        }
        var failures = 0
        for preset in PresetType.allCases {
            let url = folder.appendingPathComponent(fileName(for: preset))
            if let png = render(preset) {
                do {
                    try png.write(to: url)
                    print("wrote \(url.path)")
                } catch {
                    failures += 1
                    FileHandle.standardError.write(Data("Failed \(url.lastPathComponent): \(error)\n".utf8))
                }
            } else {
                failures += 1
                FileHandle.standardError.write(Data("Could not render \(preset.rawValue)\n".utf8))
            }
        }
        return failures == 0 ? 0 : 1
    }

    static func fileName(for preset: PresetType) -> String {
        let cleaned = preset.rawValue
            .replacingOccurrences(of: "||", with: "parallel")
            .replacingOccurrences(of: ":", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        return cleaned + ".png"
    }

    private static func render(_ preset: PresetType) -> Data? {
        let vm = CircuitEditorViewModel(preset: preset)
        vm.isSimulating = false
        vm.resetSimulation()
        vm.showGrid = false
        vm.isPrintMode = true
        // Meters show their settled AC readings (RMS amps, average watts) instead of 0.
        if case .success(let ac) = ACSteadyStateAnalyzer.analyze(vm.circuit) {
            for comp in vm.circuit.components {
                guard let p = ac.phasor(for: comp.id) else { continue }
                switch comp.kind {
                case .ammeter: comp.runtimeReading = p.rmsCurrent
                case .voltmeter: comp.runtimeReading = p.rmsVoltage
                case .wattmeter: comp.runtimeReading = abs(p.averagePower)
                default: break
                }
            }
        }
        vm.showNodeVoltages = false
        vm.showOscilloscope = false
        vm.lastConnectedWireDescription = nil

        // Frame the drawing around the parts.
        let xs = vm.circuit.components.map(\.position.x)
        let ys = vm.circuit.components.map(\.position.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let width = maxX - minX + 2 * margin
        let height = maxY - minY + 2 * margin
        vm.panOffset = CGPoint(x: margin - minX, y: margin - minY)

        let page = VStack(alignment: .leading, spacing: 10) {
            Text(preset.rawValue.replacingOccurrences(of: "||", with: "∥"))
                .font(.system(size: 20, weight: .bold))
            SchematicCanvasView(viewModel: vm)
                .frame(width: width, height: height)
                .overlay(Rectangle().stroke(Color.black.opacity(0.25), lineWidth: 1))
            Text(partsList(vm.circuit))
                .font(.system(size: 12, design: .monospaced))
        }
        .padding(24)
        .background(Color.white)
        .environment(\.colorScheme, .light)

        var data: Data?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: page)
            renderer.scale = scale
            guard let cg = renderer.cgImage else { return }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale)
            data = rep.representation(using: .png, properties: [:])
        }
        return data
    }

    /// One line per part with its value, so the printout can be read without the app.
    private static func partsList(_ circuit: Circuit) -> String {
        circuit.components.compactMap { c -> String? in
            switch c.kind {
            case .acVoltageSource:
                return String(format: "%@  AC source  %.0f V RMS (%.2f V peak), %.0f Hz",
                              c.designator, c.value / 2.0.squareRoot(), c.value, c.secondaryValue)
            case .resistor: return "\(c.designator)  Resistor  \(EngineeringFormatter.resistance(c.value))"
            case .inductor: return "\(c.designator)  Inductor  \(EngineeringFormatter.inductance(c.value))"
            case .capacitor: return "\(c.designator)  Capacitor  \(EngineeringFormatter.capacitance(c.value))"
            case .switchSPST: return "\(c.designator)  Switch  \(c.stateBool ? "closed" : "open")"
            case .ammeter: return "\(c.designator)  AC ammeter (reading shown is the expected RMS value)"
            case .wattmeter: return "\(c.designator)  Wattmeter, current coil in line, pressure coil across the branches (expected reading shown)"
            default: return nil
            }
        }
        .joined(separator: "\n")
    }
}
