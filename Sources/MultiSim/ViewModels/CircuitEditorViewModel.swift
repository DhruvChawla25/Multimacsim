import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers
import MultiSimEngine

/// The central state manager for schematic editing, simulation ticking, and virtual instruments.
@MainActor
public final class CircuitEditorViewModel: ObservableObject {
    // MARK: - Document State
    @Published public var circuit: Circuit
    @Published public var selectedComponentId: UUID? = nil
    @Published public var selectedWireId: UUID? = nil
    @Published public var currentFileURL: URL? = nil
    private var moveOrigins: [UUID: Point2D] = [:]

    // MARK: - Canvas State
    @Published public var zoomScale: CGFloat = 1.0
    @Published public var panOffset: CGPoint = .zero
    @Published public var gridSize: CGFloat = 20.0
    @Published public var wireDraftStartPin: (componentId: UUID, pin: Pin)? = nil
    @Published public var wireDraftCurrentPoint: CGPoint? = nil
    @Published public var isWireMode: Bool = false
    @Published public var showNodeVoltages: Bool = true
    /// Off when rendering a clean printout.
    @Published public var showGrid: Bool = true
    /// Printout rendering: white paper, no terminal dots.
    @Published public var isPrintMode: Bool = false
    @Published public var showDiagnosticsSheet: Bool = false
    @Published public var lastConnectedWireDescription: String? = nil
    @Published public var latestNodeVoltages: [Int: Double] = [:]
    /// The terminal the current wire draft will land on if you let go now.
    @Published public var wireDraftTargetPinId: UUID? = nil

    // MARK: - Simulation State
    @Published public var isSimulating: Bool = true
    @Published public var simulationSpeed: Double = 1.0 // 1x real time
    @Published public var currentSimulationTime: Double = 0.0
    @Published public var animationPhase: Double = 0.0 // Phase for moving current dots

    // MARK: - Virtual Instruments
    @Published public var showOscilloscope: Bool = false
    @Published public var oscilloscopeChannelACompId: UUID? = nil
    @Published public var oscilloscopeChannelBCompId: UUID? = nil
    @Published public var oscilloscopeTimeScale: Double = 0.005 // 5ms per div
    @Published public var oscilloscopeVoltsPerDivA: Double = 2.0
    @Published public var oscilloscopeVoltsPerDivB: Double = 2.0
    /// When on, the channel plots the part's current (A/div) instead of its voltage (V/div).
    @Published public var oscilloscopeChannelAShowsCurrent: Bool = false
    @Published public var oscilloscopeChannelBShowsCurrent: Bool = false

    // Waveform history buffers for oscilloscope (ring buffers)
    public var traceA: [(time: Double, voltage: Double)] = []
    public var traceB: [(time: Double, voltage: Double)] = []
    private let maxTraceSamples = 800

    /// Capacitor / inductor integration rule, kept across file loads so the two can be compared.
    @Published public var integrationMethod: IntegrationMethod = .trapezoidal {
        didSet { solver.integrationMethod = integrationMethod }
    }

    /// LTE-controlled sub-stepping inside every frame step (more accurate, more CPU on fast circuits).
    @Published public var adaptiveTimestep: Bool = false {
        didSet { solver.adaptiveTimestep = adaptiveTimestep }
    }

    // Solver instance
    public private(set) var solver: MNASolver
    private var simulationTimer: AnyCancellable?

    public init(circuit: Circuit? = nil) {
        let initialCircuit = circuit ?? Circuit()
        self.circuit = initialCircuit
        self.solver = MNASolver(circuit: initialCircuit, timeStep: 1e-4)

        // Default probe channel A to first passive/diode component
        if let firstComp = initialCircuit.components.first(where: { $0.kind.isCapacitive || $0.kind.isJunctionDiode || $0.kind == .resistor }) {
            self.oscilloscopeChannelACompId = firstComp.id
        }

        startSimulationTimer()
    }

    /// Opens with a pre-wired example so the canvas is never an empty mystery.
    public convenience init(preset: PresetType) {
        self.init(circuit: Circuit())
        loadPreset(type: preset)
    }

    private func makeSolver(for circuit: Circuit) -> MNASolver {
        let s = MNASolver(circuit: circuit, timeStep: 1e-4)
        s.integrationMethod = integrationMethod
        s.adaptiveTimestep = adaptiveTimestep
        return s
    }

    // MARK: - Simulation Control

    public func toggleSimulation() {
        isSimulating.toggle()
    }

    public func resetSimulation() {
        solver.reset()
        solver.resetFuses()
        currentSimulationTime = 0.0
        traceA.removeAll(keepingCapacity: true)
        traceB.removeAll(keepingCapacity: true)
        animationPhase = 0.0
    }

    public func stepSimulationSingle() {
        advanceSimulation(dt: solver.timeStep)
    }

    private func startSimulationTimer() {
        // Run timer at ~60 FPS (approx every 16.6 ms)
        simulationTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, self.isSimulating else { return }
                // In 16.6ms at 1x speed, do 16 steps of 100 microseconds (1.6ms simulated time) or scaled
                let stepsPerFrame = max(1, Int(16 * self.simulationSpeed))
                let dt = self.solver.timeStep
                for _ in 0..<stepsPerFrame {
                    self.advanceSimulation(dt: dt)
                }
                // Animate electron dots
                self.animationPhase += 1.5 * self.simulationSpeed
                if self.animationPhase > 1000.0 {
                    self.animationPhase = 0.0
                }
            }
    }

    private func advanceSimulation(dt: Double) {
        let res = solver.step(dt: dt)
        currentSimulationTime = res.time
        latestNodeVoltages = res.nodeVoltages

        // Record oscilloscope samples
        if let compAId = oscilloscopeChannelACompId,
           let compA = circuit.components.first(where: { $0.id == compAId }) {
            traceA.append((time: currentSimulationTime, voltage: oscilloscopeChannelAShowsCurrent ? compA.runtimeCurrent : compA.runtimeVoltageDrop))
            if traceA.count > maxTraceSamples { traceA.removeFirst() }
        }

        if let compBId = oscilloscopeChannelBCompId,
           let compB = circuit.components.first(where: { $0.id == compBId }) {
            traceB.append((time: currentSimulationTime, voltage: oscilloscopeChannelBShowsCurrent ? compB.runtimeCurrent : compB.runtimeVoltageDrop))
            if traceB.count > maxTraceSamples { traceB.removeFirst() }
        }
    }

    // MARK: - Circuit Modification

    public func addComponent(kind: ComponentKind, at position: Point2D) {
        let count = circuit.components.filter { $0.kind == kind }.count + 1
        let defaults = kind.partDefaults

        let snappedX = WireRouter.snap(position.x, to: gridSize)
        let snappedY = WireRouter.snap(position.y, to: gridSize)

        let comp = CircuitComponent(
            kind: kind,
            designator: "\(kind.designatorPrefix)\(count)",
            position: Point2D(x: snappedX, y: snappedY),
            value: defaults.value,
            secondaryValue: defaults.secondaryValue,
            stateBool: defaults.isClosed,
            modeIndex: defaults.modeIndex
        )

        circuit.components.append(comp)
        selectedComponentId = comp.id

        // Drop it straight onto a terminal or alongside a facing terminal and it wires itself.
        let wired = connectComponent(comp)
        solver.rebuildNetlist()
        if wired > 0 {
            lastConnectedWireDescription = "🔗 \(comp.designator) auto-connected (\(wired))"
        }
    }

    /// First empty spot in the visible area, so parts added from the palette never pile up.
    public func nextFreePosition() -> Point2D {
        let baseX = 200.0 - Double(panOffset.x)
        let baseY = 160.0 - Double(panOffset.y)
        for row in 0..<6 {
            for col in 0..<6 {
                let cx = baseX + Double(col) * 120.0
                let cy = baseY + Double(row) * 100.0
                let taken = circuit.components.contains { c in
                    abs(c.position.x - cx) < 80.0 && abs(c.position.y - cy) < 70.0
                }
                if !taken {
                    return Point2D(x: cx, y: cy)
                }
            }
        }
        return Point2D(x: baseX, y: baseY)
    }

    // MARK: - Moving parts

    public func beginMoving(id: UUID) {
        if let comp = circuit.components.first(where: { $0.id == id }) {
            moveOrigins[id] = comp.position
        }
    }

    public func dragOrigin(for id: UUID) -> Point2D? {
        moveOrigins[id]
    }

    /// Dragging is magnetic: the part is nudged so a terminal grabs the nearest terminal or wire.
    public func updateComponentPosition(id: UUID, newPosition: Point2D) {
        guard let comp = circuit.components.first(where: { $0.id == id }) else { return }
        let grid = Point2D(
            x: WireRouter.snap(newPosition.x, to: gridSize),
            y: WireRouter.snap(newPosition.y, to: gridSize)
        )
        comp.position = AutoConnect.snappedPosition(moving: comp, proposed: grid, in: circuit, grid: Double(gridSize)) ?? grid
        objectWillChange.send()
    }

    public func finishMovingComponent(id: UUID) {
        moveOrigins[id] = nil
        if let comp = circuit.components.first(where: { $0.id == id }) {
            let wired = connectComponent(comp)
            if wired > 0 {
                lastConnectedWireDescription = "✅ \(comp.designator) connected (\(wired) wire\(wired == 1 ? "" : "s"))"
            }
        }
        solver.rebuildNetlist()
        objectWillChange.send()
    }

    private func hasWire(between a: UUID, and b: UUID) -> Bool {
        circuit.wires.contains { w in
            (w.startPinId == a && w.endPinId == b) || (w.startPinId == b && w.endPinId == a)
        }
    }

    /// Wires every terminal of a component that is now touching another terminal, or touching a wire.
    @discardableResult
    private func connectComponent(_ comp: CircuitComponent) -> Int {
        var added = 0

        // Terminal sitting on terminal.
        for pair in AutoConnect.coincidentPairs(in: circuit) {
            guard pair.a == comp.id || pair.b == comp.id || belongsTo(comp, pair.a) || belongsTo(comp, pair.b) else { continue }
            if !hasWire(between: pair.a, and: pair.b) {
                circuit.wires.append(Wire(startPinId: pair.a, endPinId: pair.b))
                added += 1
            }
        }

        // Terminal dropped onto an existing wire becomes a T-junction on that net.
        for pin in comp.pins {
            let p = comp.absolutePinPosition(pinIndex: pin.index)
            guard let tap = AutoConnect.nearestTapPoint(from: p, in: circuit, grid: Double(gridSize), tolerance: 1.5) else { continue }
            let tapEnd = tapEndPin(for: tap.wire, near: p)
            if !hasWire(between: pin.id, and: tapEnd) {
                circuit.wires.append(Wire(startPinId: pin.id, endPinId: tapEnd, waypoints: [tap.point]))
                added += 1
            }
        }

        return added
    }

    private func belongsTo(_ comp: CircuitComponent, _ pinId: UUID) -> Bool {
        comp.pins.contains { $0.id == pinId }
    }

    /// The endpoint of a wire nearest to a tapped point - joining it puts the pin on that net.
    private func tapEndPin(for wire: Wire, near point: Point2D) -> UUID {
        guard let a = circuit.pinPosition(wire.startPinId), let b = circuit.pinPosition(wire.endPinId) else {
            return wire.startPinId
        }
        return point.distance(to: a) <= point.distance(to: b) ? wire.startPinId : wire.endPinId
    }

    // MARK: - Wiring actions

    /// Connects terminals that already face each other down the same row or column.
    @discardableResult
    public func autoConnectFacingPins() -> Int {
        let pairs = AutoConnect.facingPairs(in: circuit, maxGap: 60 * 2, grid: Double(gridSize))
        var added = 0
        for pair in pairs {
            if !hasWire(between: pair.from.id, and: pair.to.id) {
                circuit.wires.append(Wire(startPinId: pair.from.id, endPinId: pair.to.id))
                added += 1
            }
        }
        solver.rebuildNetlist()
        lastConnectedWireDescription = added == 0
            ? "ℹ️ No facing terminals found within reach - nudge the parts closer or drag from dot to dot"
            : "🔗 Auto-connect added \(added) wire\(added == 1 ? "" : "s")"
        objectWillChange.send()
        return added
    }

    /// Rounds every part back onto the grid, then re-checks for touch connections.
    public func snapAllToGrid() {
        for comp in circuit.components {
            comp.position = Point2D(
                x: WireRouter.snap(comp.position.x, to: gridSize),
                y: WireRouter.snap(comp.position.y, to: gridSize)
            )
        }
        let before = circuit.wires.count
        for comp in circuit.components {
            _ = connectComponent(comp)
        }
        solver.rebuildNetlist()
        let created = circuit.wires.count - before
        lastConnectedWireDescription = created == 0
            ? "📐 Aligned to grid"
            : "📐 Aligned to grid - \(created) new connection\(created == 1 ? "" : "s")"
        objectWillChange.send()
    }

    // MARK: - File: New / Open / Save

    public var documentName: String {
        currentFileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    private func loadCircuit(_ newCircuit: Circuit, url: URL?) {
        circuit = newCircuit
        solver = makeSolver(for: newCircuit)
        currentFileURL = url
        selectedComponentId = nil
        selectedWireId = nil
        cancelWiring()
        panOffset = .zero
        oscilloscopeChannelACompId = newCircuit.components.first(where: { $0.kind.isCapacitive || $0.kind.isJunctionDiode || $0.kind == .resistor })?.id
        oscilloscopeChannelBCompId = nil
        resetSimulation()
    }

    public func newDocument() {
        if !circuit.components.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Start a new circuit?"
            alert.informativeText = "The current circuit will be closed. Anything you have not saved will be lost."
            alert.addButton(withTitle: "Discard & New")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        loadCircuit(Circuit(), url: nil)
        lastConnectedWireDescription = nil
    }

    public func openDocument() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Open a MultiSim circuit"
        if let t = UTType(filenameExtension: "msim") {
            panel.allowedContentTypes = [t, UTType.json]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let loaded = try JSONDecoder().decode(Circuit.self, from: data)
            loadCircuit(loaded, url: url)
            lastConnectedWireDescription = "📂 Opened \(url.lastPathComponent)"
        } catch {
            showFileError("Could not open the file.", error)
        }
    }

    public func saveDocument() {
        if let url = currentFileURL {
            write(to: url)
        } else {
            saveDocumentAs()
        }
    }

    public func saveDocumentAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(documentName).msim"
        panel.message = "Save your circuit"
        if let t = UTType(filenameExtension: "msim") {
            panel.allowedContentTypes = [t]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url)
    }

    private func write(to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(circuit)
            try data.write(to: url, options: .atomic)
            currentFileURL = url
            lastConnectedWireDescription = "💾 Saved \(url.lastPathComponent)"
        } catch {
            showFileError("Could not save the file.", error)
        }
    }

    private func showFileError(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    public func rotateSelected() {
        guard let id = selectedComponentId,
              let comp = circuit.components.first(where: { $0.id == id }) else { return }
        comp.rotation = (comp.rotation + 90) % 360
        _ = connectComponent(comp)
        solver.rebuildNetlist()
        objectWillChange.send()
    }

    public func deleteSelected() {
        if let id = selectedComponentId {
            let pinIds = Set(circuit.components.first(where: { $0.id == id })?.pins.map { $0.id } ?? [])
            circuit.wires.removeAll { pinIds.contains($0.startPinId) || pinIds.contains($0.endPinId) }
            circuit.components.removeAll { $0.id == id }
            selectedComponentId = nil
            solver.rebuildNetlist()
        } else if let wireId = selectedWireId {
            circuit.wires.removeAll { $0.id == wireId }
            selectedWireId = nil
            solver.rebuildNetlist()
        }
    }

    public func toggleSwitch(componentId: UUID) {
        guard let comp = circuit.components.first(where: { $0.id == componentId }),
              comp.kind == .switchSPST else { return }
        comp.stateBool.toggle()
        objectWillChange.send()
    }

    // MARK: - Wiring Logic

    public func handlePinClicked(componentId: UUID, pin: Pin) {
        if let draft = wireDraftStartPin {
            // If clicked different pin, complete the wire!
            if draft.pin.id != pin.id {
                if !hasWire(between: draft.pin.id, and: pin.id) {
                    circuit.wires.append(Wire(startPinId: draft.pin.id, endPinId: pin.id))
                }
                solver.rebuildNetlist()

                let startName = circuit.components.first(where: { $0.id == draft.componentId })?.designator ?? "Pin"
                let targetName = circuit.components.first(where: { $0.id == componentId })?.designator ?? "Pin"
                lastConnectedWireDescription = "✅ Connected \(startName) → \(targetName)"
            }
            wireDraftStartPin = nil
            wireDraftCurrentPoint = nil
            wireDraftTargetPinId = nil
        } else {
            // Start wiring from this pin
            wireDraftStartPin = (componentId, pin)
            if let startComp = circuit.components.first(where: { $0.id == componentId }) {
                let p = startComp.absolutePinPosition(pinIndex: pin.index)
                wireDraftCurrentPoint = CGPoint(x: p.x, y: p.y)
                lastConnectedWireDescription = "⚡️ Wiring from \(startComp.designator) '\(pin.name)' — release on another terminal, or on a wire to join it"
            }
        }
    }

    /// Drops the draft onto an existing wire, joining that net with a T-junction.
    public func completeWireDraft(ontoWire wire: Wire, at point: Point2D) {
        guard let draft = wireDraftStartPin else { return }
        let endPin = tapEndPin(for: wire, near: point)
        if !hasWire(between: draft.pin.id, and: endPin) {
            circuit.wires.append(Wire(startPinId: draft.pin.id, endPinId: endPin, waypoints: [point]))
            solver.rebuildNetlist()
            let target = circuit.components.first(where: { c in c.pins.contains { $0.id == endPin } })?.designator ?? "wire"
            lastConnectedWireDescription = "✅ Tapped into \(target)'s net"
        }
        wireDraftStartPin = nil
        wireDraftCurrentPoint = nil
        wireDraftTargetPinId = nil
        objectWillChange.send()
    }

    public func cancelWiring() {
        wireDraftStartPin = nil
        wireDraftCurrentPoint = nil
        wireDraftTargetPinId = nil
        lastConnectedWireDescription = nil
    }

    public func diagnoseCircuit() -> CircuitDiagnosticReport {
        return CircuitDiagnostics.diagnose(circuit: circuit, solver: solver)
    }

    // MARK: - Preset lab circuits

    /// 130 V RMS mains-style source, entered as the peak the AC source expects.
    static let labSourcePeak = 130.0 * 2.0.squareRoot()

    public func loadPreset(type: PresetType) {
        switch type {
        case .seriesRLC50Hz:
            // 130 V RMS (183.85 V peak) 50 Hz -> R 200 Ω -> L 0.237 H -> C 18 µF -> back to the source.
            let v1 = CircuitComponent(kind: .acVoltageSource, designator: "Vs", position: Point2D(x: 140, y: 240), value: Self.labSourcePeak, secondaryValue: 50.0)
            let r1 = CircuitComponent(kind: .resistor, designator: "R", position: Point2D(x: 260, y: 160), value: 200.0)
            let l1 = CircuitComponent(kind: .inductor, designator: "L", position: Point2D(x: 380, y: 160), value: 0.237)
            let c1 = CircuitComponent(kind: .capacitor, designator: "C", position: Point2D(x: 480, y: 240), rotation: 90, value: 18e-6)
            let gnd = CircuitComponent(kind: .ground, designator: "GND", position: Point2D(x: 300, y: 340))

            let wires = [
                Wire(startPinId: v1.pins[0].id, endPinId: r1.pins[0].id),
                Wire(startPinId: r1.pins[1].id, endPinId: l1.pins[0].id),
                Wire(startPinId: l1.pins[1].id, endPinId: c1.pins[0].id),
                Wire(startPinId: c1.pins[1].id, endPinId: gnd.pins[0].id),
                Wire(startPinId: v1.pins[1].id, endPinId: gnd.pins[0].id),
            ]
            circuit = Circuit(components: [v1, r1, l1, c1, gnd], wires: wires)

        case .parallelRLRC50Hz:
            // As on the printout: 130 V RMS 50 Hz across two branches,
            // branch 1 (inductive) R1 200 Ω + L 0.239 H, branch 2 (capacitive) R2 200 Ω + C 18 µF.
            let v1 = CircuitComponent(kind: .acVoltageSource, designator: "Vs", position: Point2D(x: 140, y: 260), value: Self.labSourcePeak, secondaryValue: 50.0)
            let r1 = CircuitComponent(kind: .resistor, designator: "R1", position: Point2D(x: 280, y: 160), value: 200.0)
            let l1 = CircuitComponent(kind: .inductor, designator: "L", position: Point2D(x: 400, y: 160), value: 0.239)
            let r2 = CircuitComponent(kind: .resistor, designator: "R2", position: Point2D(x: 280, y: 360), value: 200.0)
            let c1 = CircuitComponent(kind: .capacitor, designator: "C", position: Point2D(x: 400, y: 360), value: 18e-6)
            let gnd = CircuitComponent(kind: .ground, designator: "GND", position: Point2D(x: 520, y: 440))

            let wires = [
                Wire(startPinId: v1.pins[0].id, endPinId: r1.pins[0].id),
                Wire(startPinId: v1.pins[0].id, endPinId: r2.pins[0].id),
                Wire(startPinId: r1.pins[1].id, endPinId: l1.pins[0].id),
                Wire(startPinId: r2.pins[1].id, endPinId: c1.pins[0].id),
                Wire(startPinId: l1.pins[1].id, endPinId: gnd.pins[0].id),
                Wire(startPinId: c1.pins[1].id, endPinId: gnd.pins[0].id),
                Wire(startPinId: v1.pins[1].id, endPinId: gnd.pins[0].id),
            ]
            circuit = Circuit(components: [v1, r1, l1, r2, c1, gnd], wires: wires)

        case .parallelCase1RL, .parallelCase2RC, .parallelCase3Both:
            let sw = type.parallelCaseSwitches ?? (true, true)
            circuit = LabCircuits.acParallelBench(rlClosed: sw.rl, rcClosed: sw.rc)

        }

        selectedComponentId = nil
        selectedWireId = nil
        solver = makeSolver(for: circuit)
        oscilloscopeChannelACompId = circuit.components.first(where: { $0.kind.isCapacitive || $0.kind.isJunctionDiode || $0.kind == .resistor })?.id
        oscilloscopeChannelBCompId = nil
        oscilloscopeChannelAShowsCurrent = false
        oscilloscopeChannelBShowsCurrent = false
        if type == .seriesRLC50Hz || type == .parallelRLRC50Hz || type.parallelCaseSwitches != nil {
            // Source voltage on CH1, the (first) branch current on CH2, scaled to fit 183.85 V peak.
            oscilloscopeChannelACompId = circuit.components.first(where: { $0.kind == .acVoltageSource })?.id
            oscilloscopeChannelBCompId = type.parallelCaseSwitches != nil
                ? circuit.components.first(where: { $0.kind == .ammeter && $0.designator == "I" })?.id
                : circuit.components.first(where: { $0.kind == .resistor })?.id
            oscilloscopeChannelBShowsCurrent = true
            oscilloscopeVoltsPerDivA = 50.0
            oscilloscopeVoltsPerDivB = 0.2
            oscilloscopeTimeScale = 0.005
            showOscilloscope = true
        }
        resetSimulation()
        lastConnectedWireDescription = "🧪 \(type.rawValue) loaded — every terminal is already wired"
    }


    // MARK: - Live instrument readout text

    /// The number an instrument face shows right now.
    public func readingText(for comp: CircuitComponent) -> String {
        switch comp.kind {
        case .ammeter, .galvanometer:
            return EngineeringFormatter.current(comp.runtimeReading)
        case .voltmeter:
            return EngineeringFormatter.voltage(comp.runtimeReading)
        case .ohmmeter:
            return EngineeringFormatter.resistance(comp.runtimeReading)
        case .wattmeter:
            return EngineeringFormatter.power(comp.runtimeReading)
        case .multimeter:
            switch MeterMode(rawValue: comp.modeIndex) ?? .voltage {
            case .voltage: return EngineeringFormatter.voltage(comp.runtimeReading)
            case .current: return EngineeringFormatter.current(comp.runtimeReading)
            case .resistance: return EngineeringFormatter.resistance(comp.runtimeReading)
            }
        case .probe:
            return EngineeringFormatter.voltage(comp.runtimeReading)
        case .switchSPST:
            return comp.stateBool ? "CLOSED" : "OPEN"
        case .fuse:
            return comp.stateBool ? EngineeringFormatter.current(comp.fuseRating) : "BLOWN"
        case .led:
            return comp.ledColor.rawValue.capitalized
        case .potentiometer, .rheostat:
            return EngineeringFormatter.resistance(comp.value * Self.wiperRatio(comp))
        default:
            return ""
        }
    }

    static func wiperRatio(_ comp: CircuitComponent) -> Double {
        MNASolver.wiperRatio(of: comp)
    }
}

/// Compact engineering units for instrument faces and part labels.
public enum EngineeringFormatter {
    public static func resistance(_ val: Double) -> String { units(val, "Ω") }
    public static func voltage(_ val: Double) -> String { units(val, "V") }
    public static func current(_ val: Double) -> String { units(val, "A") }
    public static func power(_ val: Double) -> String { units(val, "W") }
    public static func capacitance(_ val: Double) -> String { units(val, "F") }
    public static func inductance(_ val: Double) -> String { units(val, "H") }

    public static func units(_ val: Double, _ unit: String) -> String {
        let a = abs(val)
        guard a > 0 else { return "0 \(unit)" }
        if a >= 1e6 { return String(format: "%.3g M%@", a / 1e6, unit) }
        if a >= 1e3 { return String(format: "%.3g k%@", a / 1e3, unit) }
        if a >= 1 { return String(format: "%.3g %@", a, unit) }
        if a >= 1e-3 { return String(format: "%.3g m%@", a * 1e3, unit) }
        if a >= 1e-6 { return String(format: "%.3g µ%@", a * 1e6, unit) }
        if a >= 1e-9 { return String(format: "%.3g n%@", a * 1e9, unit) }
        if a >= 1e-12 { return String(format: "%.3g p%@", a * 1e12, unit) }
        return String(format: "%.3g %@", a, unit)
    }
}

extension CircuitComponent {
    /// Rated current of a fuse, defaulting to 1 A.
    public var fuseRating: Double { secondaryValue > 0 ? secondaryValue : 1.0 }
}

public enum PresetType: String, CaseIterable, Identifiable {
    case seriesRLC50Hz = "Lab 1: AC Series RLC, 130 V 50 Hz"
    case parallelCase1RL = "Lab 2: AC Parallel Case 1 - RL Branch Only"
    case parallelCase2RC = "Lab 3: AC Parallel Case 2 - RC Branch Only"
    case parallelCase3Both = "Lab 4: AC Parallel Case 3 - Both Branches"
    case parallelRLRC50Hz = "Lab 5: AC Parallel RL || RC, 130 V 50 Hz"

    /// The three cases of the AC parallel experiment, chosen by switches 3-4 and 5-6.
    public var parallelCaseSwitches: (rl: Bool, rc: Bool)? {
        switch self {
        case .parallelCase1RL: return (true, false)
        case .parallelCase2RC: return (false, true)
        case .parallelCase3Both: return (true, true)
        default: return nil
        }
    }

    public var id: String { rawValue }
}
