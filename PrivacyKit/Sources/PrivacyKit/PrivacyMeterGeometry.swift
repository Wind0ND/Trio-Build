import Foundation

public enum PrivacyMeterPresentation: Sendable {
    case standard, compact, minimal

    var preferredWidth: Double {
        switch self {
        case .standard: return 22
        case .compact: return 20
        case .minimal: return 14
        }
    }
}

/// Bounds for the display only. Sample values, chronology and freshness are never changed here.
public struct PrivacyMeterGeometry: Sendable {
    public struct Frame: Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
    }

    public let width: Double
    public let height: Double
    public let bars: [Frame]
    public let ring: Frame

    public init(heights: [Double?], availableWidth: Double, height: Double, presentation: PrivacyMeterPresentation) {
        let width = availableWidth.isFinite ? max(0, min(presentation.preferredWidth, availableWidth)) : presentation.preferredWidth
        let height = height.isFinite ? max(0, height) : 16
        self.width = width
        self.height = height

        let minimal = presentation == .minimal
        let inset = min(width / 2, minimal ? 0.75 : (presentation == .compact ? 1 : 1.5))
        let ordinaryWidth = minimal ? 1.2 : 1.6
        let latestWidth = minimal ? 1.4 : 2.0
        let gap = minimal ? 1.0 : 1.8
        let naturalWidth = ordinaryWidth * 5 + latestWidth + gap * 5
        let scale = min(1, max(0, width - inset * 2) / naturalWidth)
        var cursor = (width - naturalWidth * scale) / 2
        bars = (0 ..< 6).map { index in
            let barWidth = (index == 5 ? latestWidth : ordinaryWidth) * scale
            let value = heights.indices.contains(index) ? heights[index] : nil
            let fraction = value.flatMap { $0.isFinite ? min(1, max(0.12, $0)) : nil } ?? 0.12
            let barHeight = min(height, max(min(2, height), height * fraction))
            let frame = Frame(x: cursor, y: (height - barHeight) / 2, width: barWidth, height: barHeight)
            cursor += barWidth + gap * scale
            return frame
        }
        let diameter = min(11, width, height)
        ring = Frame(x: (width - diameter) / 2, y: (height - diameter) / 2, width: diameter, height: diameter)
    }
}
