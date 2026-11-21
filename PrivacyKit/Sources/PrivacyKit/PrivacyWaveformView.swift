#if canImport(UIKit)
import SwiftUI
import UIKit

public extension PrivacyColor {
    var swiftUIColor: Color { Color(red: red, green: green, blue: blue) }
}

public struct PrivacyCoverView: View {
    private let data: Data?
    private let size: CGFloat

    public init(data: Data?, size: CGFloat = 24) {
        self.data = data
        self.size = size
    }

    public var body: some View {
        Group {
            if let data, data.count <= 1200, let image = UIImage(data: data) {
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
    private let presentation: PrivacyMeterPresentation

    public init(state: PrivacyActivityState, stale: Bool, height: CGFloat = 16, presentation: PrivacyMeterPresentation = .standard) {
        self.state = state
        self.stale = stale
        self.height = height
        self.presentation = presentation
    }

    public var body: some View {
        Group {
        if !stale, state.measuredAt != nil, state.curveReadings != nil,
           let style = PrivacyMeterStyle(rawValue: state.meterStyle ?? ""), style.isCurve {
            PrivacyCurveView(state: state, dual: style == .rangeCurve, height: height, presentation: presentation)
        } else {
        PrivacyMeterLayout(heights: state.waveformHeights, height: height, presentation: presentation) {
            if stale || state.measuredAt == nil {
                Circle().strokeBorder(lineWidth: 1.5)
            } else {
                ForEach(0 ..< 6, id: \.self) { index in
                    let value = state.waveformHeights.indices.contains(index) ? state.waveformHeights[index] : nil
                    Capsule().fill(value == nil ? Color.secondary.opacity(0.25) : state.color.swiftUIColor)
                }
            }
        }
        .foregroundStyle(state.color.swiftUIColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(stale ? "Reading overdue" : "Private activity", bundle: .module))
        }
        }
    }
}

private struct PrivacyCurveView: View {
    let state: PrivacyActivityState
    let dual: Bool
    let height: CGFloat
    let presentation: PrivacyMeterPresentation

    var body: some View {
        Canvas { context, size in
            let geometry = PrivacyCurveGeometry(values: state.effectiveCurveReadings,
                width: max(0, size.width - 2), height: max(0, size.height - 2),
                references: state.curveReferences ?? .init(), dual: dual)
            func point(_ p: PrivacyCurveGeometry.Point) -> CGPoint { CGPoint(x: p.x + 1, y: p.y + 1) }
            for y in geometry.referenceY {
                var path = Path()
                path.move(to: CGPoint(x: 1, y: y + 1))
                path.addLine(to: CGPoint(x: size.width - 1, y: y + 1))
                context.stroke(path, with: .color(Color(white: 0.32)), lineWidth: 0.5)
            }
            var curve = Path()
            for segment in geometry.segments {
                curve.move(to: point(segment.start))
                curve.addCurve(to: point(segment.end), control1: point(segment.control1), control2: point(segment.control2))
            }
            for p in geometry.isolatedPoints {
                curve.move(to: point(p))
                curve.addLine(to: CGPoint(x: p.x + 1.1, y: p.y + 1))
            }
            context.stroke(curve, with: .color(state.color.swiftUIColor),
                           style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
        }
        .frame(width: presentation.preferredWidth, height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Private activity", bundle: .module))
    }
}

/// Uses the actual proposed region instead of allowing a fixed-width HStack to be cropped.
private struct PrivacyMeterLayout: Layout {
    let heights: [Double?]
    let height: CGFloat
    let presentation: PrivacyMeterPresentation

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let geometry = geometry(width: proposal.width, proposedHeight: proposal.height)
        return CGSize(width: geometry.width, height: geometry.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let geometry = geometry(width: bounds.width, proposedHeight: bounds.height)
        let frames = subviews.count == 1 ? [geometry.ring] : geometry.bars
        let offset = CGPoint(x: bounds.midX - geometry.width / 2, y: bounds.midY - geometry.height / 2)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: offset.x + frame.x, y: offset.y + frame.y), anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func geometry(width: CGFloat?, proposedHeight: CGFloat?) -> PrivacyMeterGeometry {
        PrivacyMeterGeometry(
            heights: heights, availableWidth: Double(width ?? presentation.preferredWidth),
            height: Double(min(height, proposedHeight ?? height)), presentation: presentation
        )
    }
}
#endif
