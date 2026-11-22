import Combine
import CoreData
import Foundation

final class BolusIntentRequest: BaseIntentsRequest {
    func bolus(_ bolusAmount: Double) async throws -> String {
        switch settingsManager.settings.bolusShortcut {
        case .notAllowed:
            return String(
                localized:
                "Bolusing via Shortcuts is disabled in Trio settings."
            )

        case .limitWithSafetyChecks:
            let requestedAmount = Decimal(bolusAmount)
            let validation = try await bolusSafetyValidator.validate(bolusAmount: requestedAmount)

            if case let .rejected(reason) = validation {
                return reason.shortcutMessage(
                    requestedAmount: requestedAmount,
                    pumpMaxBolus: settingsManager.pumpSettings.maxBolus
                )
            }

            let bolusQuantity = apsManager.roundBolus(amount: requestedAmount)
            await apsManager.enactBolus(amount: Double(bolusQuantity), isSMB: false, callback: nil)
            return String(
                localized:
                "A bolus command of \(bolusQuantity.formatted()) U of insulin was sent."
            )
        }
    }

    func bolusExternal(_ bolusAmount: Double) async throws -> String {
        guard bolusAmount.isFinite, bolusAmount > 0 else { return BaseAPSManager.invalidBolusAmountMessage }
        let bolusQuantity = Decimal(bolusAmount)
        var maxExternal: Decimal { settingsManager.pumpSettings.maxBolus * 3 }
        if bolusQuantity > maxExternal {
            return String(
                localized:
                "The external bolus cannot be larger than 3 x the pump setting max bolus (\(settingsManager.pumpSettings.maxBolus.description))."
            )
        } else {
            let refreshed = try await pumpHistoryStorage.recordExternalInsulin(amount: bolusQuantity, timestamp: Date()) {
                try await self.apsManager.determineBasalSync()
            }
            let receipt = String(localized: "An external bolus of \(bolusQuantity.formatted()) U of insulin was recorded.")
            return refreshed ? receipt : receipt + " " + String(localized: "The insulin calculation could not be refreshed.")
        }
    }
}

private extension BolusSafetyRejection {
    func shortcutMessage(requestedAmount: Decimal, pumpMaxBolus: Decimal) -> String {
        switch self {
        case .exceedsMaxBolus:
            return String(
                localized:
                "The bolus cannot be larger than the pump setting max bolus (\(pumpMaxBolus.description))."
            )
        case .iobUnavailable:
            return String(
                localized:
                "Bolus blocked: current IOB is not available."
            )
        case let .exceedsMaxIOB(currentIOB, maxIOB):
            return String(
                localized:
                "Bolus blocked: a \(requestedAmount.formatted()) U bolus would exceed max IOB (\(maxIOB.formatted()) U). Current IOB: \(currentIOB.formatted()) U."
            )
        case .recentBolusWithinWindow:
            return String(
                localized:
                "Bolus blocked: a significant bolus was delivered within the last \(BolusSafetyEvaluator.recentBolusWindowMinutes) minutes."
            )
        }
    }
}
