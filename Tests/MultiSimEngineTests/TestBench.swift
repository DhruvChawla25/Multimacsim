import XCTest
@testable import MultiSimEngine

/// Small helper for wiring test circuits without spelling out every Wire by hand.
final class TestBench {
    private(set) var components: [CircuitComponent] = []
    private(set) var wires: [Wire] = []
    let gnd = CircuitComponent(kind: .ground, designator: "GND")

    init() { components.append(gnd) }

    @discardableResult
    func add(_ kind: ComponentKind, _ name: String, value: Double? = nil, secondary: Double? = nil,
             mode: Int? = nil, closed: Bool? = nil) -> CircuitComponent {
        let d = kind.partDefaults
        let c = CircuitComponent(kind: kind, designator: name,
                                 value: value ?? d.value, secondaryValue: secondary ?? d.secondaryValue,
                                 stateBool: closed ?? d.isClosed, modeIndex: mode ?? d.modeIndex)
        components.append(c)
        return c
    }

    func wire(_ a: Pin, _ b: Pin) { wires.append(Wire(startPinId: a.id, endPinId: b.id)) }
    func ground(_ pins: Pin...) { for p in pins { wire(p, gnd.pins[0]) } }

    lazy var circuit: Circuit = Circuit(components: components, wires: wires)

    func solver(dt: Double = 1e-4) -> MNASolver { MNASolver(circuit: circuit, timeStep: dt) }

    func node(_ pin: Pin) -> Int { circuit.resolveNodes().pinToNode[pin.id] ?? 0 }

    func voltage(_ pin: Pin, _ res: SimulationStepResult) -> Double {
        let n = node(pin)
        return n == 0 ? 0 : res.nodeVoltages[n] ?? 0
    }
}
