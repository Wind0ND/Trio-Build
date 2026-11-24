import LoopKit

class ManualTempBasalViewModel: ObservableObject {
    @Published var selectedRate = 6.0
    @Published var selectedDuration = TimeInterval.minutes(5)
    @Published var enacting: Bool = false
    @Published var enactingBolus: Bool = false
    @Published var error: String? = nil
    @Published var activeShortTemp: ShortTempBasalStatus?
    @Published var hasManualTemp = false

    public let allowedRates: [Double] = MedtrumPumpManager.onboardingSupportedBasalRates.filter { $0 > 0 && $0 < 10 }
    public let allowedDurations: [Double] = [5, 10, 15, 20, 25].map { TimeInterval.minutes(Double($0)) } +
        (1 ... 24).map { Double($0) * TimeInterval.minutes(30) }

    var estimatedUnits: String { String(format: "%.2f U", selectedRate * selectedDuration / 3600) }

    func refreshStatus() {
        activeShortTemp = pumpManager?.shortTempBasalStatus
        hasManualTemp = pumpManager?.hasManualTempBasal ?? false
        enactingBolus = pumpManager?.state.bolusDose != nil
    }

    func rateFormatter(for basal: Double) -> String {
        let stepped = (basal / 0.05).rounded() * 0.05
        return String(format: "%.2f", stepped) + " " + String(localized: "U/hr", comment: "Units for showing temp basal rate")
    }

    func durationFormatter(for duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return String(
                format: String(localized: "%lld hr %lld min", comment: "temp basal remaining hours+minutes"),
                hours, minutes
            )
        }

        return String(
            format: String(localized: "%lld min", comment: "temp basal remaining minutes"),
            minutes
        )
    }

    private let pumpManager: MedtrumPumpManager?
    private let goBack: () -> Void
    init(pumpManager: MedtrumPumpManager?, goBack: @escaping () -> Void) {
        self.pumpManager = pumpManager
        self.goBack = goBack

        if let pumpManager {
            refreshStatus()
            pumpManager.addStatusObserver(self, queue: DispatchQueue.main)
        }
    }

    deinit {
        pumpManager?.removeStatusObserver(self)
    }

    func enact() {
        guard let pumpManager, !enacting, !pumpManager.hasManualTempBasal,
              allowedRates.contains(selectedRate), allowedDurations.contains(selectedDuration) else {
            return
        }

        enacting = true
        error = nil
        let rate = selectedRate
        let duration = selectedDuration
        pumpManager.syncPumpData { syncedAt in
            guard syncedAt != nil else {
                DispatchQueue.main.async {
                    self.enacting = false
                    self.error = MedtrumWriteError.noManager.localizedDescription
                    self.refreshStatus()
                }
                return
            }
            pumpManager.enactTempBasal(
                decisionId: nil,
                unitsPerHour: rate,
                duration: duration,
                automatic: false
            ) { error in
                DispatchQueue.main.async {
                    self.enacting = false

                    if let error {
                        self.error = error.localizedDescription
                    }
                    self.refreshStatus()
                    if error == nil, duration >= .minutes(30) { self.goBack() }
                }
            }
        }
    }

    func cancel() {
        guard let pumpManager, !enacting else { return }
        enacting = true
        error = nil
        pumpManager.cancelCurrentManualTempBasal { error in
            DispatchQueue.main.async {
                self.enacting = false
                self.error = error?.localizedDescription
                self.refreshStatus()
            }
        }
    }
}

extension ManualTempBasalViewModel: PumpManagerStatusObserver {
    func pumpManager(_: any LoopKit.PumpManager, didUpdate _: LoopKit.PumpManagerStatus, oldStatus _: LoopKit.PumpManagerStatus) {
        DispatchQueue.main.async {
            self.refreshStatus()
        }
    }
}
