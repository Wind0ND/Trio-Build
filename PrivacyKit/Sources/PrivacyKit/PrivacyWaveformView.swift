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

    public init(state: PrivacyActivityState, stale: Bool, height: CGFloat = 16) {
        self.state = state
        self.stale = stale
        self.height = height
    }

    public var body: some View {
        Group {
            if stale || state.measuredAt == nil {
                Circle().strokeBorder(lineWidth: 1.5).frame(width: 11, height: 11)
            } else {
                HStack(alignment: .center, spacing: 1.8) {
                    ForEach(0 ..< 6, id: \.self) { index in
                        let value = state.heights.indices.contains(index) ? state.heights[index] : nil
                        Capsule()
                            .fill(value == nil ? Color.secondary.opacity(0.25) : state.color.swiftUIColor)
                            .frame(width: index == 5 ? 2 : 1.6, height: max(2, height * CGFloat(value ?? 0.12)))
                    }
                }
            }
        }
        .foregroundStyle(state.color.swiftUIColor)
        .frame(width: 22, height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(stale ? "Reading overdue" : "Private activity", bundle: .module))
    }
}
#endif
