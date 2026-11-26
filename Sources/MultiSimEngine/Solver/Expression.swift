import Foundation

/// A small, safe arithmetic language for behavioural (ABM) sources.
///
/// Grammar (no code is ever evaluated, only this tree):
///
///     expr    := term (('+' | '-') term)*
///     term    := unary (('*' | '/') unary)*
///     unary   := ('-' | '+') unary | power
///     power   := primary ('^' unary)?
///     primary := number | time | t | pi | func '(' args ')' | V '(' ref [',' ref] ')' | I '(' ref ')' | '(' expr ')'
///
/// Numbers accept engineering suffixes (1k, 2.2u, 10MEG). `ref` is a node number or a part designator:
/// V(3) is node 3, V(R1) the voltage across R1 (pin 0 minus pin 1), V(a, b) a difference, I(R1) the current through R1.
public indirect enum Expression: Equatable, Sendable {
    case number(Double)
    case time
    /// Index into the expression's reference list.
    case reference(Int)
    case negate(Expression)
    case binary(Character, Expression, Expression)
    case call(String, [Expression])

    /// Something the expression reads from the circuit.
    public indirect enum Reference: Equatable, Hashable, Sendable {
        case nodeVoltage(Int)
        case partVoltage(String)
        case difference(Reference, Reference)
        case partCurrent(String)
    }

    public struct Parsed: Equatable, Sendable {
        public let root: Expression
        public let references: [Reference]
        public var usesTime: Bool { root.contains { if case .time = $0 { return true }; return false } }
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case unexpected(String)
        case unknownFunction(String)
        case wrongArgumentCount(String)
        case badReference(String)

        public var description: String {
            switch self {
            case .empty: return "Enter an expression, e.g. 2*V(1) + sin(2*pi*50*time)."
            case .unexpected(let s): return "Unexpected \"\(s)\"."
            case .unknownFunction(let s): return "Unknown function \"\(s)\" (use sin cos tan exp log log10 abs sqrt min max)."
            case .wrongArgumentCount(let s): return "Wrong number of arguments for \(s)()."
            case .badReference(let s): return "\"\(s)\" is not a node number or part name."
            }
        }
    }

    static let functions: [String: ClosedRange<Int>] = [
        "sin": 1...1, "cos": 1...1, "tan": 1...1, "exp": 1...1, "log": 1...1, "ln": 1...1, "log10": 1...1,
        "abs": 1...1, "sqrt": 1...1, "atan": 1...1, "tanh": 1...1, "min": 2...2, "max": 2...2, "pow": 2...2,
        "limit": 3...3, "sgn": 1...1,
    ]

    // MARK: Evaluation

    /// Evaluates with reference values `refs` at time `t`. Domain errors are kept finite (log of ≤0, sqrt of <0,
    /// division by ~0) so a Newton iterate passing through them cannot poison the solve.
    public func evaluate(refs: [Double], time t: Double) -> Double {
        switch self {
        case .number(let v): return v
        case .time: return t
        case .reference(let i): return i < refs.count ? refs[i] : 0
        case .negate(let e): return -e.evaluate(refs: refs, time: t)
        case .binary(let op, let a, let b):
            let x = a.evaluate(refs: refs, time: t), y = b.evaluate(refs: refs, time: t)
            switch op {
            case "+": return x + y
            case "-": return x - y
            case "*": return x * y
            case "/":
                let d = abs(y) < 1e-30 ? (y < 0 ? -1e-30 : 1e-30) : y
                return Self.finite(x / d)
            default: return Self.finite(pow(x, y))
            }
        case .call(let name, let args):
            let v = args.map { $0.evaluate(refs: refs, time: t) }
            switch name {
            case "sin": return sin(v[0])
            case "cos": return cos(v[0])
            case "tan": return Self.finite(tan(v[0]))
            case "atan": return atan(v[0])
            case "tanh": return tanh(v[0])
            case "exp": return exp(min(v[0], 700))
            case "log", "ln": return Foundation.log(max(v[0], 1e-300))
            case "log10": return log10(max(v[0], 1e-300))
            case "abs": return abs(v[0])
            case "sqrt": return max(v[0], 0).squareRoot()
            case "sgn": return v[0] > 0 ? 1 : (v[0] < 0 ? -1 : 0)
            case "min": return min(v[0], v[1])
            case "max": return max(v[0], v[1])
            case "pow": return Self.finite(pow(v[0], v[1]))
            case "limit": return min(max(v[0], min(v[1], v[2])), max(v[1], v[2]))
            default: return 0
            }
        }
    }

    private static func finite(_ v: Double) -> Double {
        if v.isNaN { return 0 }
        if v == .infinity { return 1e300 }
        if v == -.infinity { return -1e300 }
        return v
    }

    func contains(_ test: (Expression) -> Bool) -> Bool {
        if test(self) { return true }
        switch self {
        case .negate(let e): return e.contains(test)
        case .binary(_, let a, let b): return a.contains(test) || b.contains(test)
        case .call(_, let args): return args.contains { $0.contains(test) }
        default: return false
        }
    }

    // MARK: Parsing

    public static func parse(_ text: String) -> Result<Parsed, ParseError> {
        var p = ExpressionParser(text)
        do {
            guard !p.atEnd else { throw ParseError.empty }
            let root = try p.expression()
            guard p.atEnd else { throw ParseError.unexpected(p.peekText) }
            return .success(Parsed(root: root, references: p.references))
        } catch let e as ParseError {
            return .failure(e)
        } catch {
            return .failure(.unexpected(text))
        }
    }
}

private struct ExpressionParser {
    enum Token: Equatable {
        case number(Double)
        case ident(String)
        case op(Character)
    }

    private var tokens: [Token] = []
    private var raw: [String] = []
    private var pos = 0
    private(set) var references: [Expression.Reference] = []
    private var lexError: String?

    init(_ text: String) {
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                if j < chars.count, chars[j] == "e" || chars[j] == "E",
                   j + 1 < chars.count, chars[j + 1].isNumber || ((chars[j + 1] == "-" || chars[j + 1] == "+") && j + 2 < chars.count && chars[j + 2].isNumber) {
                    j += 2
                    while j < chars.count, chars[j].isNumber { j += 1 }
                }
                // Engineering suffix glued to the number (1k, 4.7u, 10MEG).
                while j < chars.count, chars[j].isLetter { j += 1 }
                let s = String(chars[i..<j])
                if let v = EngineeringUnitParser.parse(s) { tokens.append(.number(v)) } else { lexError = lexError ?? s }
                raw.append(s)
                i = j
                continue
            }
            if c.isLetter || c == "_" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "." { j += 1 }
                let s = String(chars[i..<j])
                tokens.append(.ident(s))
                raw.append(s)
                i = j
                continue
            }
            if "+-*/^(),".contains(c) {
                tokens.append(.op(c))
                raw.append(String(c))
                i += 1
                continue
            }
            lexError = lexError ?? String(c)
            i += 1
        }
    }

    var atEnd: Bool { pos >= tokens.count && lexError == nil }
    var peekText: String { lexError ?? (pos < raw.count ? raw[pos] : "end") }

    private func peek() -> Token? { pos < tokens.count ? tokens[pos] : nil }

    private mutating func expect(_ c: Character) throws {
        guard peek() == .op(c) else { throw Expression.ParseError.unexpected(peekText) }
        pos += 1
    }

    mutating func expression() throws -> Expression {
        if let e = lexError { throw Expression.ParseError.unexpected(e) }
        var lhs = try term()
        while let t = peek(), t == .op("+") || t == .op("-") {
            pos += 1
            guard case .op(let c) = t else { break }
            lhs = .binary(c, lhs, try term())
        }
        return lhs
    }

    private mutating func term() throws -> Expression {
        var lhs = try unary()
        while let t = peek(), t == .op("*") || t == .op("/") {
            pos += 1
            guard case .op(let c) = t else { break }
            lhs = .binary(c, lhs, try unary())
        }
        return lhs
    }

    private mutating func unary() throws -> Expression {
        if peek() == .op("-") { pos += 1; return .negate(try unary()) }
        if peek() == .op("+") { pos += 1; return try unary() }
        let base = try primary()
        if peek() == .op("^") {
            pos += 1
            return .binary("^", base, try unary())
        }
        return base
    }

    private mutating func reference(_ r: Expression.Reference) -> Expression {
        if let i = references.firstIndex(of: r) { return .reference(i) }
        references.append(r)
        return .reference(references.count - 1)
    }

    private mutating func refArgument() throws -> Expression.Reference {
        guard let t = peek() else { throw Expression.ParseError.unexpected("end") }
        pos += 1
        switch t {
        case .number(let v) where v >= 0 && v == v.rounded():
            return .nodeVoltage(Int(v))
        case .ident(let name):
            return .partVoltage(name)
        default:
            throw Expression.ParseError.badReference(raw[pos - 1])
        }
    }

    private mutating func primary() throws -> Expression {
        guard let t = peek() else { throw Expression.ParseError.unexpected("end") }
        switch t {
        case .number(let v):
            pos += 1
            return .number(v)
        case .op("("):
            pos += 1
            let e = try expression()
            try expect(")")
            return e
        case .ident(let rawName):
            pos += 1
            let name = rawName.lowercased()
            if peek() != .op("(") {
                switch name {
                case "time", "t": return .time
                case "pi": return .number(.pi)
                default: throw Expression.ParseError.unexpected(rawName)
                }
            }
            pos += 1 // (
            if name == "v" {
                let a = try refArgument()
                if peek() == .op(",") {
                    pos += 1
                    let b = try refArgument()
                    try expect(")")
                    return reference(.difference(nodeOf(a), nodeOf(b)))
                }
                try expect(")")
                return reference(a)
            }
            if name == "i" {
                guard case .ident(let part)? = peek() else { throw Expression.ParseError.badReference(peekText) }
                pos += 1
                try expect(")")
                return reference(.partCurrent(part))
            }
            guard let arity = Expression.functions[name] else { throw Expression.ParseError.unknownFunction(rawName) }
            var args: [Expression] = []
            if peek() != .op(")") {
                args.append(try expression())
                while peek() == .op(",") {
                    pos += 1
                    args.append(try expression())
                }
            }
            try expect(")")
            guard arity.contains(args.count) else { throw Expression.ParseError.wrongArgumentCount(rawName) }
            return .call(name, args)
        default:
            throw Expression.ParseError.unexpected(peekText)
        }
    }

    /// In V(a, b) a part name stands for the node on its first pin.
    private func nodeOf(_ r: Expression.Reference) -> Expression.Reference {
        if case .partVoltage(let name) = r { return .partVoltage(name + ".0") }
        return r
    }
}

/// Parsed expressions keyed by their text.
public final class ExpressionCache: @unchecked Sendable {
    public static let shared = ExpressionCache()
    private var parsed: [String: Expression.Parsed] = [:]
    private let lock = NSLock()

    public func expression(for text: String) -> Expression.Parsed? {
        lock.lock()
        defer { lock.unlock() }
        if let e = parsed[text] { return e }
        guard case .success(let e) = Expression.parse(text) else { return nil }
        if parsed.count > 256 { parsed.removeAll() }
        parsed[text] = e
        return e
    }
}
