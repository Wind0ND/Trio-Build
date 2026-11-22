import CoreData
import Foundation

extension Home.StateModel {
    // MARK: - Insulin / Pump History

    @MainActor func setupInsulinController() {
        insulinControllerDelegate.onContentChange = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.updateInsulinFromController()
                self.displayPumpStatusHighlightMessage()
                self.displayPumpStatusBadge()
            }
        }

        do {
            insulinController.fetchRequest.predicate = .forPump(.pumpHistory(since: chartHistoryStartDate), simulated: glucoseStorage.mockPumpConnected == true)
            try insulinController.performFetch()
            updateInsulinFromController()
        } catch {
            warning(.ui, "Fetching insulin for home screen failed", error: error)
        }
    }

    @MainActor func updateInsulinFromController() {
        guard let objects = insulinController.fetchedObjects else { return }
        insulinFromPersistence = objects

        manualTempBasal = apsManager.isManualTempBasal
        tempBasals = objects.filter { $0.tempBasal != nil }
        suspendAndResumeEvents = objects.filter {
            $0.type == EventType.pumpSuspend.rawValue || $0.type == EventType.pumpResume.rawValue
        }
    }

    // MARK: - Last Bolus

    //
    // Drives the bolus progress bar. The predicate filters out external boluses so the progress bar
    // does not display the amount of an external bolus added after a pump bolus.

    @MainActor func setupLastBolusController() {
        lastBolusControllerDelegate.onContentChange = { [weak self] in
            Task { @MainActor in
                self?.updateLastBolusFromController()
            }
        }

        do {
            lastBolusController.fetchRequest.predicate = .forPump(.lastPumpBolus, simulated: glucoseStorage.mockPumpConnected == true)
            try lastBolusController.performFetch()
            updateLastBolusFromController()
        } catch {
            warning(.ui, "Fetching last bolus for home screen failed", error: error)
        }
    }

    @MainActor private func updateLastBolusFromController() {
        lastPumpBolus = lastBolusController.fetchedObjects?.first
    }
}
