import Foundation
import LoopKit
import PrivacyKit
import SwiftUI
import Testing
import UIKit

@testable import Trio

@Suite("Private Live Activity payload") struct PrivacyPresentationTests {
    @Test("All six bars remain visible inside a narrow activity region") @MainActor
    func narrowWaveformRendering() throws {
        let now = Date()
        let state = PrivacyActivityState(readings: (0 ..< 6).map {
            PrivacyReading(mgDL: 108, date: now.addingTimeInterval(-Double($0) * 300))
        }, now: now)
        for presentation in [PrivacyMeterPresentation.standard, .compact, .minimal] {
            for width in [12.0, 14, 16] {
                let columns = try renderedCenterRow(state: state, stale: false, width: width, presentation: presentation)
                var runs = 0
                var previous = false
                for active in columns {
                    if active && !previous { runs += 1 }
                    previous = active
                }
                #expect(runs == 6, "All six chronological bars should fit a \(width)pt region")
            }
        }
    }

    @Test("The overdue ring keeps the same center in narrow regions") @MainActor
    func centeredOverdueRing() throws {
        let now = Date()
        let state = PrivacyActivityState(readings: (0 ..< 6).map {
            PrivacyReading(mgDL: 108, date: now.addingTimeInterval(-Double($0) * 300))
        }, now: now)
        for width in [12.0, 14, 16] {
            let columns = try renderedCenterRow(state: state, stale: true, width: width, presentation: .minimal)
            let first = try #require(columns.firstIndex(of: true))
            let last = try #require(columns.lastIndex(of: true))
            #expect(abs(Double(first + last) / 2 - Double(columns.count - 1) / 2) <= 1)
            #expect(columns[columns.count / 2] == false)
            let runs = columns.indices.filter { columns[$0] && ($0 == 0 || !columns[$0 - 1]) }.count
            #expect(runs == 2, "An overdue reading must render a hollow ring instead of bars or a filled disk")
        }
    }

    @MainActor private func renderedCenterRow(state: PrivacyActivityState, stale: Bool, width: Double, presentation: PrivacyMeterPresentation) throws -> [Bool] {
        let content = PrivacyWaveformView(state: state, stale: stale, presentation: presentation)
            .frame(width: width, height: 20).clipped().background(Color.black)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        let cgImage = try #require(renderer.cgImage)
        let bytesPerRow = cgImage.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * cgImage.height)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: cgImage.width, height: cgImage.height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        let middleRow = cgImage.height / 2
        return (0 ..< cgImage.width).map { x in
            let index = middleRow * bytesPerRow + x * 4
            return Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2]) > 60
        }
    }

    @Test("Icon picker follows the built primary and keeps all original alternatives")
    func iconCatalog() {
        let icons = Icon_.availableIcons
        #expect(icons.contains(.primary))
        #expect(icons.filter { $0.assetName == Icon_.primaryAssetName }.count == 1)
        #expect(Icon_.resolvedIcon(named: nil) == .primary)
        #expect(Icon_.resolvedIcon(named: "removed-or-unknown-icon") == .primary)
        #expect(Icon_.resolvedIcon(named: Icon_.primaryAssetName) == .primary)
        let metadata = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let alternatives = metadata?["CFBundleAlternateIcons"] as? [String: Any] ?? [:]
        let expected = ["trioBlack", "trioWhiteShadow", "trioColorBG", "trioWhite", "trioCircledNoBackground", "trio3D", "diabeetus", "catWithPod", "catWithPodWhiteBG", "hiroSleepCat", "hiroRoundCat", "hiroShiba", "hiroSpaniel", "hiroCorgi"]
        for name in expected {
            #expect(icons.contains { $0.assetName == name })
            #expect(UIImage(named: name) != nil)
            #expect(name == Icon_.primaryAssetName || alternatives[name] != nil, "Alternate icon must be registered, not only available as a preview")
        }
    }

    @Test("A current-grid recovery refreshes presentation but preserves the actual sample timestamp") func recoveredGridReceipt() {
        let receivedAt = Date()
        let measuredAt = receivedAt.addingTimeInterval(-240)
        let reading = GlucoseData(glucose: 108, date: measuredAt, direction: nil)
        let state = LiveActivityAttributes.ContentState(
            new: reading, prev: nil, units: .mmolL, chart: [reading],
            settings: TrioSettings(), determination: nil, iob: nil,
            override: nil, tempTarget: nil, widgetItems: [], privateDisplay: true,
            privateRecoveredAt: receivedAt
        )
        #expect(state.glucoseMeasuredAt == measuredAt)
        #expect(state.privacy?.measuredAt == measuredAt)
        #expect(state.privacy?.recoveredAt == receivedAt)
        #expect(state.privacy?.staleDate == receivedAt.addingTimeInterval(360))
        let fallback = LiveActivityAttributes.ContentState.privateFallback(previous: state, settings: TrioSettings())
        #expect(fallback.privacy?.staleDate == state.privacy?.staleDate)
    }

    @Test("Private alert content preserves the dependency's complete action list") func alertActions() {
        let content = LoopKit.Alert.Content(
            title: "Low Glucose", body: "Clinical details",
            actions: [.init(label: "OK", identifier: "acknowledge")]
        )
        let alert = LoopKit.Alert(
            identifier: .init(managerIdentifier: "Trio", alertIdentifier: "glucose.low.test"),
            foregroundContent: content, backgroundContent: content,
            trigger: .immediate, interruptionLevel: .critical, sound: .sound(name: "alarm.caf")
        )
        let presentation = TrioPrivacyAlert.content(content, for: alert, enabled: true)
        #expect(presentation?.title == PrivacyText.attention)
        #expect(presentation?.body == "")
        #expect(presentation?.actions == content.actions)
        #expect(TrioPrivacyAlert.content(content, for: alert, enabled: false) == content)
        #expect(alert.backgroundContent == content)
    }

    @Test("Private snapshots fit ActivityKit and omit health text") func payloadBudget() throws {
        let now = Date()
        let reading = GlucoseData(glucose: 142, date: now, direction: nil)
        let state = LiveActivityAttributes.ContentState(
            new: reading, prev: nil, units: .mmolL, chart: [reading],
            settings: TrioSettings(), determination: nil, iob: 3,
            override: nil, tempTarget: nil, widgetItems: [],
            privateDisplay: true, privateCover: Data(repeating: 0, count: 1200)
        )
        #expect(state.bg.isEmpty)
        #expect(state.glucose == nil)
        #expect(state.detailedViewState.chart.isEmpty)
        #expect(state.detailedViewState.iob == 0)
        #expect(state.privacy?.measuredAt == now)
        #expect(state.privacy?.staleDate == now.addingTimeInterval(360))
        #expect(try JSONEncoder().encode(state).count < 4096)
    }

    @Test("Fallback removes the cover while retaining stale geometry and measurement time") func fallbackCoverRemoval() {
        let now = Date().addingTimeInterval(-7 * 3600)
        let reading = GlucoseData(glucose: 142, date: now, direction: nil)
        let state = LiveActivityAttributes.ContentState(
            new: reading, prev: nil, units: .mmolL, chart: [reading],
            settings: TrioSettings(), determination: nil, iob: 3,
            override: nil, tempTarget: nil, widgetItems: [],
            privateDisplay: true, privateCover: Data([1, 2, 3])
        )
        let fallback = LiveActivityAttributes.ContentState.privateFallback(previous: state, settings: TrioSettings(), cover: nil)
        #expect(fallback.privacy?.cover == nil)
        #expect(fallback.privacy?.measuredAt == state.privacy?.measuredAt)
        #expect(fallback.privacy?.heights == state.privacy?.heights)
        #expect(fallback.privacy?.color == state.privacy?.color)
        #expect(fallback.privacy?.isStale(at: Date()) == true)
    }
}
