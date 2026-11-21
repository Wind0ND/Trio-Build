import Foundation

// Interface scaffold for the regression-first run. Actual geometry follows observed RED.
public struct PrivacyCurveReferences: Codable, Hashable, Sendable {
    public let lower: Double
    public let upper: Double
    public let single: Double
    public init(lower: Double = 4, upper: Double = 10, single: Double = 5) {
        self.lower = lower; self.upper = upper; self.single = single
    }
}

public struct PrivacyCurveGeometry: Sendable {
    public struct Point: Sendable { public let x: Double; public let y: Double }
    public struct Segment: Sendable {
        public let start: Point; public let control1: Point; public let control2: Point; public let end: Point
    }
    public let referenceY: [Double] = []
    public let segments: [Segment] = []
    public init(values: [Double?], width: Double, height: Double, references: PrivacyCurveReferences, dual: Bool) {}
}
