#if canImport(UIKit)
import SwiftUI
import UIKit

public extension PrivacyColor {
    var swiftUIColor: Color { Color(red: red, green: green, blue: blue) }
}

public struct PrivacyCoverView: View {
    @Environment(\.displayScale) private var displayScale
    private let data: Data?
    private let size: CGFloat

    public init(data: Data?, size: CGFloat = 24) {
        self.data = data
        self.size = size
    }

    public var body: some View {
        Group {
            if let data, data.count <= 1200, let image = UIImage(data: data, scale: max(1, displayScale)) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.12), Color(white: 0.28), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Capsule().fill(.white.opacity(0.13))
                        .frame(width: size * 1.3, height: size * 0.16).rotationEffect(.degrees(-35))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
        .accessibilityHidden(true)
    }
}

public struct PrivacyWaveformView: View {
    private let state: PrivacyActivityState
    private let stale: Bool
    private let height: CGFloat
    private let coverHeight: CGFloat?
    private let presentation: PrivacyMeterPresentation

    public init(state: PrivacyActivityState, stale: Bool, height: CGFloat = 16, presentation: PrivacyMeterPresentation = .standard, coverHeight: CGFloat? = nil) {
        self.coverHeight = coverHeight
        self.state = state
        self.stale = stale
        self.height = height
        self.presentation = presentation
    }

    public var body: some View {
        Group {
            if !stale, state.measuredAt != nil, state.curveReadings != nil,
               let style = PrivacyMeterStyle(rawValue: state.meterStyle ?? ""), style.isCurve {
                let anchor = coverHeight ?? max(0, height - 4)
                let plotHeight = coverHeight.map { $0 + (presentation == .compact ? 2 : 6) } ?? height
                PrivacyCurveView(state: state, dual: style == .rangeCurve, height: plotHeight,
                                 coverHeight: anchor, presentation: presentation)
                    .frame(height: coverHeight ?? height)
            } else {
                meter
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(stale ? "Reading overdue" : "Private activity", bundle: .module))
    }

    private var meter: some View {
        GeometryReader { proxy in
            let geometry = PrivacyMeterGeometry(heights: state.waveformHeights,
                availableWidth: proxy.size.width, height: proxy.size.height, presentation: presentation)
            ZStack(alignment: .topLeading) {
                if stale || state.measuredAt == nil {
                    let ring = geometry.ring
                    Circle().strokeBorder(state.color.swiftUIColor, lineWidth: 1.5)
                        .frame(width: ring.width, height: ring.height).offset(x: ring.x, y: ring.y)
                } else {
                    ForEach(geometry.bars.indices, id: \.self) { index in
                        let frame = geometry.bars[index]
                        let heights = state.waveformHeights
                        let missing = !heights.indices.contains(index) || heights[index] == nil
                        Capsule().fill(missing ? Color.secondary.opacity(0.25) : state.color.swiftUIColor)
                            .frame(width: frame.width, height: frame.height).offset(x: frame.x, y: frame.y)
                    }
                }
            }
            .frame(width: geometry.width, height: geometry.height, alignment: .topLeading)
        }
        .frame(idealWidth: presentation.preferredWidth, maxWidth: presentation.preferredWidth)
        .frame(height: height)
    }
}

private struct PrivacyCurveView: View {
    let state: PrivacyActivityState
    let dual: Bool
    let height: CGFloat
    let coverHeight: CGFloat
    let presentation: PrivacyMeterPresentation

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let geometry = PrivacyCurveGeometry(values: state.effectiveCurveReadings,
                width: max(0, size.width - 6), height: size.height, coverHeight: coverHeight,
                references: state.curveReferences ?? .init(), dual: dual)
            ZStack {
                Path { path in
                    func point(_ p: PrivacyCurveGeometry.Point) -> CGPoint { CGPoint(x: p.x + 3, y: p.y) }
                    for segment in geometry.segments {
                        path.move(to: point(segment.start))
                        path.addCurve(to: point(segment.end), control1: point(segment.control1), control2: point(segment.control2))
                    }
                    for p in geometry.isolatedPoints {
                        path.move(to: point(p))
                        path.addLine(to: CGPoint(x: p.x + 3.1, y: p.y))
                    }
                }.stroke(state.color.swiftUIColor, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                Path { path in
                    for y in geometry.referenceY {
                        path.move(to: CGPoint(x: 1, y: y))
                        path.addLine(to: CGPoint(x: size.width - 1, y: y))
                    }
                }.stroke(Color(white: 0.45), lineWidth: 1)
            }
        }
        .frame(idealWidth: presentation.preferredWidth, maxWidth: presentation.preferredWidth)
        .frame(height: height)
    }
}
#endif
