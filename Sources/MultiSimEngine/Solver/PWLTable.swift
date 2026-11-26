import Foundation

/// A piecewise-linear waveform: (time, value) corners joined by straight lines.
public struct PWLTable: Sendable, Equatable {
    public let points: [(t: Double, v: Double)]

    public static func == (a: PWLTable, b: PWLTable) -> Bool {
        a.points.count == b.points.count && zip(a.points, b.points).allSatisfy { $0.t == $1.t && $0.v == $1.v }
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case oddCount
        case badNumber(String)
        case timeGoesBack(Double)

        public var description: String {
            switch self {
            case .empty: return "Enter at least one \"time value\" pair."
            case .oddCount: return "Every time needs a value: the list must hold pairs."
            case .badNumber(let s): return "\"\(s)\" is not a number (use 1m, 2.5u, 10k ...)."
            case .timeGoesBack(let t): return "Times must not go backwards (at \(EngineeringUnitParser.format(t)) s)."
            }
        }
    }

    /// Parses "t v" pairs separated by spaces, commas, semicolons or new lines. Engineering suffixes allowed.
    public static func parse(_ text: String) -> Result<PWLTable, ParseError> {
        let tokens = text.split(whereSeparator: { " ,;\n\t\r()".contains($0) }).map(String.init)
        guard !tokens.isEmpty else { return .failure(.empty) }
        guard tokens.count % 2 == 0 else { return .failure(.oddCount) }
        var pts: [(t: Double, v: Double)] = []
        for i in stride(from: 0, to: tokens.count, by: 2) {
            guard let t = EngineeringUnitParser.parse(tokens[i], unit: "s") else { return .failure(.badNumber(tokens[i])) }
            guard let v = EngineeringUnitParser.parse(tokens[i + 1]) else { return .failure(.badNumber(tokens[i + 1])) }
            if let last = pts.last, t < last.t { return .failure(.timeGoesBack(t)) }
            pts.append((t, v))
        }
        return .success(PWLTable(points: pts))
    }

    /// Value at time t: held before the first and after the last corner.
    public func value(at t: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if t <= first.t { return first.v }
        if t >= last.t { return last.v }
        // Binary search for the segment.
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        return b.t > a.t ? a.v + (b.v - a.v) * (t - a.t) / (b.t - a.t) : b.v
    }

    /// Next corner strictly after t.
    public func nextCorner(after t: Double) -> Double? {
        points.first { $0.t > t + max(abs(t) * 1e-12, 1e-15) }?.t
    }

    public var duration: Double { points.last?.t ?? 0 }
}

/// Parsed PWL tables keyed by their text, so the solver does not re-parse every Newton iteration.
public final class PWLCache: @unchecked Sendable {
    public static let shared = PWLCache()
    private var tables: [String: PWLTable] = [:]
    private let lock = NSLock()

    public func table(for text: String) -> PWLTable? {
        lock.lock()
        defer { lock.unlock() }
        if let t = tables[text] { return t }
        guard case .success(let t) = PWLTable.parse(text) else { return nil }
        if tables.count > 256 { tables.removeAll() }
        tables[text] = t
        return t
    }
}
