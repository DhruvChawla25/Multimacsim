import Foundation

/// Defines all supported electronic component types and their parameter models.
public enum ComponentKind: String, Codable, CaseIterable {
    // Power & Ground
    case ground = "Ground"
    case dcVoltageSource = "DC Voltage Source"
    case acVoltageSource = "AC Voltage Source"
    case dcCurrentSource = "DC Current Source"
    case clockSource = "Clock / Pulse Source"
    case functionGenerator = "Function Generator"

    // Measuring Instruments
    case ammeter = "Ammeter"
    case voltmeter = "Voltmeter"
    case galvanometer = "Galvanometer"
    case ohmmeter = "Ohmmeter"
    case wattmeter = "Wattmeter"
    case multimeter = "Multimeter (DMM)"

    // Passive
    case resistor = "Resistor"
    case capacitor = "Capacitor"
    case electrolyticCapacitor = "Electrolytic Capacitor"
    case trimmerCapacitor = "Trimmer Capacitor"
    case inductor = "Inductor"
    case potentiometer = "Potentiometer"
    case rheostat = "Rheostat"
    case switchSPST = "Switch (SPST)"
    case lamp = "Filament Lamp"
    case fuse = "Fuse"
    case thermistor = "Thermistor (NTC)"
    case photoResistor = "LDR (Photoresistor)"

    // Semiconductors
    case diode = "Diode"
    case led = "LED"
    case zenerDiode = "Zener Diode"
    case schottkyDiode = "Schottky Diode"
    case bjtNPN = "NPN Transistor"
    case bjtPNP = "PNP Transistor"

    // Active & ICs
    case opAmp = "Operational Amplifier"
    case vcvs = "VCVS (Voltage-Controlled Voltage Source)"
    case vccs = "VCCS (Voltage-Controlled Current Source)"
    case logicAND = "AND Gate"
    case logicOR = "OR Gate"
    case logicNOT = "NOT Gate"
    case logicNAND = "NAND Gate"
    case logicNOR = "NOR Gate"
    case logicXOR = "XOR Gate"
    case logicXNOR = "XNOR Gate"
    case logicBuffer = "Buffer"

    // Power sources (v6)
    case threePhaseWye = "Three-Phase Voltage Source (Wye)"
    case threePhaseDelta = "Three-Phase Voltage Source (Delta)"
    case vccRail = "VCC Supply"
    case vddRail = "VDD Supply"
    case veeRail = "VEE Supply"
    case vssRail = "VSS Supply"
    case digitalGround = "Digital Ground"
    case amVoltage = "AM Voltage Source"
    case fmVoltage = "FM Voltage Source"
    case exponentialVoltage = "Exponential Voltage Source"
    case pwlVoltage = "Piecewise Linear Voltage Source"
    case pulseVoltage = "Pulse Voltage Source"
    case bipolarVoltage = "Bipolar Voltage Source"
    case whiteNoiseVoltage = "White Noise Voltage Source"
    case acCurrentSource = "AC Current Source"
    case clockCurrentSource = "Clock Current Source"
    case exponentialCurrentSource = "Exponential Current Source"
    case fmCurrentSource = "FM Current Source"
    case pwlCurrentSource = "Piecewise Linear Current Source"
    // Controlled sources (v6): current-controlled through a sense branch between I+ and I-
    case ccvs = "CCVS (Current-Controlled Voltage Source)"
    case cccs = "CCCS (Current-Controlled Current Source)"
    case abmVoltage = "ABM Voltage Source"
    case abmCurrent = "ABM Current Source"
    case vcoSine = "Voltage-Controlled Sine Wave"
    case vcoSquare = "Voltage-Controlled Square Wave"
    case vcoTriangle = "Voltage-Controlled Triangle Wave"
    case gainBlock = "Voltage Gain Block"
    case multiplierBlock = "Voltage Multiplier"
    case dividerBlock = "Voltage Divider Block"
    case summerBlock = "Voltage Summer"
    case integratorBlock = "Voltage Integrator"
    case differentiatorBlock = "Voltage Differentiator"
    case limiterBlock = "Voltage Limiter"
    case hysteresisBlock = "Voltage Hysteresis Block"
    case slewRateBlock = "Voltage Slew Rate Block"
    case polynomialBlock = "Polynomial Voltage Block"
    case transferFunctionBlock = "Transfer Function Block"
    // Digital sources (v6): one output terminal, logic levels against (digital) ground
    case digitalClock = "Digital Clock"
    case digitalConstant = "Digital Constant"
    // Probes
    case probe = "Voltage Probe"
}

/// Grouping used by the palette so every part shows up on the same surface, in a fixed order.
public enum PartCategory: String, CaseIterable, Sendable {
    case instruments = "Measuring Instruments"
    // The Multisim "Sources" group, family by family.
    case powerSources = "Power Sources"
    case signalVoltageSources = "Signal Voltage Sources"
    case signalCurrentSources = "Signal Current Sources"
    case controlledSources = "Controlled Sources"
    case controlFunctionBlocks = "Control Function Blocks"
    case digitalSources = "Digital Sources"
    case passives = "Passives & Loads"
    case semiconductors = "Semiconductors"
    case analogLogic = "Analog & Logic ICs"
    case probes = "Probes & Test"
}

extension ComponentKind {
    public var category: PartCategory {
        switch self {
        case .ground, .dcVoltageSource:
            return .powerSources
        case .acVoltageSource, .clockSource:
            return .signalVoltageSources
        case .dcCurrentSource:
            return .signalCurrentSources
        case .vcvs, .vccs:
            return .controlledSources
        case .ammeter, .voltmeter, .galvanometer, .ohmmeter, .wattmeter, .multimeter, .functionGenerator:
            return .instruments
        case .resistor, .capacitor, .electrolyticCapacitor, .trimmerCapacitor, .inductor,
             .potentiometer, .rheostat, .switchSPST, .lamp, .fuse, .thermistor, .photoResistor:
            return .passives
        case .diode, .led, .zenerDiode, .schottkyDiode, .bjtNPN, .bjtPNP:
            return .semiconductors
        case .opAmp, .logicAND, .logicOR, .logicNOT, .logicNAND, .logicNOR,
             .logicXOR, .logicXNOR, .logicBuffer:
            return .analogLogic
        case .threePhaseWye, .threePhaseDelta:
            return .powerSources
        case .vccRail, .vddRail, .veeRail, .vssRail, .digitalGround:
            return .powerSources
        case .amVoltage:
            return .signalVoltageSources
        case .fmVoltage:
            return .signalVoltageSources
        case .exponentialVoltage:
            return .signalVoltageSources
        case .pwlVoltage:
            return .signalVoltageSources
        case .pulseVoltage:
            return .signalVoltageSources
        case .bipolarVoltage:
            return .signalVoltageSources
        case .whiteNoiseVoltage:
            return .signalVoltageSources
        case .acCurrentSource:
            return .signalCurrentSources
        case .clockCurrentSource:
            return .signalCurrentSources
        case .exponentialCurrentSource:
            return .signalCurrentSources
        case .fmCurrentSource:
            return .signalCurrentSources
        case .pwlCurrentSource:
            return .signalCurrentSources
        case .ccvs, .cccs:
            return .controlledSources
        case .abmVoltage, .abmCurrent:
            return .controlledSources
        case .vcoSine, .vcoSquare, .vcoTriangle:
            return .controlledSources
        case .gainBlock:
            return .controlFunctionBlocks
        case .multiplierBlock:
            return .controlFunctionBlocks
        case .dividerBlock:
            return .controlFunctionBlocks
        case .summerBlock:
            return .controlFunctionBlocks
        case .integratorBlock:
            return .controlFunctionBlocks
        case .differentiatorBlock:
            return .controlFunctionBlocks
        case .limiterBlock:
            return .controlFunctionBlocks
        case .hysteresisBlock:
            return .controlFunctionBlocks
        case .slewRateBlock:
            return .controlFunctionBlocks
        case .polynomialBlock:
            return .controlFunctionBlocks
        case .transferFunctionBlock:
            return .controlFunctionBlocks
        case .digitalClock:
            return .digitalSources
        case .digitalConstant:
            return .digitalSources
        case .probe:
            return .probes
        }
    }

    /// Designator prefix used when the part is placed on the canvas.
    public var designatorPrefix: String {
        switch self {
        case .ground: return "GND"
        case .dcVoltageSource, .acVoltageSource: return "V"
        case .dcCurrentSource: return "I"
        case .clockSource: return "CLK"
        case .functionGenerator: return "FG"
        case .ammeter: return "A"
        case .voltmeter: return "V"
        case .galvanometer: return "G"
        case .ohmmeter: return "OHM"
        case .wattmeter: return "W"
        case .multimeter: return "DMM"
        case .resistor: return "R"
        case .capacitor, .electrolyticCapacitor, .trimmerCapacitor: return "C"
        case .inductor: return "L"
        case .potentiometer: return "POT"
        case .rheostat: return "RH"
        case .switchSPST: return "SW"
        case .lamp: return "LS"
        case .fuse: return "F"
        case .thermistor: return "TH"
        case .photoResistor: return "LDR"
        case .diode, .schottkyDiode: return "D"
        case .led: return "LED"
        case .zenerDiode: return "ZD"
        case .bjtNPN, .bjtPNP: return "Q"
        case .opAmp: return "U"
        case .vcvs: return "E"
        case .vccs: return "G"
        case .logicAND: return "U_AND"
        case .logicOR: return "U_OR"
        case .logicNOT: return "U_NOT"
        case .logicNAND: return "U_NAND"
        case .logicNOR: return "U_NOR"
        case .logicXOR: return "U_XOR"
        case .logicXNOR: return "U_XNOR"
        case .logicBuffer: return "U_BUF"
        case .threePhaseWye, .threePhaseDelta: return "V"
        case .vccRail: return "VCC"
        case .vddRail: return "VDD"
        case .veeRail: return "VEE"
        case .vssRail: return "VSS"
        case .digitalGround: return "DGND"
        case .amVoltage: return "V"
        case .fmVoltage: return "V"
        case .exponentialVoltage: return "V"
        case .pwlVoltage: return "V"
        case .pulseVoltage: return "V"
        case .bipolarVoltage: return "V"
        case .whiteNoiseVoltage: return "V"
        case .acCurrentSource: return "I"
        case .clockCurrentSource: return "I"
        case .exponentialCurrentSource: return "I"
        case .fmCurrentSource: return "I"
        case .pwlCurrentSource: return "I"
        case .ccvs: return "H"
        case .cccs: return "F"
        case .abmVoltage: return "B"
        case .abmCurrent: return "B"
        case .vcoSine, .vcoSquare, .vcoTriangle: return "VCO"
        case .gainBlock: return "A"
        case .multiplierBlock: return "A"
        case .dividerBlock: return "A"
        case .summerBlock: return "A"
        case .integratorBlock: return "A"
        case .differentiatorBlock: return "A"
        case .limiterBlock: return "A"
        case .hysteresisBlock: return "A"
        case .slewRateBlock: return "A"
        case .polynomialBlock: return "A"
        case .transferFunctionBlock: return "A"
        case .digitalClock: return "U_CLK"
        case .digitalConstant: return "U_LOGIC"
        case .probe: return "P"
        }
    }

    /// Short name shown in the palette row.
    public var paletteLabel: String {
        switch self {
        case .ground: return "Ground (0V)"
        case .dcVoltageSource: return "DC Voltage Source"
        case .acVoltageSource: return "AC Sine Source"
        case .dcCurrentSource: return "Current Source"
        case .clockSource: return "Clock Pulse"
        case .functionGenerator: return "Function Generator"
        case .ammeter: return "Ammeter (series A)"
        case .voltmeter: return "Voltmeter (parallel V)"
        case .galvanometer: return "Galvanometer"
        case .ohmmeter: return "Ohmmeter"
        case .wattmeter: return "Wattmeter"
        case .multimeter: return "Multimeter / DMM"
        case .resistor: return "Resistor"
        case .capacitor: return "Capacitor"
        case .electrolyticCapacitor: return "Electrolytic Cap"
        case .trimmerCapacitor: return "Trimmer Cap"
        case .inductor: return "Inductor"
        case .potentiometer: return "Potentiometer (3-wire)"
        case .rheostat: return "Rheostat (variable R)"
        case .switchSPST: return "SPST Switch"
        case .lamp: return "Filament Lamp"
        case .fuse: return "Fuse"
        case .thermistor: return "Thermistor NTC"
        case .photoResistor: return "LDR (light)"
        case .diode: return "Diode (1N4148)"
        case .led: return "LED"
        case .zenerDiode: return "Zener Diode"
        case .schottkyDiode: return "Schottky Diode"
        case .bjtNPN: return "NPN Transistor"
        case .bjtPNP: return "PNP Transistor"
        case .opAmp: return "Operational Amplifier"
        case .vcvs: return "VCVS (Voltage Controlled)"
        case .vccs: return "VCCS (Voltage Controlled I)"
        case .logicAND: return "AND Gate"
        case .logicOR: return "OR Gate"
        case .logicNOT: return "NOT Inverter"
        case .logicNAND: return "NAND Gate"
        case .logicNOR: return "NOR Gate"
        case .logicXOR: return "XOR Gate"
        case .logicXNOR: return "XNOR Gate"
        case .logicBuffer: return "Buffer"
        case .threePhaseWye: return "3-Phase Wye (Star)"
        case .threePhaseDelta: return "3-Phase Delta"
        case .vccRail: return "VCC Rail"
        case .vddRail: return "VDD Rail"
        case .veeRail: return "VEE Rail"
        case .vssRail: return "VSS Rail"
        case .digitalGround: return "Digital Ground"
        case .amVoltage: return "AM Voltage"
        case .fmVoltage: return "FM Voltage"
        case .exponentialVoltage: return "Exponential Voltage"
        case .pwlVoltage: return "PWL Voltage"
        case .pulseVoltage: return "Pulse Voltage"
        case .bipolarVoltage: return "Bipolar Voltage (±V square)"
        case .whiteNoiseVoltage: return "White Noise Voltage"
        case .acCurrentSource: return "AC Current Source"
        case .clockCurrentSource: return "Clock / Pulse Current"
        case .exponentialCurrentSource: return "Exponential Current"
        case .fmCurrentSource: return "FM Current"
        case .pwlCurrentSource: return "PWL Current"
        case .ccvs: return "CCVS (Current Controlled V)"
        case .cccs: return "CCCS (Current Controlled I)"
        case .abmVoltage: return "ABM Voltage (expression)"
        case .abmCurrent: return "ABM Current (expression)"
        case .vcoSine: return "Voltage-Controlled Sine"
        case .vcoSquare: return "Voltage-Controlled Square"
        case .vcoTriangle: return "Voltage-Controlled Triangle"
        case .gainBlock: return "Gain Block (K)"
        case .multiplierBlock: return "Multiplier (X·Y)"
        case .dividerBlock: return "Divider (X / Y)"
        case .summerBlock: return "Summer (A + B + C)"
        case .integratorBlock: return "Integrator (∫)"
        case .differentiatorBlock: return "Differentiator (d/dt)"
        case .limiterBlock: return "Limiter (clip)"
        case .hysteresisBlock: return "Hysteresis (Schmitt)"
        case .slewRateBlock: return "Slew Rate Limiter"
        case .polynomialBlock: return "Polynomial P(x)"
        case .transferFunctionBlock: return "Transfer Function H(s)"
        case .digitalClock: return "Digital Clock"
        case .digitalConstant: return "Digital Constant (0 / 1)"
        case .probe: return "Voltage Probe"
        }
    }

    public var sfSymbol: String {
        switch self {
        case .ground: return "arrow.down.to.line"
        case .dcVoltageSource: return "battery.100.bolt"
        case .acVoltageSource: return "waveform"
        case .clockSource: return "metronome"
        case .dcCurrentSource: return "arrow.up.circle"
        case .functionGenerator: return "waveform.path"
        case .ammeter: return "speedometer"
        case .voltmeter: return "bolt.horizontal"
        case .galvanometer: return "scalemass"
        case .ohmmeter: return "ruler"
        case .wattmeter: return "flame"
        case .multimeter: return "plusminus"
        case .resistor: return "alternatingcurrent"
        case .capacitor: return "pause"
        case .electrolyticCapacitor: return "capsule.portrait"
        case .trimmerCapacitor: return "slider.vertical.3"
        case .inductor: return "rotate.right"
        case .potentiometer: return "slider.horizontal.3"
        case .rheostat: return "dial.low.fill"
        case .switchSPST: return "switch.2"
        case .lamp: return "lightbulb"
        case .fuse: return "capsule"
        case .thermistor: return "thermometer"
        case .photoResistor: return "sun.max"
        case .diode: return "arrowtriangle.right.fill"
        case .led: return "lightbulb.fill"
        case .zenerDiode: return "bolt.fill"
        case .schottkyDiode: return "arrowtriangle.right.circle"
        case .bjtNPN: return "arrow.up.right.circle"
        case .bjtPNP: return "arrow.down.right.circle"
        case .opAmp: return "triangle.fill"
        case .vcvs: return "diamond.fill"
        case .vccs: return "diamond"
        case .logicAND: return "square.split.diagonal.2x2"
        case .logicOR: return "shield"
        case .logicNOT: return "circle.slash"
        case .logicNAND: return "square.split.diagonal"
        case .logicNOR: return "shield.slash"
        case .logicXOR: return "divide"
        case .logicXNOR: return "equals"
        case .logicBuffer: return "arrow.right.to.line"
        case .threePhaseWye: return "asterisk.circle"
        case .threePhaseDelta: return "triangle.circle"
        case .vccRail, .vddRail: return "arrow.up.to.line"
        case .veeRail, .vssRail: return "arrow.down.to.line.compact"
        case .digitalGround: return "arrowtriangle.down"
        case .amVoltage: return "antenna.radiowaves.left.and.right"
        case .fmVoltage: return "dot.radiowaves.left.and.right"
        case .exponentialVoltage: return "chart.line.uptrend.xyaxis"
        case .pwlVoltage: return "chart.xyaxis.line"
        case .pulseVoltage: return "square.on.square.dashed"
        case .bipolarVoltage: return "plusminus.circle"
        case .whiteNoiseVoltage: return "waveform.badge.magnifyingglass"
        case .acCurrentSource: return "waveform.circle"
        case .clockCurrentSource: return "metronome.fill"
        case .exponentialCurrentSource: return "chart.line.uptrend.xyaxis.circle"
        case .fmCurrentSource: return "dot.radiowaves.right"
        case .pwlCurrentSource: return "chart.xyaxis.line"
        case .ccvs: return "diamond.lefthalf.filled"
        case .cccs: return "diamond.righthalf.filled"
        case .abmVoltage: return "function"
        case .abmCurrent: return "x.squareroot"
        case .vcoSine: return "waveform.path.ecg.rectangle"
        case .vcoSquare: return "square.on.circle"
        case .vcoTriangle: return "triangle.bottomhalf.filled"
        case .gainBlock: return "multiply.circle"
        case .multiplierBlock: return "xmark.circle"
        case .dividerBlock: return "divide.circle"
        case .summerBlock: return "sum"
        case .integratorBlock: return "sum"
        case .differentiatorBlock: return "chart.line.downtrend.xyaxis"
        case .limiterBlock: return "rectangle.compress.vertical"
        case .hysteresisBlock: return "arrow.left.arrow.right.square"
        case .slewRateBlock: return "speedometer"
        case .polynomialBlock: return "function"
        case .transferFunctionBlock: return "function"
        case .digitalClock: return "clock.badge"
        case .digitalConstant: return "01.square"
        case .probe: return "pin"
        }
    }

    /// True when the part measures the circuit rather than being part of it.
    public var isInstrument: Bool {
        category == .instruments || self == .probe
    }

    /// True for every family of the Multisim Sources group.
    public var isSource: Bool {
        switch category {
        case .powerSources, .signalVoltageSources, .signalCurrentSources, .controlledSources,
             .controlFunctionBlocks, .digitalSources:
            return true
        default:
            return self == .functionGenerator
        }
    }

    /// Parts whose label shows a live measured value instead of a static rating.
    public var showsLiveReading: Bool {
        switch self {
        case .ammeter, .voltmeter, .galvanometer, .ohmmeter, .wattmeter, .multimeter, .probe:
            return true
        default:
            return false
        }
    }

    /// Two-terminal parts that behave as a plain resistance in the MNA matrix.
    public var isLinearResistive: Bool {
        switch self {
        case .resistor, .switchSPST, .potentiometer, .rheostat, .lamp, .fuse, .thermistor,
             .photoResistor, .ammeter, .voltmeter, .galvanometer:
            return true
        default:
            return false
        }
    }

    /// Two-terminal parts that behave as a capacitor (backward-Euler companion model).
    public var isCapacitive: Bool {
        self == .capacitor || self == .electrolyticCapacitor || self == .trimmerCapacitor
    }

    /// Parts conducting through a PN-junction style exponential model.
    public var isJunctionDiode: Bool {
        switch self {
        case .diode, .led, .schottkyDiode: return true
        default: return false
        }
    }

    /// Ideal voltage sources that need an auxiliary MNA variable.
    public var isVoltageSourceType: Bool {
        switch self {
        case .dcVoltageSource, .acVoltageSource, .clockSource, .functionGenerator,
             .threePhaseWye, .threePhaseDelta: return true
        default: return false
        }
    }

    /// Two-terminal independent voltage sources whose value comes from `SourceWaveforms` (+ on pin 0).
    public var isWaveformVoltageSource: Bool {
        switch self {
        case .whiteNoiseVoltage: return true
        case .bipolarVoltage: return true
        case .pulseVoltage: return true
        case .pwlVoltage: return true
        case .exponentialVoltage: return true
        case .fmVoltage: return true
        case .amVoltage: return true
        case .dcVoltageSource, .acVoltageSource, .clockSource, .functionGenerator:
            return true
        default:
            return false
        }
    }

    /// Two-terminal independent current sources; current leaves pin 0, where the arrow points.
    public var isWaveformCurrentSource: Bool {
        switch self {
        case .pwlCurrentSource: return true
        case .fmCurrentSource: return true
        case .exponentialCurrentSource: return true
        case .clockCurrentSource: return true
        case .acCurrentSource: return true
        case .dcCurrentSource:
            return true
        default:
            return false
        }
    }

    /// Control function blocks: ideal inputs, ideal voltage output to ground.
    public var isControlBlock: Bool { category == .controlFunctionBlocks }

    /// One-terminal logic sources driving their output against ground (0 V / high level).
    public var isDigitalSource: Bool { category == .digitalSources }

    /// Voltage-controlled sine / square / triangle oscillators.
    public var isVoltageControlledOscillator: Bool {
        switch self {
        case .vcoSine, .vcoSquare, .vcoTriangle: return true
        default: return false
        }
    }

    /// VCC / VDD / VEE / VSS: one-terminal DC supplies to ground whose symbols share a global net.
    public var isSupplyRail: Bool {
        switch self {
        case .vccRail, .vddRail, .veeRail, .vssRail: return true
        default: return false
        }
    }

    /// Parts that tie their terminal to node 0.
    public var isGroundReference: Bool { self == .ground || self == .digitalGround }

    /// Digital gate parts.
    public var isLogicGate: Bool {
        switch self {
        case .logicAND, .logicOR, .logicNOT, .logicNAND, .logicNOR, .logicXOR, .logicXNOR, .logicBuffer:
            return true
        default:
            return false
        }
    }
}

/// Sensible starting parameter for a freshly placed part.
public struct PartDefaults: Sendable {
    public var value: Double
    public var secondaryValue: Double
    /// Closed switch / intact fuse.
    public var isClosed: Bool
    /// Waveform or meter mode index.
    public var modeIndex: Int

    public init(value: Double = 0, secondaryValue: Double = 0, isClosed: Bool = false, modeIndex: Int = 0) {
        self.value = value
        self.secondaryValue = secondaryValue
        self.isClosed = isClosed
        self.modeIndex = modeIndex
    }
}

extension ComponentKind {
    /// Values applied when the part is dropped on the canvas.
    public var partDefaults: PartDefaults {
        switch self {
        case .resistor: return PartDefaults(value: 1_000)
        case .capacitor: return PartDefaults(value: 1e-6)
        case .electrolyticCapacitor: return PartDefaults(value: 100e-6)
        case .trimmerCapacitor: return PartDefaults(value: 100e-12)
        case .inductor: return PartDefaults(value: 1e-3)
        case .dcVoltageSource: return PartDefaults(value: 5)
        case .acVoltageSource: return PartDefaults(value: 5, secondaryValue: 60)
        case .clockSource: return PartDefaults(value: 5, secondaryValue: 1_000)
        case .functionGenerator: return PartDefaults(value: 5, secondaryValue: 1_000)
        case .dcCurrentSource: return PartDefaults(value: 0.01)
        case .potentiometer: return PartDefaults(value: 10_000, secondaryValue: 0.5)
        case .rheostat: return PartDefaults(value: 1_000, secondaryValue: 0.5)
        case .switchSPST: return PartDefaults(isClosed: false)
        case .lamp: return PartDefaults(value: 10)
        case .fuse: return PartDefaults(value: 0.05, secondaryValue: 1.0, isClosed: true)
        case .thermistor: return PartDefaults(value: 10_000, secondaryValue: 25)
        case .photoResistor: return PartDefaults(value: 5_000, secondaryValue: 100)
        case .led: return PartDefaults(value: 2)
        case .zenerDiode: return PartDefaults(secondaryValue: 5.1)
        case .bjtNPN, .bjtPNP: return PartDefaults(secondaryValue: 100)
        case .opAmp: return PartDefaults(secondaryValue: 15)
        case .vcvs: return PartDefaults(value: 2)
        case .vccs: return PartDefaults(value: 0.05)
        case .ammeter: return PartDefaults(value: Self.idealAmmeterR)
        case .voltmeter: return PartDefaults(value: Self.idealVoltmeterR)
        case .galvanometer: return PartDefaults(value: 100, secondaryValue: 1e-3)
        case .ohmmeter: return PartDefaults(value: 1e-3)
        case .wattmeter: return PartDefaults(value: 0.05, secondaryValue: 1e6)
        case .multimeter: return PartDefaults(value: Self.idealVoltmeterR, modeIndex: MeterMode.voltage.rawValue)
        case .threePhaseWye, .threePhaseDelta: return PartDefaults(value: 400, secondaryValue: 50)
        case .vccRail, .vddRail: return PartDefaults(value: 5)
        case .veeRail: return PartDefaults(value: -5)
        case .vssRail: return PartDefaults(value: 0)
        case .amVoltage: return PartDefaults(value: 1, secondaryValue: 500)
        case .fmVoltage: return PartDefaults(value: 1, secondaryValue: 500)
        case .exponentialVoltage: return PartDefaults(value: 5)
        case .pwlVoltage: return PartDefaults()
        case .pulseVoltage: return PartDefaults(value: 5)
        case .bipolarVoltage: return PartDefaults(value: 5, secondaryValue: 1000)
        case .whiteNoiseVoltage: return PartDefaults(value: 1, secondaryValue: 1000)
        case .acCurrentSource: return PartDefaults(value: 0.01, secondaryValue: 1000)
        case .clockCurrentSource: return PartDefaults(value: 0.01, secondaryValue: 1000)
        case .exponentialCurrentSource: return PartDefaults(value: 0.01)
        case .fmCurrentSource: return PartDefaults(value: 0.01, secondaryValue: 500)
        case .pwlCurrentSource: return PartDefaults()
        case .ccvs: return PartDefaults(value: 1000)
        case .cccs: return PartDefaults(value: 10)
        case .vcoSine, .vcoSquare, .vcoTriangle: return PartDefaults(value: 1, secondaryValue: 1000)
        case .gainBlock: return PartDefaults(value: 2)
        case .multiplierBlock: return PartDefaults(value: 1)
        case .dividerBlock: return PartDefaults(value: 1)
        case .summerBlock: return PartDefaults(value: 1)
        case .integratorBlock: return PartDefaults(value: 1000)
        case .differentiatorBlock: return PartDefaults(value: 1e-3)
        case .limiterBlock: return PartDefaults(value: 1)
        case .hysteresisBlock: return PartDefaults()
        case .slewRateBlock: return PartDefaults(value: 1e3)
        case .polynomialBlock: return PartDefaults()
        case .transferFunctionBlock: return PartDefaults()
        case .digitalClock: return PartDefaults(value: 5, secondaryValue: 100)
        case .digitalConstant: return PartDefaults(value: 5, isClosed: true)
        default: return PartDefaults()
        }
    }

    private static let idealAmmeterR = 0.001
    private static let idealVoltmeterR = 1e7
}

extension ComponentKind {
    /// Value shown for the primary parameter field in the inspector.
    public var primaryParameterLabel: String {
        switch self {
        case .resistor, .rheostat, .lamp, .galvanometer: return "Resistance (Ω):"
        case .potentiometer: return "Total Track Resistance (Ω):"
        case .fuse: return "On-State Resistance (Ω):"
        case .thermistor: return "Resistance at 25°C (Ω):"
        case .photoResistor: return "Resistance at 10 lux (Ω):"
        case .ammeter: return "Burden Resistance (Ω):"
        case .voltmeter, .multimeter: return "Input Resistance (Ω):"
        case .wattmeter: return "Current-Coil Resistance (Ω):"
        case .ohmmeter: return "Test Current (A):"
        case .capacitor, .electrolyticCapacitor, .trimmerCapacitor: return "Capacitance (F):"
        case .inductor: return "Inductance (H):"
        case .dcVoltageSource: return "Voltage (V):"
        case .acVoltageSource: return "Peak Amplitude (V):"
        case .clockSource: return "Amplitude (V):"
        case .functionGenerator: return "Amplitude (Vp):"
        case .dcCurrentSource: return "Current (A):"
        case .vcvs: return "Voltage Gain (μ):"
        case .vccs: return "Transconductance gm (S):"
        case .zenerDiode: return "Forward Drop Model (V):"
        case .threePhaseWye, .threePhaseDelta: return "Line Voltage (V RMS):"
        case .vccRail, .vddRail, .veeRail, .vssRail: return "Rail Voltage (V):"
        case .amVoltage: return "Carrier Amplitude (Vp):"
        case .fmVoltage: return "Amplitude (Vp):"
        case .exponentialVoltage: return "Pulsed Value V2 (V):"
        case .pwlVoltage: return "Value:"
        case .pulseVoltage: return "Pulsed Value V2 (V):"
        case .bipolarVoltage: return "Amplitude ±V (V):"
        case .whiteNoiseVoltage: return "Noise RMS Voltage (V):"
        case .acCurrentSource: return "Peak Current (A):"
        case .clockCurrentSource: return "Pulse Current (A):"
        case .exponentialCurrentSource: return "Pulsed Value I2 (A):"
        case .fmCurrentSource: return "Amplitude (A peak):"
        case .pwlCurrentSource: return "Value:"
        case .ccvs: return "Transresistance r (V/A):"
        case .cccs: return "Current Gain β (A/A):"
        case .vcoSine, .vcoSquare, .vcoTriangle: return "Output Amplitude (Vp):"
        case .gainBlock: return "Gain K:"
        case .multiplierBlock: return "Output Gain K:"
        case .dividerBlock: return "Output Gain K:"
        case .summerBlock: return "Output Gain K:"
        case .integratorBlock: return "Integrator Gain K (1/s):"
        case .differentiatorBlock: return "Differentiator Gain K (s):"
        case .limiterBlock: return "Gain K:"
        case .hysteresisBlock: return "Value:"
        case .slewRateBlock: return "Rising Slew Rate (V/s):"
        case .polynomialBlock: return "Value:"
        case .transferFunctionBlock: return "Value:"
        case .digitalClock: return "Logic High Level (V):"
        case .digitalConstant: return "Logic High Level (V):"
        default: return "Value:"
        }
    }

    public var secondaryParameterLabel: String? {
        switch self {
        case .acVoltageSource, .clockSource, .functionGenerator: return "Frequency (Hz):"
        case .potentiometer, .rheostat: return "Wiper / Setting (0–1):"
        case .fuse: return "Rated Current (A):"
        case .thermistor: return "Temperature (°C):"
        case .photoResistor: return "Illuminance (lux):"
        case .galvanometer: return "Full-Scale Current (A):"
        case .wattmeter: return "Pressure-Coil Resistance (Ω):"
        case .zenerDiode: return "Zener Breakdown (V):"
        case .bjtNPN, .bjtPNP: return "Current Gain (β / hFE):"
        case .digitalClock: return "Clock Frequency (Hz):"
        case .vcoSine, .vcoSquare, .vcoTriangle: return "Frequency at 0 V Control (Hz):"
        case .fmCurrentSource: return "Carrier Frequency (Hz):"
        case .clockCurrentSource: return "Frequency (Hz):"
        case .acCurrentSource: return "Frequency (Hz):"
        case .whiteNoiseVoltage: return "Bandwidth (Hz):"
        case .bipolarVoltage: return "Frequency (Hz):"
        case .fmVoltage: return "Carrier Frequency (Hz):"
        case .amVoltage: return "Carrier Frequency (Hz):"
        case .threePhaseWye, .threePhaseDelta: return "Frequency (Hz):"
        default: return nil
        }
    }
}

/// Represents the physical or logical pin of a component.
public struct Pin: Identifiable, Codable, Equatable, Hashable {
    public let id: UUID
    public let index: Int
    public let name: String
    /// Relative offset from component center on the schematic canvas (in grid units).
    public var relativeX: Double
    public var relativeY: Double

    public init(id: UUID = UUID(), index: Int, name: String, relativeX: Double, relativeY: Double) {
        self.id = id
        self.index = index
        self.name = name
        self.relativeX = relativeX
        self.relativeY = relativeY
    }
}

/// Standard color for LEDs.
public enum LEDColor: String, Codable, CaseIterable {
    case red, green, blue, yellow, white

    public var forwardVoltage: Double {
        switch self {
        case .red: return 1.8
        case .yellow: return 2.1
        case .green: return 2.2
        case .blue: return 3.2
        case .white: return 3.3
        }
    }
}

/// Waveform selected on the function generator (`CircuitComponent.modeIndex`).
public enum GeneratorWaveform: Int, CaseIterable, Sendable {
    case sine = 0
    case square = 1
    case triangle = 2

    public var label: String {
        switch self {
        case .sine: return "Sine"
        case .square: return "Square"
        case .triangle: return "Triangle"
        }
    }
}

/// Measurement mode selected on the multimeter (`CircuitComponent.modeIndex`).
public enum MeterMode: Int, CaseIterable, Sendable {
    case voltage = 0
    case current = 1
    case resistance = 2

    public var label: String {
        switch self {
        case .voltage: return "V (parallel)"
        case .current: return "A (series)"
        case .resistance: return "Ω (ohmmeter)"
        }
    }
}
