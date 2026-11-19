#if canImport(UIKit)
import SwiftUI
import PrivacyKit

struct PrivacySecretInput: View {
    let method: PrivacyLockMethod
    @Binding var value: String
    let onComplete: (String) -> Void

    var body: some View {
        if method == .pin {
            VStack(spacing: 20) {
                HStack(spacing: 16) {
                    ForEach(0 ..< 4, id: \.self) { index in
                        Circle().fill(index < value.count ? Color.primary : .clear)
                            .overlay(Circle().stroke(Color.primary, lineWidth: 1))
                            .frame(width: 12, height: 12)
                    }
                }
                .accessibilityLabel(Text(privacyText("PIN entry")))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(64)), count: 3), spacing: 12) {
                    ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "delete"], id: \.self) { digit in
                        if digit.isEmpty {
                            Color.clear.frame(width: 64, height: 48)
                        } else {
                            Button {
                                if digit == "delete" {
                                    if !value.isEmpty { value.removeLast() }
                                } else if value.count < 4 {
                                    value += digit
                                    if value.count == 4 { onComplete(value) }
                                }
                            } label: {
                                Group {
                                    if digit == "delete" { Image(systemName: "delete.left") }
                                    else { Text(verbatim: digit).font(.title2) }
                                }
                                .frame(width: 64, height: 48)
                                .background(.primary.opacity(0.08), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(digit == "delete" ? privacyText("Delete") : digit))
                        }
                    }
                }
            }
        } else {
            PrivacyPatternInput(value: $value, onComplete: onComplete)
        }
    }
}

private struct PrivacyPatternInput: View {
    @AppStorage(PrivacyPreference.patternTraceKey) private var showTrace = false
    @Environment(\.scenePhase) private var scenePhase
    @Binding var value: String
    let onComplete: (String) -> Void
    @State private var selected: [Int] = []
    @State private var drawing = false
    @State private var finger: CGPoint?

    private func point(_ index: Int, in size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(index % 3) * size.width / 3 + size.width / 6,
                y: CGFloat(index / 3) * size.height / 3 + size.height / 6)
    }

    private func add(_ index: Int) {
        guard !selected.contains(index) else { return }
        if let previous = selected.last {
            let row = previous / 3 + index / 3
            let column = previous % 3 + index % 3
            if row % 2 == 0, column % 2 == 0 {
                let middle = row / 2 * 3 + column / 2
                if middle != previous, middle != index, !selected.contains(middle) { selected.append(middle) }
            }
        }
        selected.append(index)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if showTrace, let first = selected.first {
                    Path { path in
                        path.move(to: point(first, in: geometry.size))
                        for index in selected.dropFirst() { path.addLine(to: point(index, in: geometry.size)) }
                        if let finger { path.addLine(to: finger) }
                    }
                    .stroke(Color.primary.opacity(0.65), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
                ForEach(0 ..< 9, id: \.self) { index in
                    Circle().fill(Color.primary.opacity(showTrace && selected.contains(index) ? 1 : 0.65))
                        .frame(width: showTrace && selected.contains(index) ? 20 : 14,
                               height: showTrace && selected.contains(index) ? 20 : 14)
                        .position(point(index, in: geometry.size))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { event in
                    if !drawing { selected = []; drawing = true }
                    finger = event.location
                    for index in 0 ..< 9 {
                        let center = point(index, in: geometry.size)
                        if hypot(event.location.x - center.x, event.location.y - center.y) < 28 { add(index) }
                    }
                }
                .onEnded { _ in
                    drawing = false
                    finger = nil
                    value = selected.map(String.init).joined()
                    if PrivacyLockMethod.pattern.accepts(value) { onComplete(value) }
                    selected = []
                })
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 360)
        .onDisappear(perform: clearGesture)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { clearGesture() }
        }
        .accessibilityLabel(Text(privacyText(showTrace
            ? "Draw a pattern through at least four dots. The trace is visible."
            : "Draw a pattern through at least four dots. The trace is hidden.")))
    }

    private func clearGesture() {
        selected = []
        finger = nil
        drawing = false
        value = ""
    }
}
#endif
