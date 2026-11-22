import Foundation
import PrivacyKit

extension UserDefaults {
    private enum Keys {
        static let liveActivityOrder = "liveActivityOrder"
    }

    func loadLiveActivityOrderFromUserDefaults() -> [LiveActivityAttributes.LiveActivityItem]? {
        if let itemStrings = stringArray(forKey: Keys.liveActivityOrder) {
            return itemStrings.map { string in
                if string == "" {
                    return .empty
                } else {
                    return LiveActivityAttributes.LiveActivityItem(rawValue: string) ?? .empty
                }
            }
        }
        return nil
    }
}

extension LiveActivityAttributes.SimpleViewStyle {
    init(settings: TrioSettings) {
        self.init(fontSize: settings.liveActivitySimpleFontSize)
    }
}

extension LiveActivityAttributes.ContentState {
    /// Privacy must take effect even while Core Data is loading or has no recent samples.
    static func privateFallback(
        previous: Self?, settings: TrioSettings,
        cover: Data? = UserDefaults.standard.data(forKey: PrivacyPreference.coverKey)
    ) -> Self {
        // A public chart no longer carries manual provenance. Wait for an accepted CGM snapshot.
        let readings: [PrivacyReading] = []
        let snapshot = previous?.privacy?.replacingCover(cover).replacingMeterStyle(.stored()) ?? PrivacyActivityState(
            readings: readings, now: Date(), palette: .stored(),
            cover: cover, meterStyle: .stored()
        )
        let empty = LiveActivityAttributes.ContentAdditionalState(
            chart: [], rotationDegrees: 0, cob: 0, iob: 0, tdd: 0,
            isOverrideActive: false, overrideName: "", overrideDate: .distantPast, overrideDuration: 0, overrideTarget: 0,
            isTempTargetActive: false, tempTargetName: "", tempTargetDate: .distantPast, tempTargetDuration: 0, tempTargetTarget: 0,
            widgetItems: [], minForecast: [], maxForecast: [], forecastLines: [], forecastDisplayType: ""
        )
        return Self(
            unit: "", bg: "", glucose: nil, direction: nil, change: "", date: nil,
            highGlucose: 180, lowGlucose: 70, target: 100, glucoseColorScheme: "",
            useDetailedViewIOS: false, useDetailedViewWatchOS: false,
            simpleViewStyle: .init(settings: settings), detailedViewState: empty,
            isInitialState: false, privacy: snapshot, glucoseMeasuredAt: snapshot.measuredAt
        )
    }

    static func calculateChange(chart: [GlucoseData], units: GlucoseUnits) -> String {
        guard chart.count >= 2 else { return "" }

        let lastGlucose = Decimal(chart.first?.glucose ?? 0)
        let secondLastGlucose = Decimal(chart.dropFirst().first?.glucose ?? 0)
        return (lastGlucose - secondLastGlucose).formattedDelta(for: units)
    }

    init(
        new bg: GlucoseData,
        prev _: GlucoseData?,
        units: GlucoseUnits,
        chart: [GlucoseData],
        settings: TrioSettings,
        determination: DeterminationData?,
        iob: Decimal?,
        override: OverrideData?,
        tempTarget: TempTargetData?,
        widgetItems: [LiveActivityAttributes.LiveActivityItem]?,
        privateDisplay: Bool = PrivacyPreference.displayEnabled,
        privateCover: Data? = UserDefaults.standard.data(forKey: PrivacyPreference.coverKey),
        privateRecoveredAt: Date? = nil
    ) {
        let now = Date()
        let privateReadings = chart.filter { !$0.isManual && $0.glucose > 0 && $0.date <= now }
        let privateSnapshot = privateDisplay ? PrivacyActivityState(
            readings: privateReadings.map { PrivacyReading(mgDL: Double($0.glucose), date: $0.date) },
            now: now, palette: .stored(), cover: privateCover,
            recoveredAt: privateReadings.first?.date == bg.date ? privateRecoveredAt : nil,
            meterStyle: .stored()
        ) : nil
        let glucose = bg.glucose
        let formattedBG = glucose.formatted(for: units)
        var rotationDegrees = 0.0

        switch bg.direction {
        case .doubleUp,
             .singleUp,
             .tripleUp:
            rotationDegrees = -90
        case .fortyFiveUp:
            rotationDegrees = -45
        case .flat:
            rotationDegrees = 0
        case .fortyFiveDown:
            rotationDegrees = 45
        case .doubleDown,
             .singleDown,
             .tripleDown:
            rotationDegrees = 90
        case nil,
             .notComputable,
             .rateOutOfRange:
            rotationDegrees = 0
        default:
            rotationDegrees = 0
        }

        let trendString = bg.direction?.symbol as? String
        let change = Self.calculateChange(chart: chart, units: units)

        let detailedState = LiveActivityAttributes.ContentAdditionalState(
            chart: privateDisplay ? [] : chart.map { LiveActivityAttributes.ChartItem(value: Decimal($0.glucose), date: $0.date) },
            rotationDegrees: privateDisplay ? 0 : rotationDegrees,
            cob: privateDisplay ? 0 : Decimal(determination?.cob ?? 0),
            iob: privateDisplay ? 0 : (iob ?? 0 as Decimal),
            tdd: privateDisplay ? 0 : (determination?.tdd ?? 0 as Decimal),
            isOverrideActive: privateDisplay ? false : (override?.isActive ?? false),
            overrideName: privateDisplay ? "" : (override?.overrideName ?? "Override"),
            overrideDate: override?.date ?? Date(),
            overrideDuration: privateDisplay ? 0 : (override?.duration ?? 0),
            overrideTarget: privateDisplay ? 0 : (override?.target ?? 0),
            isTempTargetActive: privateDisplay ? false : (tempTarget?.isActive ?? false),
            tempTargetName: privateDisplay ? "" : (tempTarget?.tempTargetName ?? "Temp Target"),
            tempTargetDate: tempTarget?.date ?? Date(),
            tempTargetDuration: privateDisplay ? 0 : (tempTarget?.duration ?? 0),
            tempTargetTarget: privateDisplay ? 0 : (tempTarget?.target ?? 0),
            widgetItems: widgetItems ?? [], // set empty array here to silence compiler; this can never be nil
            minForecast: !privateDisplay && settings.displayGlucoseForecasts && settings.forecastDisplayType == .cone
                ? (determination?.minForecast ?? []) : [],
            maxForecast: !privateDisplay && settings.displayGlucoseForecasts && settings.forecastDisplayType == .cone
                ? (determination?.maxForecast ?? []) : [],
            forecastLines: !privateDisplay && settings.displayGlucoseForecasts && settings.forecastDisplayType == .lines
                ? (determination?.forecastLines ?? [])
                .map { LiveActivityAttributes.ForecastLine(type: $0.type, values: $0.values) }
                : [],
            forecastDisplayType: settings.forecastDisplayType.rawValue
        )

        self.init(
            unit: privateDisplay ? "" : settings.units.rawValue,
            bg: privateDisplay ? "" : formattedBG,
            glucose: privateDisplay ? nil : Decimal(glucose),
            direction: privateDisplay ? nil : trendString,
            change: privateDisplay ? "" : change,
            date: determination?.date,
            highGlucose: settings.high,
            lowGlucose: settings.low,
            target: privateDisplay ? 100 : (determination?.target ?? 100 as Decimal),
            glucoseColorScheme: settings.glucoseColorScheme.rawValue,
            useDetailedViewIOS: settings.lockScreenView == .detailed,
            useDetailedViewWatchOS: settings.smartStackView == .detailed,
            simpleViewStyle: LiveActivityAttributes.SimpleViewStyle(settings: settings),
            detailedViewState: detailedState,
            isInitialState: false,
            privacy: privateSnapshot,
            glucoseMeasuredAt: privateDisplay ? privateSnapshot?.measuredAt : bg.date
        )
    }
}
