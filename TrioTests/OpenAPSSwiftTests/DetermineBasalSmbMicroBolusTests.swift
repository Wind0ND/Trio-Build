import Foundation
import Testing
@testable import Trio

@Suite("determineBasal SMB microbolus behavior") struct DetermineBasalSmbMicroBolusTests {
    @Test("Device SMB restriction selects the complete native basal-only algorithm", arguments: [1, 2, 5])
    func deviceRestrictionMatchesNativeBasalOnly(delta: Decimal) throws {
        let inputs = buildInputs(lastBolusOffsetMinutes: 10)
        var profile = inputs.profile
        profile.skipNeutralTemps = false
        let glucoseStatus = GlucoseStatus(
            delta: delta, glucose: 140, noise: 1, shortAvgDelta: delta, longAvgDelta: delta,
            date: inputs.currentTime, lastCalIndex: nil, device: "test"
        )
        let iobForecast = (0 ..< 48).map { index -> IobResult in
            let remaining = Decimal(48 - index) / 48
            let time = inputs.currentTime.addingTimeInterval(Double(index) * 300)
            return IobResult(
                iob: 1.2 * remaining, activity: 0.008 * remaining,
                basaliob: 1.2 * remaining, bolusiob: 0, netbasalinsulin: 0, bolusinsulin: 0, time: time,
                iobWithZeroTemp: IobResult.IobWithZeroTemp(
                    iob: 1.2 * remaining, activity: 0.008 * remaining,
                    basaliob: 1.2 * remaining, bolusiob: 0, netbasalinsulin: 0, bolusinsulin: 0, time: time
                ), lastBolusTime: inputs.iobData.first?.lastBolusTime, lastTemp: inputs.iobData.first?.lastTemp
            )
        }
        func calculate(deviceAllowsSMB: Bool, userDisablesSMB: Bool) throws -> Determination? {
            var variables = inputs.trioCustomOrefVariables
            variables.smbIsOff = userDisablesSMB
            return try DeterminationGenerator.determineBasal(
                profile: profile, preferences: inputs.preferences, currentTemp: inputs.currentTemp,
                iobData: iobForecast, mealData: inputs.mealData, autosensData: inputs.autosensData,
                glucoseStatus: glucoseStatus, microBolusAllowed: deviceAllowsSMB,
                trioCustomOrefVariables: variables, currentTime: inputs.currentTime
            )
        }
        let nativeResult = try calculate(deviceAllowsSMB: true, userDisablesSMB: true)
        let restrictedResult = try calculate(deviceAllowsSMB: false, userDisablesSMB: false)
        let native = try #require(nativeResult)
        let restricted = try #require(restrictedResult)
        #expect(native.units == nil)
        #expect(restricted.units == nil)
        #expect(restricted.rate == native.rate)
        #expect(restricted.duration == native.duration)
        #expect(restricted.iob == native.iob)
    }

    private func buildInputs(lastBolusOffsetMinutes: Decimal) -> (
        profile: Profile,
        preferences: Preferences,
        currentTemp: TempBasal,
        iobData: [IobResult],
        mealData: ComputedCarbs,
        autosensData: Autosens,
        glucoseStatus: GlucoseStatus,
        trioCustomOrefVariables: TrioCustomOrefVariables,
        microBolusAllowed: Bool,
        currentTime: Date
    ) {
        let now = Date()

        var profile = Profile()
        profile.currentBasal = 1.0
        profile.maxDailyBasal = 1.5
        profile.maxBasal = 3.0
        profile.minBg = 90
        profile.maxBg = 160
        profile.targetBg = 100
        profile.sens = 40
        profile.carbRatio = 10
        profile.thresholdSetting = 70
        profile.maxIob = 6
        profile.enableSMBAlways = true
        profile.bolusIncrement = 0.1
        profile.enableSMBHighBg = true
        profile.enableSMBHighBgTarget = 140

        var preferences = Preferences()
        preferences.curve = .rapidActing
        preferences.useCustomPeakTime = false

        let currentTemp = TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: now)

        let lastBolusTime = UInt64(
            now
                .addingTimeInterval(TimeInterval(-60 * NSDecimalNumber(decimal: lastBolusOffsetMinutes).doubleValue))
                .timeIntervalSince1970 * 1000
        )
        let iobData = [IobResult(
            iob: 0.2,
            activity: 0,
            basaliob: 0.2,
            bolusiob: 0,
            netbasalinsulin: 0,
            bolusinsulin: 0,
            time: now,
            iobWithZeroTemp: IobResult.IobWithZeroTemp(
                iob: 0.2,
                activity: 0,
                basaliob: 0.2,
                bolusiob: 0,
                netbasalinsulin: 0,
                bolusinsulin: 0,
                time: now
            ),
            lastBolusTime: lastBolusTime,
            lastTemp: IobResult.LastTemp(
                rate: 0,
                timestamp: now,
                started_at: now,
                date: UInt64(now.timeIntervalSince1970 * 1000),
                duration: 30
            )
        )]

        let mealData = ComputedCarbs(
            carbs: 0,
            mealCOB: 0,
            currentDeviation: 0,
            maxDeviation: 0,
            minDeviation: 0,
            slopeFromMaxDeviation: 0,
            slopeFromMinDeviation: 0,
            allDeviations: [0, 0, 0, 0, 0],
            lastCarbTime: 0
        )

        let autosensData = Autosens(ratio: 1.0, newisf: nil)

        let glucoseStatus = GlucoseStatus(
            delta: 5,
            glucose: 190,
            noise: 1,
            shortAvgDelta: 5,
            longAvgDelta: 5,
            date: now,
            lastCalIndex: nil,
            device: "test"
        )

        let trioCustomOrefVariables = TrioCustomOrefVariables(
            average_total_data: 0,
            weightedAverage: 0,
            currentTDD: 0,
            past2hoursAverage: 0,
            date: now,
            overridePercentage: 100,
            useOverride: false,
            duration: 0,
            unlimited: false,
            overrideTarget: 0,
            smbIsOff: false,
            advancedSettings: false,
            isfAndCr: false,
            isf: false,
            cr: false,
            smbIsScheduledOff: false,
            start: 0,
            end: 0,
            smbMinutes: 30,
            uamMinutes: 30
        )

        return (
            profile: profile,
            preferences: preferences,
            currentTemp: currentTemp,
            iobData: iobData,
            mealData: mealData,
            autosensData: autosensData,
            glucoseStatus: glucoseStatus,
            trioCustomOrefVariables: trioCustomOrefVariables,
            microBolusAllowed: true,
            currentTime: now
        )
    }

    @Test("Applies SMB microbolus when interval has elapsed") func testMicrobolusWhenIntervalElapsed() throws {
        let inputs = buildInputs(lastBolusOffsetMinutes: 10)

        let determination = try DeterminationGenerator.determineBasal(
            profile: inputs.profile,
            preferences: inputs.preferences,
            currentTemp: inputs.currentTemp,
            iobData: inputs.iobData,
            mealData: inputs.mealData,
            autosensData: inputs.autosensData,
            glucoseStatus: inputs.glucoseStatus,
            microBolusAllowed: inputs.microBolusAllowed,
            trioCustomOrefVariables: inputs.trioCustomOrefVariables,
            currentTime: inputs.currentTime
        )

        #expect(determination?.units ?? 0 > 0)
        #expect(determination?.reason.contains("Microbolusing") ?? false)
    }

    @Test("Waits for SMB interval before another microbolus") func testWaitsForInterval() throws {
        let inputs = buildInputs(lastBolusOffsetMinutes: 1)

        let determination = try DeterminationGenerator.determineBasal(
            profile: inputs.profile,
            preferences: inputs.preferences,
            currentTemp: inputs.currentTemp,
            iobData: inputs.iobData,
            mealData: inputs.mealData,
            autosensData: inputs.autosensData,
            glucoseStatus: inputs.glucoseStatus,
            microBolusAllowed: inputs.microBolusAllowed,
            trioCustomOrefVariables: inputs.trioCustomOrefVariables,
            currentTime: inputs.currentTime
        )

        #expect(determination?.units == nil || determination?.units == 0)
        #expect(determination?.reason.contains("Waiting") ?? false)
    }
}
