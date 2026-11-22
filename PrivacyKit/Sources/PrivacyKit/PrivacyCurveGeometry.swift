import Foundation

/// Display references only; these never change clinical alarm thresholds.
public struct PrivacyCurveReferences: Codable, Hashable, Sendable {
    public let lower: Double
    public let upper: Double
    public let single: Double
    public init(lower: Double = 4, upper: Double = 10, single: Double = 5) {
        let pairValid = lower.isFinite && upper.isFinite && (1 ... 30).contains(lower)
            && (1 ... 30).contains(upper) && upper - lower >= 0.099
        self.lower = pairValid ? lower : 4
        self.upper = pairValid ? upper : 10
        self.single = single.isFinite && (1 ... 30).contains(single) ? single : 5
    }

    private enum CodingKeys: String, CodingKey { case lower, upper, single }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(lower: (try? c.decode(Double.self, forKey: .lower)) ?? 4,
                  upper: (try? c.decode(Double.self, forKey: .upper)) ?? 10,
                  single: (try? c.decode(Double.self, forKey: .single)) ?? 5)
    }
    public static let preferenceKey = "privacy.curve.references"
    public static func stored(in defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: preferenceKey),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return value
    }

}

public struct PrivacyCurveGeometry: Sendable {
    public struct Point: Sendable { public let x: Double; public let y: Double }
    public struct Segment: Sendable {
        public let start: Point; public let control1: Point; public let control2: Point; public let end: Point
    }
    public let referenceY: [Double]
    public let segments: [Segment]
    public let isolatedPoints: [Point]
    public init(values: [Double?], width: Double, height: Double, coverHeight: Double = 12, references: PrivacyCurveReferences, dual: Bool) {
        let w = width.isFinite ? max(0, width) : 22
        let h = height.isFinite ? max(0, height) : 16
        let span = min(h, coverHeight.isFinite ? max(0, coverHeight) : 12)
        let middle = h / 2
        let lowerY = middle + span / 2
        let upperY = middle - span / 2
        referenceY = dual ? [lowerY, upperY] : [middle]
        func y(_ value: Double) -> Double {
            let position = dual
                ? lowerY - (value - references.lower) * span / (references.upper - references.lower)
                : middle - (value - references.single) * h / 12
            return min(h, max(0, position))
        }
        let points: [Point?] = values.enumerated().map { index, value in
            guard let value, value.isFinite, value > 0 else { return nil }
            return Point(x: values.count < 2 ? w / 2 : Double(index) * w / Double(values.count - 1), y: y(value))
        }
        var result: [Segment] = []
        var isolated: [Point] = []
        for index in points.indices {
            guard let start = points[index] else { continue }
            let previous = index > 0 ? points[index - 1] : nil
            let next = index + 1 < points.count ? points[index + 1] : nil
            if previous == nil && next == nil { isolated.append(start) }
            guard let end = next, end.x > start.x else { continue }
            let delta = (end.y - start.y) / (end.x - start.x)
            func tangent(_ neighbor: Point?, at point: Point, fallback: Double) -> Double {
                guard let neighbor, point.x != neighbor.x else { return fallback }
                let adjacent = (point.y - neighbor.y) / (point.x - neighbor.x)
                return adjacent * fallback > 0 ? 2 / (1 / adjacent + 1 / fallback) : 0
            }
            let following = index + 2 < points.count ? points[index + 2] : nil
            let dx = (end.x - start.x) / 3
            let bounds = min(start.y, end.y) ... max(start.y, end.y)
            func bounded(_ v: Double) -> Double { min(bounds.upperBound, max(bounds.lowerBound, v)) }
            result.append(Segment(start: start,
                control1: Point(x: start.x + dx, y: bounded(start.y + tangent(previous, at: start, fallback: delta) * dx)),
                control2: Point(x: end.x - dx, y: bounded(end.y - tangent(following, at: end, fallback: delta) * dx)), end: end))
        }
        segments = result
        isolatedPoints = isolated
    }
}
