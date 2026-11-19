import Foundation
import LoopKit
import PrivacyKit
import Testing

@testable import Trio

@Suite("Private Live Activity payload") struct PrivacyPresentationTests {
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
