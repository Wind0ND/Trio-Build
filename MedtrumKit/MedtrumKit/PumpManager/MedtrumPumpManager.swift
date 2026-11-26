import CoreBluetooth
import HealthKit
import LoopKit
import MedtrumLifecycleKit
import UIKit

public class MedtrumPumpManager: DeviceManager {
    public let pluginIdentifier = "Medtrum"
    public let localizedTitle: String = "Medtrum Nano"

    public var inSignalLoss: Bool {
        Date.now.timeIntervalSince(state.lastSync) > .minutes(12)
    }

    public var isInoperable: Bool {
        state.basalDeliveryState == .pumpInoperable
    }

    public let managerIdentifier: String = "Medtrum"

    /// The host atomically saves this manager's current raw state before the patch receives a dose command.
    public var persistPendingDelivery: (() throws -> Void)?
    public typealias BasalRecoveryTransaction = (_ save: (PumpManager.RawStateValue) throws -> Void) throws -> Void
    public var persistBasalRecovery: ((BasalRecoveryTransaction) throws -> Void)?
    public var legacyBasalEvidenceProvider: ((DateInterval, @escaping ([MedtrumBasalRecoveryLogEntry]) -> Void) -> Void)?
    func checkpointDelivery() throws {
        guard let persistPendingDelivery else { throw CocoaError(.fileWriteUnknown) }
        try persistPendingDelivery()
    }

    private let log = MedtrumLogger(category: "MedtrumPumpManager")

    public let pumpDelegate = WeakSynchronizedDelegate<PumpManagerDelegate>()
    private let statusObservers = WeakSynchronizedSet<PumpManagerStatusObserver>()

    public var state: MedtrumPumpState
    var oldState: MedtrumPumpState
    public var rawState: PumpManager.RawStateValue {
        deliveryLock.withLock { state.rawValue }
    }

    // Protects the pending dose and delivery-command reservation across BLE callbacks.
    let deliveryLock = NSRecursiveLock()
    var verifiedBasalBaseline: MedtrumBasalRecoveryBaseline?
    var verifiedPumpObservation: MedtrumVerifiedPumpObservation?
    var deliveryGeneration = UUID()
    var basalRecoveryInProgress = false
    var basalRecoveryBlockReported = false
    var basalHistoryReadInFlight = false
    var basalHistoryCache = MedtrumBasalHistoryCache()
    var verifiedClockMapping: MedtrumFrozenClockMapping?
    var userBasalRecoveryOwner: UUID?
    var submittingDelivery = false
    var shortTempBasalTimer: DispatchSourceTimer?
    var shortTempBasalCheckInFlight = false
    var shortTempBasalNextAttempt = Date.distantPast
    var shortTempBasalNextAttemptUptime: TimeInterval = 0
    var shortTempClockAlerted = Set<UUID>()
    var shortTempBasalLastVerifiedSync = Date.distantPast
    var shortTempBasalObservedSegment: BasalData?
    var shortTempBasalMonitoringEnabled = true
    public var armShortTempBasalAlarm: ((UUID, Date, @escaping (Bool) -> Void) -> Void)?
    public var retireShortTempBasalAlarm: ((UUID) -> Void)?
    public var shortTempBasalAlarmIsValid: ((UUID) -> Bool)?
    public var shortTempBasalAlarmDidEnterDriver: ((UUID) -> Void)?
    public var reportShortTempBasalFailure: ((UUID) -> Void)?
    public var reportBasalPulseCompanionFailure: ((UUID) -> Void)?
    public var automaticBasalPulseEnabled: (() -> Bool)?
    public var isCurrentBasalPulsePump: (() -> Bool)?
    var pulseContinuationInFlight = false
    var pulseContinuationNextAttemptUptime: TimeInterval = 0
    private let logDeviceIdentifierLock = NSLock()
    private var logDeviceIdentifierStorage = ""

    /// for host-app logging
    var logDeviceIdentifier: String {
        logDeviceIdentifierLock.withLock { logDeviceIdentifierStorage }
    }

    private func refreshLogDeviceIdentifier() {
        let identifier = state.pumpSN.hexEncodedString()
        logDeviceIdentifierLock.withLock { logDeviceIdentifierStorage = identifier }
    }

    var bluetooth: BluetoothManager!
    convenience init(state: MedtrumPumpState) {
        self.init(state: state, bluetooth: BluetoothManager(knownPeripheralIdentifier: state.peripheralIdentifier))
    }

    init(state: MedtrumPumpState, bluetooth: BluetoothManager?) {
        self.state = state
        oldState = MedtrumPumpState(rawValue: state.rawValue)
        self.bluetooth = bluetooth
        refreshLogDeviceIdentifier()
        guard let bluetooth else { return }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appMovedToBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appMovedToForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )

        bluetooth.pumpManager = self
        MedtrumLogger.pumpManager = self
        startShortTempBasalMonitoring()
    }

    deinit {
        shortTempBasalTimer?.cancel()
        NotificationCenter.default.removeObserver(self)
        log.info("MedtrumPumpManager deallocated")
    }

    public func forgetBluetoothManager() {
        retireShortTempBasalIntent()
        shortTempBasalTimer?.cancel()
        deliveryLock.withLock { shortTempBasalMonitoringEnabled = false }
        bluetooth?.pumpManager = nil
        bluetooth?.disconnect(force: true)
        // In-flight completions may still refer to this transport. Detach it now;
        // release it with the manager rather than invalidating an IUO under those callbacks.
    }

    /// background sync, doesn't lock loops
    static let heartbeatSyncFreshnessInterval: TimeInterval = .minutes(2.5)

    /// start of the loop, try to avoid syncs
    static let loopSyncFreshnessInterval: TimeInterval = .minutes(4.5)

    static let patchTimeRefreshInterval: TimeInterval = .minutes(30)

    public required convenience init?(rawState: RawStateValue) {
        self.init(state: MedtrumPumpState(rawValue: rawState))
    }

    public var isOnboarded: Bool {
        state.isOnboarded
    }

    public static var onboardingMaximumBasalScheduleEntryCount: Int {
        48
    }

    public static var onboardingSupportedBasalRates: [Double] {
        // During onboard, we assume 300u -> 0.00-30U/hr
        // 0 U/hr is a supported scheduled basal rate
        (0 ... 600).map { Double($0) / 20 }
    }

    public static var onboardingSupportedBolusVolumes: [Double] {
        // 0.05 units for rates between 0.05-30U
        // 0 is not a supported bolus volume
        (1 ... 600).map { Double($0) / 20 }
    }

    public static var onboardingSupportedMaximumBolusVolumes: [Double] {
        MedtrumPumpManager.onboardingSupportedBolusVolumes
    }

    public var delegateQueue: DispatchQueue! {
        get {
            pumpDelegate.queue
        }
        set {
            pumpDelegate.queue = newValue
        }
    }

    public func roundToSupportedBolusVolume(units: Double) -> Double {
        // We do support rounding down to 0.00u
        supportedBolusVolumes.last(where: { $0 <= units }) ?? 0
    }

    public func roundToSupportedBasalRate(unitsPerHour: Double) -> Double {
        supportedBasalRates.last(where: { $0 <= unitsPerHour }) ?? 0
    }

    public var supportedBasalRates: [Double] {
        guard !state.pumpSN.isEmpty else {
            return MedtrumPumpManager.onboardingSupportedBasalRates
        }

        // 300U -> 0.05-30U
        // 200U -> 0.05-25U
        return state.pumpName.contains("300U") ? MedtrumPumpManager.onboardingSupportedBasalRates : (0 ... 500)
            .map { Double($0) / 20 }
    }

    public var supportedBolusVolumes: [Double] {
        MedtrumPumpManager.onboardingSupportedBolusVolumes
    }

    public var supportedMaximumBolusVolumes: [Double] {
        MedtrumPumpManager.onboardingSupportedBolusVolumes
    }

    public var maximumBasalScheduleEntryCount: Int {
        MedtrumPumpManager.onboardingMaximumBasalScheduleEntryCount
    }

    public var minimumBasalScheduleEntryDuration: TimeInterval {
        TimeInterval(minutes: 30)
    }

    public var debugDescription: String {
        state.debugDescription
    }

    public func acknowledgeAlert(alertIdentifier _: LoopKit.Alert.AlertIdentifier) async throws {
        // No alerts to acknowledge for Medtrum
    }

    public func getSoundBaseURL() -> URL? {
        nil
    }

    public func getSounds() -> [LoopKit.Alert.Sound] {
        []
    }

    public var pumpManagerDelegate: LoopKit.PumpManagerDelegate? {
        get {
            pumpDelegate.delegate
        }
        set {
            pumpDelegate.delegate = newValue
        }
    }

    private func device(_ state: MedtrumPumpState) -> HKDevice {
        HKDevice(
            name: state.pumpName,
            manufacturer: "Medtrum",
            model: state.model,
            hardwareVersion: nil,
            firmwareVersion: nil,
            softwareVersion: state.swVersion,
            localIdentifier: nil,
            udiDeviceIdentifier: nil
        )
    }

    /// While the patch is being stopped on request, the states it reports are not a base reset
    private(set) var isDeactivatingPatch = false

    private var mustProvideBLEHeartbeat = false
    private var lastHeartbeat: Date = .distantPast

    private static let heartbeatInterval: TimeInterval = .minutes(1)

    func issueHeartbeatIfNeeded() {
        guard mustProvideBLEHeartbeat,
              Date.now.timeIntervalSince(lastHeartbeat) > Self.heartbeatInterval
        else {
            return
        }

        lastHeartbeat = Date.now
        log.info("Firing BLE heartbeat")

        pumpDelegate.notify { delegate in
            guard let delegate = delegate else {
                self.log.error("Heartbeat fire could not be reported -> Missing delegate")
                return
            }

            delegate.pumpManagerBLEHeartbeatDidFire(self)
        }
    }

    private let backgroundTask = BackgroundTask()
    @objc func appMovedToBackground() {
        if state.useSilentTones {
            log.info("Starting silent tones")
            backgroundTask.startBackgroundTask()
        }
    }

    @objc func appMovedToForeground() {
        backgroundTask.stopBackgroundTask()
        serviceShortTempBasalDeadline()
    }
}

public extension MedtrumPumpManager {
    var pumpRecordsBasalProfileStartEvents: Bool {
        false
    }

    var pumpReservoirCapacity: Double {
        state.model == "MD8301" ? 300 : 200
    }

    var lastSync: Date? {
        state.lastSync
    }

    var status: PumpManagerStatus {
        deliveryLock.withLock { self.status(state) }
    }

    private func status(_ state: MedtrumPumpState) -> PumpManagerStatus {
        PumpManagerStatus(
            timeZone: TimeZone.current,
            device: device(state),
            pumpBatteryChargeRemaining: nil, // Patch pumps do not need to report back battery status
            basalDeliveryState: state.basalDeliveryUncertain || basalRecoveryInProgress ? nil : state.basalDeliveryState,
            bolusState: state.bolusDeliveryState,
            insulinType: state.insulinType,
            deliveryIsUncertain: basalRecoveryInProgress || state.bolusDeliveryUncertain || state.basalDeliveryUncertain || !state.unresolvedShortTempBasals.isEmpty
        )
    }

    func ensureCurrentPumpData(completion: ((Date?) -> Void)?) {
        if let observedAt = cachedPumpDataDate(at: Date()) {
            log.info("Using confirmed fresh pump data for loop recovery")
            completion?(observedAt)
            return
        }

        guard state.patchActivatedAt != nil, !state.patchSessionEnded, !state.pumpState.isSetup else {
            log.error("(ensureCurrentPumpData) patch not in active state yet")
            completion?(nil)
            return
        }

        syncPumpData(completion: completion)
    }

    func syncPumpData(completion: ((Date?) -> Void)?) {
        log.info("Sync pump data")

        #if targetEnvironment(simulator)
            pumpDelegate.notify { delegate in
                self.state.reservoir = Double(Int.random(in: 10 ..< 200))
                if self.state.initialReservoir == nil {
                    self.state.initialReservoir = self.state.reservoir
                }

                delegate?.pumpManager(self, didReadReservoirValue: self.state.reservoir, at: Date.now) { _ in }

                self.state.lastSync = Date.now
                self.notifyStateDidChange()

                completion?(nil)
            }
            return
        #endif

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion?(nil)
                return
            }

            StateSyncer.fetchPatchTimeIfStale(pumpManager: self)
            let query = self.captureBasalSyncContext()
            let syncResult = self.bluetooth.write(SynchronizePacket())

            switch syncResult {
            case let .failure(error):
                self.log.error("Failed to write: \(error.localizedDescription)")
                completion?(nil)
                return

            case let .success(data):
                guard let syncResponse = data as? SynchronizePacketResponse else {
                    self.log.error("Invalid response data...")
                    completion?(nil)
                    return
                }

                do {
                    self.log.info("Manual sync: \(String(data: try JSONEncoder().encode(syncResponse), encoding: .utf8) ?? "")")
                } catch {
                    self.log.warning("State update: Failed to encode JSON")
                }

                self.withLegacyBasalEvidence(for: query) { evidence in
                    self.withBasalHistory(for: query, response: syncResponse, evidence: evidence) { finalStatus, history in
                        StateSyncer.sync(syncResponse: finalStatus, state: self.state, pumpManager: self,
                            duringReconnect: false, fullSync: true, recoveryQuery: query, legacyEvidence: evidence,
                            historyResolution: history)
                        // History acceptance can finish asynchronously. A protected result must stay nil.
                        completion?(self.verifiedPumpDataDate(at: Date()))
                    }
                }
            }
        }
    }

    func setMustProvideBLEHeartbeat(_ mustProvideBLEHeartbeat: Bool) {
        self.mustProvideBLEHeartbeat = mustProvideBLEHeartbeat
    }

    func createBolusProgressReporter(reportingOn: DispatchQueue) -> (any LoopKit.DoseProgressReporter)? {
        if let doseEntry = state.bolusDose {
            return MedtrumDoseProgressReporter(
                pumpManager: self,
                dose: doseEntry,
                reportingQueue: reportingOn
            )
        }

        return nil
    }

    func estimatedDuration(toBolus units: Double) -> TimeInterval {
        // 1.5 unit per minute
        units / 1.5 * TimeInterval(minutes: 1)
    }

    func enactBolus(
        decisionId: UUID?, units: Double, activationType: LoopKit.BolusActivationType,
        completion: @escaping (LoopKit.PumpManagerError?) -> Void
    ) {
        enactBolus(decisionId: decisionId, units: units, activationType: activationType, validation: nil, completion: completion)
    }

    func enactGuardedAutomaticBolus(units: Double, isValid: @escaping () -> Bool,
                                   completion: @escaping (LoopKit.PumpManagerError?) -> Void) {
        enactBolus(decisionId: nil, units: units, activationType: .automatic, validation: isValid, completion: completion)
    }

    private func enactBolus(
        decisionId: UUID?, units: Double, activationType: LoopKit.BolusActivationType,
        validation: (() -> Bool)?, completion: @escaping (LoopKit.PumpManagerError?) -> Void
    ) {
        guard activationType != .automatic || (automaticBasalPulseEnabled?() != true && !hasActiveBasalPulse) else {
            completion(.deviceState(MedtrumConnectError.automaticBolusUnavailable)); return
        }
        guard validation?() ?? true else { completion(.configuration(MedtrumWriteError.contextChanged)); return }
        guard activationType != .automatic || !hasManualTempBasal else {
            completion(.configuration(MedtrumWriteError.contextChanged)); return
        }
        let originalContext = automaticBolusContext()
        guard activationType != .automatic || originalContext.allowsAutomaticBolus else {
            completion(.deviceState(MedtrumConnectError.automaticBolusUnavailable))
            return
        }
        guard let finish = reserveDeliveryCommand(completion) else { return }
        ensureConnectedAndActive { error in
            if let error {
                finish(.communication(error))
                return
            }
            let duration = self.estimatedDuration(toBolus: units)
            let dose = UnfinalizedDose(decisionId: decisionId, units: units, duration: duration,
                                       activationType: activationType, insulinType: self.state.insulinType)
            self.deliveryLock.lock()
            guard activationType != .automatic || self.automaticBolusContext() == originalContext else {
                self.deliveryLock.unlock()
                finish(.deviceState(MedtrumConnectError.automaticBolusUnavailable))
                return
            }
            guard self.state.bolusDose == nil, !self.status.deliveryIsUncertain, self.state.pumpState.isDelivering else {
                self.deliveryLock.unlock()
                finish(.deviceState(MedtrumConnectError.isSuspended))
                return
            }
            self.state.bolusDose = dose
            self.state.awaitingBolusReply = true
            self.notifyStateDidChange()
            self.deliveryLock.unlock()

            do {
                try self.checkpointDelivery()
            } catch {
                self.deliveryLock.withLock {
                    if self.state.bolusDose === dose {
                        self.state.bolusDose = nil
                        self.state.awaitingBolusReply = false
                    }
                    self.notifyStateDidChange()
                }
                self.log.error("Cannot checkpoint delivery: \(error.localizedDescription)")
                finish(.configuration(MedtrumWriteError.persistenceFailed))
                return
            }
            if activationType == .automatic, self.automaticBolusContext() != originalContext {
                self.deliveryLock.withLock {
                    if self.state.bolusDose === dose {
                        self.state.bolusDose = nil
                        self.state.awaitingBolusReply = false
                    }
                    self.notifyStateDidChange()
                }
                // No command was sent: do not leave a persisted pending bolus after restart.
                do { try self.checkpointDelivery() } catch {
                    finish(.configuration(MedtrumWriteError.persistenceFailed))
                    return
                }
                finish(.deviceState(MedtrumConnectError.automaticBolusUnavailable))
                return
            }
            let result = self.bluetooth.write(SetBolusPacket(bolusAmount: units), validation: {
                (validation?() ?? true) &&
                    (activationType != .automatic || (!self.hasManualTempBasal && self.automaticBolusContext() == originalContext))
            })
            self.deliveryLock.lock()
            defer { self.deliveryLock.unlock() }
            // A final progress event can arrive while write is waiting for its reply.
            guard self.state.bolusDose === dose else {
                if case .failure = result { finish(.uncertainDelivery) } else { finish(nil) }
                return
            }
            self.state.awaitingBolusReply = false
            switch result {
            case .success:
                self.notifyStateDidChange()
                self.emitPumpEvents([NewPumpEvent.bolus(unfinalizedDose: dose, confirmedProgressOnly: self.state.bolusDeliveryUncertain)], replacePendingEvents: false)
                finish(nil)
            case let .failure(error):
                if error.deliveryMayHaveStarted || dose.deliveredUnits > 0 {
                    self.markBolusDeliveryUncertain()
                    finish(.uncertainDelivery)
                } else {
                    self.state.bolusDose = nil
                    self.notifyStateDidChange()
                    self.emitPumpEvents([])
                    // This branch still holds deliveryLock; persistence must run after it is released.
                    DispatchQueue.global(qos: .utility).async { try? self.checkpointDelivery() }
                    finish(.communication(error))
                }
            }
        }
    }

    private func reserveDeliveryCommand(
        _ completion: @escaping (PumpManagerError?) -> Void
    ) -> ((PumpManagerError?) -> Void)? {
        deliveryLock.lock()
        guard !status.deliveryIsUncertain else {
            deliveryLock.unlock(); completion(.uncertainDelivery); return nil
        }
        guard !submittingDelivery, state.bolusState == .noBolus else {
            deliveryLock.unlock()
            completion(.deviceState(MedtrumConnectError.isBolussing))
            return nil
        }
        submittingDelivery = true
        deliveryGeneration = UUID()
        deliveryLock.unlock()
        return { error in
            self.deliveryLock.withLock { self.submittingDelivery = false }
            completion(error)
        }
    }

    func cancelBolus(completion: @escaping (LoopKit.PumpManagerResult<LoopKit.DoseEntry?>) -> Void) {
        log.info("Cancelling bolus...")

        state.cancelingBolusSince = Date.now
        notifyStateDidChange()

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                self.state.cancelingBolusSince = nil
                self.notifyStateDidChange()

                completion(.failure(.communication(error)))
                return
            }

            let result = self.bluetooth.write(CancelBolusPacket())
            self.deliveryLock.lock()
            defer { self.deliveryLock.unlock() }
            if case let .failure(error) = result {
                self.log.error("Failed to cancel bolus: \(error.localizedDescription)")
                self.state.cancelingBolusSince = nil
                self.notifyStateDidChange()

                if error.deliveryMayHaveStarted {
                    self.markBolusDeliveryUncertain()
                    completion(.failure(.uncertainDelivery))
                } else {
                    completion(.failure(.communication(error)))
                }
                return
            }

            self.log.info("Bolus cancelled!")

            guard let doseEntry = self.state.bolusDose else {
                self.state.cancelingBolusSince = nil
                self.notifyStateDidChange()

                completion(.success(nil))
                return
            }

            if self.state.bolusDeliveryUncertain {
                // Cancel confirms the stop, not how much was delivered before it.
                self.state.cancelingBolusSince = nil
                self.notifyStateDidChange()
                completion(.failure(.uncertainDelivery))
                return
            }
            let dose = doseEntry.toDoseEntry()
            var events = self.runningTempBasal()
            events.append(NewPumpEvent.bolus(dose: dose))

            self.state.bolusDose = nil
            self.state.awaitingBolusReply = false
            self.state.cancelingBolusSince = nil
            self.state.lastSync = Date.now
            self.notifyStateDidChange()

            self.emitPumpEvents(events)

            completion(.success(nil))
        }
    }

    func enactTempBasal(
        decisionId: UUID?,
        unitsPerHour: Double,
        for duration: TimeInterval,
        completion: @escaping (LoopKit.PumpManagerError?) -> Void
    ) {
        enactTempBasal(decisionId: decisionId, unitsPerHour: unitsPerHour, duration: duration, automatic: true, completion: completion)
    }

    func enactGuardedAutomaticTempBasal(unitsPerHour: Double, duration: TimeInterval,
                                       isValid: @escaping () -> Bool,
                                       completion: @escaping (LoopKit.PumpManagerError?) -> Void) {
        enactTempBasal(decisionId: nil, unitsPerHour: unitsPerHour, duration: duration,
                       automatic: true, validation: isValid, completion: completion)
    }

    func enactTempBasal(
        decisionId: UUID?, unitsPerHour: Double, duration: TimeInterval, automatic: Bool,
        validation: (() -> Bool)? = nil, shortIntent shortIntentTemplate: MedtrumShortTempBasal? = nil,
        alarmPrepared: Bool = false,
        continuationOf: UUID? = nil, deadlineCancellation: UUID? = nil,
        completion: @escaping (LoopKit.PumpManagerError?) -> Void
    ) {
        guard validation?() ?? true else { completion(.configuration(MedtrumWriteError.contextChanged)); return }
        guard duration.isFinite, duration >= 0, duration <= .hours(24), unitsPerHour.isFinite else {
            completion(.configuration(MedtrumWriteError.contextChanged)); return
        }
        guard !automatic || !hasManualTempBasal else {
            completion(.configuration(MedtrumWriteError.contextChanged)); return
        }
        let shortMinutes = Int(duration / 60)
        let isShort = duration > 0 && ((!automatic && duration < .minutes(30)) || shortIntentTemplate != nil)
        let interruptedPulse = deliveryLock.withLock { state.shortTempBasal?.commandID }
        let protectiveInterrupt = automatic && hasActiveBasalPulse &&
            MedtrumBasalPulsePlan.permitsProtectiveInterruption(rate: unitsPerHour, duration: duration,
                scheduledRate: state.currentBaseBasalRate, pulseRate: state.shortTempBasal?.rate ?? state.basalDose.value)
        let ownsContinuation = continuationOf != nil && continuationOf == state.basalPulseContinuation?.commandID
        guard !automatic || !hasActiveBasalPulse || protectiveInterrupt || ownsContinuation else {
            completion(.configuration(MedtrumWriteError.contextChanged)); return
        }
        var replacementHasCancelled = false
        guard !isShort || (duration == Double(shortMinutes) * 60 &&
            shortTempRateAllowed(unitsPerHour, automatic: automatic) &&
            (automatic ? shortIntentTemplate?.isValid == true && shortIntentTemplate?.automaticPulse == true : MedtrumShortTempBasal.supportedMinutes.contains(shortMinutes))) else {
            completion(.configuration(MedtrumWriteError.contextChanged)); return
        }
        if isShort, !automatic, !alarmPrepared {
            ensureConnectedAndActive { error in
                if let error { completion(.communication(error)); return }
                guard let sessionStart = self.state.patchActivatedAt,
                      var intent = MedtrumShortTempBasal(sessionID: self.state.patchId, sessionStartedAt: sessionStart,
                          commandID: UUID(), rate: unitsPerHour, minutes: shortMinutes, requestedAt: Date()) else {
                    completion(.configuration(MedtrumWriteError.contextChanged)); return
                }
                let start: (Bool) -> Void = { armed in
                    intent.alarmPrepared = armed
                    self.enactTempBasal(decisionId: intent.commandID, unitsPerHour: unitsPerHour,
                        duration: duration, automatic: false, validation: validation, shortIntent: intent,
                        alarmPrepared: true) { error in
                            if error != nil, self.deliveryLock.withLock({ self.state.shortTempBasal?.commandID != intent.commandID && self.state.pendingTempBasal?.decisionId != intent.commandID }) {
                                self.retireShortTempBasalAlarm?(intent.commandID)
                            }
                            completion(error)
                        }
                }
                if let arm = self.armShortTempBasalAlarm { arm(intent.commandID, intent.targetEnd.addingTimeInterval(15), start) }
                else { start(false) }
            }
            return
        }
        let originalSession = automaticBolusContext()
        let writeValidation: () -> Bool = { [weak self] in
            guard let self, validation?() ?? true else { return false }
            return self.deliveryLock.withLock {
                guard self.state.patchId == originalSession.sessionID,
                      self.state.patchActivatedAt == originalSession.sessionStartedAt,
                      !self.state.patchSessionEnded else { return false }
                guard !automatic || !self.hasManualTempBasal else { return false }
                if automatic, !protectiveInterrupt, continuationOf == nil, self.hasActiveBasalPulse {
                    guard self.state.shortTempBasal?.commandID == shortIntentTemplate?.commandID else { return false }
                }
                if protectiveInterrupt, let interruptedPulse, !replacementHasCancelled {
                    guard self.state.shortTempBasal?.commandID == interruptedPulse,
                          self.shortTempBasalCanCancel(command: interruptedPulse, at: Date(), requiresDeadline: false) else { return false }
                }
                if let continuationOf {
                    guard self.state.basalPulseContinuation?.commandID == continuationOf else { return false }
                }
                let protectiveContinuation = continuationOf != nil && unitsPerHour <= self.state.currentBaseBasalRate && self.isCurrentBasalPulsePump?() == true
                guard shortIntentTemplate == nil || ((!automatic || self.automaticBasalPulseEnabled?() == true || protectiveContinuation) &&
                    shortIntentTemplate?.sessionID == self.state.patchId && shortIntentTemplate?.sessionStartedAt == self.state.patchActivatedAt &&
                    shortIntentTemplate.map { $0.targetEnd > Date() } == true) else { return false }
                guard !isShort || self.shortTempRateAllowed(unitsPerHour, automatic: automatic) else { return false }
                if automatic, let shortIntentTemplate {
                    guard self.shortTempBasalAlarmIsValid?(shortIntentTemplate.commandID) == true else { return false }
                }
                guard automatic || duration == 0 || self.manualTempBasalRateAllowed(unitsPerHour) else { return false }
                return !isShort || (self.shortTempBasalMonitoringEnabled && !self.state.patchSessionEnded &&
                    self.state.patchId == originalSession.sessionID && self.state.patchActivatedAt == originalSession.sessionStartedAt)
            }
        }
        log.info("Setting temp basal at \(unitsPerHour)U/hr for \(duration)s")

        guard let finish = reserveDeliveryCommand(completion) else { return }
        ensureConnectedAndActive { error in
            if let error {
                finish(.communication(error))
                return
            }
            guard !self.status.deliveryIsUncertain, self.state.pumpState.isDelivering else {
                finish(.deviceState(MedtrumConnectError.isSuspended))
                return
            }
            if automatic, let shortIntentTemplate, self.shortTempBasalAlarmIsValid?(shortIntentTemplate.commandID) != true {
                finish(.configuration(MedtrumBasalPulseError.alarmUnavailable)); return
            }
            guard writeValidation() else { finish(.configuration(MedtrumWriteError.contextChanged)); return }
            guard !isShort || (!self.hasManualTempBasal && (!self.hasActiveBasalPulse || self.pulseContinuationInFlight)) else {
                finish(.configuration(MedtrumWriteError.contextChanged)); return
            }
            if self.state.basalState == .tempBasal {
                do {
                    try self.checkpointBasal(requested: nil)
                } catch {
                    self.log.error("Cannot checkpoint delivery: \(error.localizedDescription)")
                    finish(.configuration(MedtrumWriteError.persistenceFailed))
                    return
                }
                let result = self.bluetooth.write(CancelTempBasalPacket(), validation: writeValidation)
                if case let .failure(error) = result {
                    finish(self.handleBasalWriteError(error, requested: nil, expectedSession: originalSession))
                    return
                }
                var cancelledAt = Date()
                let endingIntent = self.deliveryLock.withLock { self.state.shortTempBasal }
                if let intent = self.state.shortTempBasal {
                    guard case let .success(data) = result, let response = data as? CancelTempBasalPacketResponse,
                          response.basalType == .STANDARD,
                          response.basalPatchId == Double(self.state.patchId.toUInt64()),
                          let end = intent.confirmedEnd(pumpEnd: response.basalStartTime, observedAt: Date(),
                            clockOffset: self.state.pumpTime.timeIntervalSince(self.state.pumpTimeSyncedAt)) else {
                        finish(self.handleBasalWriteError(.invalidData, requested: nil, expectedSession: originalSession)); return
                    }
                    cancelledAt = end
                }
                let applied = self.deliveryLock.withLock {
                    guard self.state.patchId == originalSession.sessionID,
                          self.state.patchActivatedAt == originalSession.sessionStartedAt,
                          !self.state.patchSessionEnded else { return false }
                    self.state.awaitingBasalReply = false
                    self.state.basalState = .active
                    if let endingIntent {
                        if deadlineCancellation == endingIntent.commandID {
                            StateSyncer.rememberPulseCompanion(state: self.state, ended: endingIntent, at: cancelledAt)
                        } else if self.state.basalPulseContinuation?.commandID == endingIntent.commandID {
                            self.state.basalPulseContinuation = nil
                        }
                    }
                    self.state.shortTempBasal = nil
                    if case let .success(data) = result, let response = data as? CancelTempBasalPacketResponse,
                       response.basalType == .STANDARD, response.basalPatchId == Double(self.state.patchId.toUInt64()),
                       let sessionStart = self.state.patchActivatedAt {
                        self.verifiedBasalBaseline = MedtrumBasalRecoveryBaseline(segment: BasalData(type: response.basalType,
                            sequence: response.basalSequence, patchId: response.basalPatchId,
                            startTime: response.basalStartTime, rate: response.basalValue, delivery: 0),
                            sessionID: self.state.patchId, sessionStartedAt: sessionStart, observedAt: Date())
                    }
                    self.reportScheduledBasal(at: cancelledAt)
                    return true
                }
                guard applied else { finish(.configuration(MedtrumWriteError.contextChanged)); return }
                replacementHasCancelled = true
                if let endingIntent {
                    self.finishEndedShortTempBasal(endingIntent)
                }
            }

            guard duration >= .ulpOfOne else {
                finish(nil)
                return
            }

            if protectiveInterrupt {
                self.deliveryLock.withLock { self.state.basalPulseContinuation = nil }
            }

            if automatic, !self.ensureAutomaticBasalBaseline() {
                finish(.communication(MedtrumWriteError.noData))
                return
            }
            let actualDuration = Self.pumpTempBasalDuration(requested: duration, automatic: isShort ? false : automatic)
            let commandID = shortIntentTemplate?.commandID ?? (isShort ? UUID() : decisionId)
            let preparedTemplate = shortIntentTemplate?.preparedForWrite(at: Date(), uptime: ProcessInfo.processInfo.systemUptime)
            guard shortIntentTemplate == nil || preparedTemplate != nil else {
                finish(.configuration(MedtrumWriteError.contextChanged)); return
            }
            var tempBasalDose = UnfinalizedDose(
                decisionId: commandID, tempRate: unitsPerHour, duration: actualDuration,
                insulinType: self.state.insulinType, automatic: automatic, startDate: preparedTemplate?.requestedAt ?? Date()
            )
            var shortIntent: MedtrumShortTempBasal?
            if isShort {
                guard let sessionStart = self.state.patchActivatedAt, !self.state.patchSessionEnded,
                      self.state.patchId == originalSession.sessionID,
                      sessionStart == originalSession.sessionStartedAt,
                      let commandID,
                      var intent = preparedTemplate ?? MedtrumShortTempBasal(sessionID: self.state.patchId, sessionStartedAt: sessionStart,
                          commandID: commandID, rate: unitsPerHour, minutes: shortMinutes, requestedAt: tempBasalDose.startDate) else {
                    finish(.configuration(MedtrumWriteError.contextChanged)); return
                }
                if intent.pulseBudget != nil { intent.previousPulseAt = self.lastBasalPulseAt }
                shortIntent = intent
            }
            do {
                try self.checkpointBasal(requested: tempBasalDose, shortIntent: shortIntent)
            } catch {
                self.log.error("Cannot checkpoint delivery: \(error.localizedDescription)")
                if isShort { self.deliveryLock.withLock {
                    if self.state.shortTempBasal?.commandID == commandID {
                        self.restorePreviousPulseTime(self.state.shortTempBasal)
                        self.state.shortTempBasal = nil
                    }
                } }
                finish(.configuration(MedtrumWriteError.persistenceFailed))
                return
            }
            if let shortIntent { self.shortTempBasalAlarmDidEnterDriver?(shortIntent.commandID) }
            let result = self.bluetooth.write(SetTempBasalPacket(rate: unitsPerHour, duration: actualDuration), validation: {
                writeValidation() && self.deliveryLock.withLock {
                    guard !self.state.basalDeliveryUncertain, !self.state.bolusDeliveryUncertain,
                          self.state.pendingTempBasal?.startDate == tempBasalDose.startDate,
                          self.state.pendingTempBasal?.estimatedEndDate == tempBasalDose.estimatedEndDate,
                          self.state.pendingTempBasal?.value == tempBasalDose.value,
                          !automatic || self.state.basalRecoveryCheckpoint?.matches(tempBasalDose) == true else { return false }
                    return !isShort || self.state.shortTempBasal?.commandID == commandID
                }
            })
            if case let .failure(error) = result {
                if isShort, !error.deliveryMayHaveStarted {
                    self.deliveryLock.withLock {
                        if self.state.shortTempBasal?.commandID == commandID {
                            self.restorePreviousPulseTime(self.state.shortTempBasal)
                            self.state.shortTempBasal = nil
                        }
                    }
                }
                finish(self.handleBasalWriteError(error, requested: tempBasalDose, expectedSession: originalSession))
                return
            }

            if isShort {
                guard self.deliveryLock.withLock({
                    self.state.patchId == originalSession.sessionID && self.state.patchActivatedAt == originalSession.sessionStartedAt &&
                        self.state.shortTempBasal?.commandID == commandID
                }) else { finish(.configuration(MedtrumWriteError.contextChanged)); return }
                guard case let .success(data) = result, let response = data as? SetTempBasalResponse,
                      response.basalType == .ABSOLUTE_TEMP, abs(response.basalValue - unitsPerHour) < 0.001,
                      response.basalPatchId == Double(self.state.patchId.toUInt64()),
                      let intent = self.state.shortTempBasal?.confirmed(startedAt: response.basalStartTime, observedAt: Date(),
                        clockOffset: self.state.pumpTime.timeIntervalSince(self.state.pumpTimeSyncedAt),
                        sequence: response.basalSequence, acknowledged: true), let localStart = intent.confirmedStart else {
                    self.deliveryLock.withLock {
                        self.state.basalDeliveryUncertain = true
                        self.state.awaitingBasalReply = false
                        self.state.shortTempBasal?.accountingUnresolved = true
                        self.notifyStateDidChange()
                    }
                    finish(.uncertainDelivery); return
                }
                self.deliveryLock.withLock {
                    self.state.shortTempBasal = intent
                    if intent.pulseBudget != nil { self.state.lastBasalPulseAt = localStart }
                    self.shortTempBasalObservedSegment = BasalData(type: response.basalType, sequence: response.basalSequence,
                        patchId: response.basalPatchId, startTime: response.basalStartTime, rate: response.basalValue, delivery: 0)
                    self.shortTempBasalLastVerifiedSync = Date()
                }
                tempBasalDose = UnfinalizedDose(decisionId: commandID, tempRate: unitsPerHour, duration: actualDuration,
                    insulinType: self.state.insulinType, automatic: automatic, startDate: localStart)
            }

            self.deliveryLock.lock()
            defer { self.deliveryLock.unlock() }
            guard self.state.patchId == originalSession.sessionID,
                  self.state.patchActivatedAt == originalSession.sessionStartedAt,
                  !self.state.patchSessionEnded else { finish(.configuration(MedtrumWriteError.contextChanged)); return }
            self.state.awaitingBasalReply = false
            self.state.pendingTempBasal = nil
            self.state.basalRecoveryCheckpoint = nil
            self.deliveryGeneration = UUID()
            var events = self.finalizedTempBasal(endedAt: Date.now)
            events.append(NewPumpEvent.tempBasal(dose: tempBasalDose.toDoseEntry(isMutable: true)))

            self.state.basalDose = tempBasalDose
            self.state.basalState = .tempBasal
            self.state.lastSync = Date.now
            self.notifyStateDidChange()

            self.emitPumpEvents(events)
            if isShort { self.emitShortTempBasalDiagnostic("started") }
            finish(nil)
        }
    }

    func checkpointBasal(requested: UnfinalizedDose?, shortIntent: MedtrumShortTempBasal? = nil) throws {
        try deliveryLock.withLock {
            let checkpoint = captureBasalRecoveryCheckpoint(for: requested)
            if requested?.automatic == true, checkpoint == nil {
                throw MedtrumWriteError.contextChanged
            }
            if let shortIntent {
                state.shortTempBasal = shortIntent
                if shortIntent.pulseBudget != nil {
                    state.lastBasalPulseAt = shortIntent.requestedAt
                    state.lastBasalPulseSessionID = shortIntent.sessionID
                    state.lastBasalPulseSessionStart = shortIntent.sessionStartedAt
                }
            }
            state.pendingTempBasal = requested
            state.basalRecoveryCheckpoint = checkpoint
            state.legacyBasalRecoveryAllowed = false
            basalRecoveryBlockReported = false
            state.awaitingBasalReply = true
            deliveryGeneration = UUID()
        }
        do {
            try checkpointDelivery()
        } catch {
            deliveryLock.withLock {
                state.pendingTempBasal = nil
                state.basalRecoveryCheckpoint = nil
                state.awaitingBasalReply = false
                notifyStateDidChange()
            }
            throw error
        }
    }

    private func handleBasalWriteError(_ error: MedtrumWriteError, requested: UnfinalizedDose?,
                                      expectedSession: MedtrumAutomaticBolusContext) -> PumpManagerError {
        var shouldCheckpoint = false
        let result: PumpManagerError = deliveryLock.withLock {
            guard state.patchId == expectedSession.sessionID, state.patchActivatedAt == expectedSession.sessionStartedAt else {
                return .communication(error)
            }
            state.awaitingBasalReply = false
            deliveryGeneration = UUID()
            guard error.deliveryMayHaveStarted else {
                state.pendingTempBasal = nil
                notifyStateDidChange()
                shouldCheckpoint = true
                return .communication(error)
            }
            state.basalDeliveryUncertain = true
            state.pendingTempBasal = requested
            notifyStateDidChange()
            pumpDelegate.notify { $0?.pumpManager(self, didError: .uncertainDelivery) }
            return .uncertainDelivery
        }
        if shouldCheckpoint {
            do { try checkpointDelivery() } catch { return .configuration(MedtrumWriteError.persistenceFailed) }
        }
        return result
    }

    private func reportScheduledBasal(at now: Date = Date.now) {
        var events = finalizedTempBasal(endedAt: now)

        let basalDose = UnfinalizedDose(
            basalRate: state.currentBaseBasalRate,
            insulinType: state.insulinType,
            startDate: now
        )

        events.append(NewPumpEvent.basal(dose: basalDose.toDoseEntry()))

        state.basalDose = basalDose
        state.lastSync = Date.now
        notifyStateDidChange()

        emitPumpEvents(events)
    }

    func suspendDelivery(completion: @escaping ((any Error)?) -> Void) {
        suspendPatch(duration: .minutes(120), completion: completion)
    }

    func suspendPatch(duration: TimeInterval, completion: @escaping ((any Error)?) -> Void) {
        invalidateBasalObservation()
        log.info("Suspending delivery...")

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion(error)
                return
            }

            let result = self.bluetooth.write(SuspendPumpPacket(duration: duration))
            if case let .failure(error) = result {
                self.log.error("Failed to suspend delivery: \(error.localizedDescription)")
                completion(error)
                return
            }

            let start = Date.now
            let basalDose = UnfinalizedDose(suspendStartTime: start)

            var events = self.finalizedTempBasal(endedAt: start)
            events.append(NewPumpEvent.suspend(dose: basalDose.toDoseEntry()))

            self.state.basalDose = basalDose
            self.state.basalState = .suspended
            self.state.lastSync = Date.now
            self.notifyStateDidChange()

            self.emitPumpEvents(events)

            self.log.info("Delivery suspended for \(duration.minutes) min!")
            completion(nil)
        }
    }

    func resumeDelivery(completion: @escaping ((any Error)?) -> Void) {
        invalidateBasalObservation()
        log.info("Resuming delivery...")

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion(error)
                return
            }

            let response = self.bluetooth.write(ResumePumpPacket())
            if case let .failure(error) = response {
                self.log.error("Failed to resume delivery: \(error.localizedDescription)")
                completion(error)
                return
            }

            self.log.info("Resumed delivery!")

            let resumeDose = UnfinalizedDose(
                resumeStartTime: Date.now,
                insulinType: self.state.insulinType
            )

            var events = self.runningTempBasal()
            events.append(NewPumpEvent.resume(dose: resumeDose.toDoseEntry()))

            self.state.basalDose = resumeDose
            self.state.basalState = .active
            self.state.lastSync = Date.now
            self.notifyStateDidChange()

            self.emitPumpEvents(events)

            completion(nil)
        }
    }

    func syncBasalRateSchedule(
        items: [LoopKit.RepeatingScheduleValue<Double>],
        completion: @escaping (Result<LoopKit.BasalRateSchedule, any Error>) -> Void
    ) {
        log.info("Sync-ing basal schedule...")
        guard let basalSchedule = DailyValueSchedule<Double>(dailyItems: items) else {
            completion(.failure(NSError(domain: "Basal schedule is empty...", code: -1)))
            return
        }

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            let schedule = BasalSchedule(entries: items)
            let packet = SetBasalProfilePacket(basalProfile: schedule.toData())
            let result = self.bluetooth.write(packet)

            if case let .failure(error) = result {
                self.log.error("Failed to sync basal schedule: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            self.state.basalSchedule = schedule
            self.state.lastSync = Date.now
            self.notifyStateDidChange()

            self.log.info("Basal schedule sync complete!")

            completion(.success(basalSchedule))
        }
    }

    func syncDeliveryLimits(
        limits: LoopKit.DeliveryLimits,
        completion: @escaping (Result<LoopKit.DeliveryLimits, any Error>) -> Void
    ) {
        // The patch has no matching hardware setting, so keep the trusted host ceiling locally.
        let maximum = limits.maximumBasalRate?.doubleValue(for: .internationalUnitsPerHour)
        deliveryLock.withLock {
            state.manualBasalMaximum = maximum.flatMap { $0.isFinite && (0 ... 30).contains($0) ? $0 : nil }
            notifyStateDidChange()
        }
        completion(.success(limits))
    }

    func primePatch(_ completion: @escaping (MedtrumPrimePatchResult) -> Void) {
        log.info("Start priming patch...")

        if state.pumpSN.isEmpty {
            // Need to scan for pump base first
            log.warning("No pump base known yet...")
            completion(.failure(error: .noKnownPumpBase))
            return
        }

        if state.sessionToken.isEmpty {
            log.debug("Refreshing session token...")

            // Patch has been disabled and thus a new session token is needed
            state.sessionToken = Crypto.genSessionToken()
            notifyStateDidChange()
        }

        bluetooth.ensureConnected { error in
            if let error = error {
                self.log.error("Failed to connect to pump: \(error)")
                completion(.failure(error: .connectionFailure(reason: error.errorDescription ?? "EMPTY")))
                return
            }

            guard !self.state.pumpState.isTerminated else {
                self.log.error("Cannot prime, patch session is over: \(self.state.pumpState.description)")
                completion(.failure(error: .patchNotPrimeable(state: self.state.pumpState)))
                return
            }

            guard self.state.pumpState.isBeforePriming else {
                self.log.info("Patch is already priming or primed!")
                completion(.success)
                return
            }

            guard self.state.pumpState == .filled else {
                self.log.warning("Patch is not filled yet, refusing to prime. State: \(self.state.pumpState)")
                completion(.failure(error: .patchNotFilled(state: self.state.pumpState)))
                return
            }

            let primeResult = self.bluetooth.write(PrimePacket())
            if case let .failure(error) = primeResult {
                self.log.error("Failed to start priming pump: \(error)")
                completion(.failure(error: .unknownError(reason: error)))
                return
            }

            self.log.info("Priming has started!")
            completion(.success)
        }
    }

    func activatePatch(_ completion: @escaping (MedtrumActivatePatchResult) -> Void) {
        log.info("Activate patch pump...")

        bluetooth.ensureConnected { error in
            if let error = error {
                self.log.error("Failed to connect to pump: \(error)")
                completion(.failure(error: .connectionFailure(reason: error.errorDescription ?? "EMPTY")))
                return
            }

            guard !self.state.pumpState.isTerminated else {
                self.log.error("Cannot activate, patch session is over: \(self.state.pumpState.description)")
                completion(.failure(error: .patchNotActivatable(state: self.state.pumpState)))
                return
            }

            guard !self.state.pumpState.isRunning else {
                // The patch activated, but its answer was lost: the session it starts is not started yet
                if self.state.patchSessionEnded {
                    // Its id is not taken from what the connect synced, which can be stale with no session: the first
                    // status after this sets it, and payloads are not checked against an id until then. It may have
                    // suspended since - the connect synced its status, and notifications keep it current while connected.
                    self.log.warning("Patch already activated, but its session was not started - starting it")
                    let start = Date.now
                    // It activated before now: at the start time the connect synced, if that is the new patch's. The
                    // previous patch's - kept since, or synced before it disconnected - is from before its deactivation.
                    let activatedAt: Date
                    if let syncedActivation = self.state.patchActivatedAt,
                       let deactivatedAt = self.state.previousPatch?.deactivatedAt,
                       syncedActivation > deactivatedAt, syncedActivation <= start
                    {
                        activatedAt = syncedActivation
                    } else {
                        activatedAt = start
                    }
                    self.startPatchSession(
                        patchId: Data(),
                        at: start,
                        activatedAt: activatedAt,
                        isDelivering: self.state.pumpState.isDelivering
                    )
                }

                self.log.info("Patch already activated!")
                completion(.success)
                return
            }

            StateSyncer.syncTime(pumpManager: self)

            let packet = ActivatePacket(
                expirationTimer: self.state.expiryMode.timer,
                alarmSetting: self.state.alarmSetting,
                hourlyMaxInsulin: self.state.maxHourlyInsulin,
                dailyMaxInsulin: self.state.maxDailyInsulin,
                currentTDD: 0,
                basalProfile: self.state.basalSchedule.toData()
            )
            let result = self.bluetooth.write(packet)
            switch result {
            case let .failure(error):
                self.log.error("Failed to activate pump: \(error)")
                completion(.failure(error: .unknownError(reason: error.localizedDescription)))
                return

            case let .success(data):
                guard let data = data as? ActivatePacketResponse else {
                    self.log.error("Failed to parse response...")
                    completion(.failure(error: .unknownError(reason: "Failed to parse response...")))
                    return
                }

                let start = Date.now
                self.startPatchSession(patchId: data.patchId, at: start, activatedAt: start, isDelivering: true)

                self.log.info("Patch activated!")
                completion(.success)
                return
            }
        }
    }

    func deactivatePatch(_ completion: @escaping (MedtrumDeactivatePatchResult) -> Void) {
        log.info("Deactivate patch pump...")

        // The sync that runs as part of connecting can find that the base has reset, and end the
        // session before we get to stop it - see `handleBaseReset`. It also drops the link, which
        // usually fails the connect. Either way the patch is no longer active.
        let hadActivePatch = !state.pumpState.isSetup
        let sessionEndedWhileConnecting = { hadActivePatch && self.state.pumpState.isSetup }

        bluetooth.ensureConnected { error in
            if sessionEndedWhileConnecting() {
                self.log.info("Patch session already ended while connecting, nothing left to deactivate")
                completion(.success)
                return
            }

            if let error = error {
                self.log.error("Failed to connect to pump: \(error)")
                completion(.failure(error: .connectionFailure))
                return
            }

            self.isDeactivatingPatch = true
            defer { self.isDeactivatingPatch = false }

            let result = self.bluetooth.write(StopPatchPacket())
            if case let .failure(error) = result {
                self.log.error("Failed to deactivate pump: \(error)")
                completion(.failure(error: .unknownError(reason: error.localizedDescription)))
                return
            }

            // Connected: the connect synced the patch's status, and its notifications have kept it current since
            self.endPatchSession(at: Date.now, statusIsCurrent: true)

            self.log.info("Patch deactivated")
            completion(.success)

            self.bluetooth.disconnect(force: true)
        }
    }

    func forceDeactivatePatch() {
        log.info("Force deactivating patch...")

        endPatchSession(at: Date.now, statusIsCurrent: false)

        bluetooth.disconnect(force: true)
    }

    /// The base rebooted underneath an activated patch: it came back as a blank, never activated
    /// patch and is not delivering anything. The session cannot be resumed, so it ends here.
    func handleBaseReset(deliveryStoppedAt: Date) {
        log.error("Pump base has reset, patch session is lost - delivery stopped at \(deliveryStoppedAt)")

        // A terminated patch has already raised its own alert, and was not delivering anyway
        let wasRunning = state.pumpState.isRunning

        // What the patch did last is as of the last status of it, before the base went down
        endPatchSession(at: deliveryStoppedAt, statusIsCurrent: false)

        bluetooth.disconnect(force: true)

        if wasRunning {
            emitAlert(alertType: .baseResetNotification)
        }
    }

    /// The new patch delivers on its schedule from `start` - unless it is not delivering: then the suspend reported stays
    /// outstanding, for the first status that shows it delivering to resume. Its expiry counts from `activatedAt`.
    private func startPatchSession(patchId: Data, at start: Date, activatedAt: Date, isDelivering: Bool) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        retireShortTempBasalIntent()
        if state.expiryMode == .default {
            // Issued now, due a set time after the activation
            emitAlert(alertType: .patchReminder(activatedAt: activatedAt, afterActivation: state.notificationAfterActivation, now: start))
        }

        var events: [NewPumpEvent] = []
        if !state.patchSessionEnded {
            // The previous patch was replaced without deactivating it - it fell off, or was swapped outside the app. When it
            // stopped is unknown, so it is taken to have delivered until `start`: a temp basal or a bolus in flight ends
            // there, and the schedule runs from there. No suspend: a host can take one with a resume at the same time as
            // never ending.
            log.warning("Previous patch session was not ended, ending its delivery at activation")
            events.append(contentsOf: finalizedTempBasal(endedAt: start))
            events.append(contentsOf: finalizeInterruptedBolus())
        }

        events.append(NewPumpEvent.replacedPump(date: start))
        if isDelivering {
            let resumeDose = UnfinalizedDose(
                resumeStartTime: start,
                insulinType: state.insulinType
            )
            if state.basalDose.type == .suspend {
                // Only a suspend that was reported gets a resume: a host can take one without it as suspended before it
                events.append(NewPumpEvent.resume(dose: resumeDose.toDoseEntry()))
            } else if !state.patchSessionEnded {
                let basalDose = UnfinalizedDose(
                    basalRate: state.currentBaseBasalRate,
                    insulinType: state.insulinType,
                    startDate: start
                )
                events.append(NewPumpEvent.basal(dose: basalDose.toDoseEntry()))
            }

            state.basalDose = resumeDose
            // What commands check: the old patch may have left it suspended or running a temp basal, and it would
            // stay so until the first status that shows the new patch's basal
            state.basalState = .active
        } else {
            // A resume now would count the time until the patch resumes as delivered. The suspend outstanding - the old
            // session's, or one the status that showed it suspended recorded - stays, for the first status
            // that shows it delivering to resume.
            state.basalState = .suspended
        }

        state.bolusDeliveryUncertain = false
        state.awaitingBolusReply = false
        state.basalDeliveryUncertain = false
        state.pendingTempBasal = nil
        state.basalRecoveryCheckpoint = nil
        state.legacyBasalRecoveryAllowed = false
        verifiedBasalBaseline = nil
        verifiedPumpObservation = nil
        deliveryGeneration = UUID()
        state.patchSessionEnded = false
        state.initialReservoir = nil
        state.patchId = patchId
        state.patchActivatedAt = activatedAt
        state.patchActivationIsProvisional = activatedAt == start
        state.extendedLifePolicy = .init()
        state.lastSync = Date.now
        notifyStateDidChange()

        emitPumpEvents(events)
    }

    /// The patch session is over: delivery stopped at `stoppedAt`, unless it is known to have stopped already
    private func endPatchSession(at deliveryStoppedAt: Date, statusIsCurrent: Bool) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        retireShortTempBasalIntent()
        // Delivery cannot have stopped before the running dose began
        let stoppedAt = max(deliveryStoppedAt, state.basalDose.startDate)

        // Ended already - a force after a deactivation, or no session started since: the previous patch is recorded
        if !state.patchSessionEnded {
            state.previousPatch = PreviousPatch(
                patchId: state.patchId,
                lastStateRaw: state.pumpState.rawValue,
                lastSyncAt: state.lastSync,
                battery: state.battery,
                activatedAt: state.patchActivatedAt ?? Date.distantPast,
                deactivatedAt: stoppedAt,
                initialReservoirLevel: state.initialReservoir,
                reservoirLevel: state.reservoir
            )
        }

        // Suspended already - by the patch halting, or by a suspend - its suspend was reported then. A second, later one
        // would have a host that keeps only the last count the time between the two as delivered. That holds only while
        // the patch can't have resumed: a suspend can end on its own, unseen while out of range, so it takes a state the
        // patch never leaves, one it never delivered in or no longer does, or a current one that shows it not delivering.
        // Otherwise the suspend is reported now.
        let hasStopped = state.basalDose.type == .suspend &&
            (state.pumpState.isTerminated || state.pumpState.isSetup || (statusIsCurrent && !state.pumpState.isDelivering))
        let events = hasStopped ? finalizeInterruptedBolus() : stoppedDelivery(at: stoppedAt)

        state.patchId = Data()
        state.pumpState = .none
        state.backupSessionToken = state.sessionToken
        state.sessionToken = Data()
        state.initialReservoir = nil
        state.patchSessionEnded = true
        state.lastSync = Date.now
        state.basalState = .suspended
        notifyStateDidChange()

        emitPumpEvents(events)
    }

    /// Delivery stopped at `stoppedAt`: a temp basal or a bolus in flight ends there, and the suspend starts
    private func stoppedDelivery(at stoppedAt: Date) -> [NewPumpEvent] {
        var events = finalizedTempBasal(endedAt: stoppedAt)
        events.append(contentsOf: finalizeInterruptedBolus())

        let suspendDose = UnfinalizedDose(suspendStartTime: stoppedAt)
        events.append(NewPumpEvent.suspend(dose: suspendDose.toDoseEntry()))
        state.basalDose = suspendDose

        return events
    }

    func clearAlert(alertType: AlertType, completion: @escaping (Bool) -> Void) {
        log.info("Clearing alert - alertType: \(alertType.rawValue)")

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect to pump: \(error)")
                completion(false)
                return
            }

            let clearAlertResult = self.bluetooth.write(ClearAlertPacket(alertType: alertType))
            if case let .failure(error) = clearAlertResult {
                self.log.error("Failed to clear alert: \(error)")
                completion(false)
                return
            }

            let resumeResult = self.bluetooth.write(ResumePumpPacket())
            if case let .failure(error) = resumeResult {
                self.log.error("Failed to resume patch: \(error)")
                completion(false)
                return
            }

            self.syncPumpData { _ in
                self.log.info("Alert cleared!")
                completion(true)
            }
        }
    }

    func updatePatchSettings(completion: @escaping (MedtrumUpdatePatchResult) -> Void) {
        log.info("Update patch settings...")

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect to pump: \(error)")
                completion(.failure(error: .connectionFailure))
                return
            }

            let package = SetPatchPacket(
                alarmSettings: self.state.alarmSetting,
                hourlyMaxInsulin: self.state.maxHourlyInsulin,
                dailyMaxInsulin: self.state.maxDailyInsulin,
                expirationTimer: self.state.expiryMode.timer
            )
            let result = self.bluetooth.write(package)
            if case let .failure(error) = result {
                self.log.error("Failed to update settings: \(error)")
                completion(.failure(error: .unknownError(reason: error.localizedDescription)))
                return
            }

            self.log.info("Patch settings updated!")
            completion(.success)
        }
    }

    func addStatusObserver(_ observer: PumpManagerStatusObserver, queue: DispatchQueue) {
        statusObservers.insert(observer, queue: queue)
    }

    func removeStatusObserver(_ observer: PumpManagerStatusObserver) {
        statusObservers.removeElement(observer)
    }

    func notifyStateDidChange() {
        refreshLogDeviceIdentifier()

        DispatchQueue.main.async {
            let status = self.status(self.state)
            let oldStatus = self.status(self.oldState)

            self.pumpDelegate.notify { delegate in
                delegate?.pumpManagerDidUpdateState(self)
                delegate?.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
            }

            self.statusObservers.forEach { observer in
                observer.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
            }

            self.deliveryLock.withLock {
                self.oldState = MedtrumPumpState(rawValue: self.state.rawValue)
                self.oldState.bolusDeliveryUncertain = self.state.bolusDeliveryUncertain
                self.oldState.basalDeliveryUncertain = self.state.basalDeliveryUncertain
            }
        }
    }

    internal func emitAlert(alertType: MedtrumAlert) {
        pumpDelegate.notify { delegate in
            // PumpManagerDelegate.issueAlert is async. Both calls stay inside one
            // Task so the alert is still issued before the pump event, as it was
            // when the delegate API was synchronous -- wrapping only the alert
            // would let the two race. The pump event hops back onto the delegate queue.
            Task {
                await delegate?.issueAlert(alertType.alert)

                guard let pumpEvent = NewPumpEvent.alert(type: alertType) else {
                    return
                }

                self.pumpDelegate.notify { delegate in
                    delegate?.pumpManager(
                        self,
                        hasNewPumpEvents: [pumpEvent],
                        lastReconciliation: self.state.lastSync,
                        replacePendingEvents: false,
                        completion: { error in
                            if let error = error {
                                self.handlePumpDelegateError(method: "hasNewPumpEvents", error)
                            }
                        }
                    )
                }
            }
        }
    }

    func updateBolusProgress(delivered: Double, completed: Bool, useEstimatedEndDate: Bool) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        guard let doseEntry = state.bolusDose else { return }
        // Compare in the patch's 0.05-U increments to tolerate binary float conversion.
        let pulses = (delivered * 20).rounded()
        guard pulses >= (doseEntry.deliveredUnits * 20).rounded(), pulses <= (doseEntry.value * 20).rounded() else {
            markBolusDeliveryUncertain()
            return
        }
        doseEntry.deliveredUnits = delivered

        if !completed {
            notifyStateDidChange()
            return
        }

        state.bolusDeliveryUncertain = false
        state.awaitingBolusReply = false
        let dose = doseEntry.toDoseEntry(useEstimatedEndDate: useEstimatedEndDate)
        var events = runningTempBasal()
        events.append(NewPumpEvent.bolus(dose: dose))

        state.bolusDose = nil
        state.lastSync = Date.now
        notifyStateDidChange()

        pumpDelegate.notify { delegate in
            guard let delegate = delegate else {
                return
            }

            delegate.pumpManager(
                self,
                didReadReservoirValue: self.state.reservoir.rounded(toPlaces: 1),
                at: self.state.lastSync
            ) { result in
                switch result {
                case let .failure(error):
                    self.handlePumpDelegateError(method: "didReadReservoirValue", error)
                case .success:
                    break
                }
            }
        }

        emitPumpEvents(events)
    }

    func checkBolusDone() {
        deliveryLock.withLock {
            if state.bolusDose != nil { markBolusDeliveryUncertain() }
        }
    }

    private func markBolusDeliveryUncertain() {
        guard let dose = state.bolusDose, !state.bolusDeliveryUncertain else { return }
        state.bolusDeliveryUncertain = true
        notifyStateDidChange()
        emitPumpEvents([NewPumpEvent.bolus(unfinalizedDose: dose, confirmedProgressOnly: true)], replacePendingEvents: false)
        pumpDelegate.notify { $0?.pumpManager(self, didError: .uncertainDelivery) }
    }

    private func finalizeInterruptedBolus() -> [NewPumpEvent] {
        guard let doseEntry = state.bolusDose else {
            return []
        }

        log.warning(
            "Patch session ended during a bolus... \(doseEntry.deliveredUnits) U of the \(doseEntry.value) U"
        )

        let dose = doseEntry.toDoseEntry()
        state.awaitingBolusReply = false
        state.bolusDose = nil

        pumpDelegate.notify { delegate in
            guard let delegate = delegate else {
                self.log.warning("No pump delegate, not notifying...")
                return
            }

            delegate.pumpManager(self, didError: .uncertainDelivery)
        }

        return [NewPumpEvent.bolus(dose: dose)]
    }

    func ensureConnectedAndActive(_ completion: @escaping (MedtrumConnectError?) -> Void) {
        guard !state.pumpState.isSetup else {
            log.warning("No active patch, failing immediately")
            completion(.failedToFindDevice)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                completion(.failedToFindDevice)
                return
            }

            guard let bluetooth = self.bluetooth, self.shortTempBasalMonitoringEnabled else {
                completion(.failedToFindDevice); return
            }
            bluetooth.ensureConnected(completion)
        }
    }

    private func handlePumpDelegateError(method: String, _ error: Error, _ function: String = #function, _ line: Int = #line) {
        let logLine = "Received pump delegate error in \(method): \(error) at \(function):\(line)"
        log.error(logLine)
        logDeviceCommunication(logLine, type: .error)
    }

    internal func logDeviceCommunication(_ message: String, type: DeviceLogEntryType = .send) {
        // Not dispatching here; if delegate queue is blocked, timestamps will be delayed
        pumpManagerDelegate?.deviceManager(
            self,
            logEventForDeviceIdentifier: logDeviceIdentifier,
            type: type,
            message: message,
            completion: nil
        )
    }

    /// The current temp basal (if any), reported as still running
    private func runningTempBasal() -> [NewPumpEvent] {
        guard state.basalDose.type == .tempBasal else {
            return []
        }

        return [NewPumpEvent.tempBasal(dose: state.basalDose.toDoseEntry(isMutable: true))]
    }

    /// The current temp basal (if any), finalized as having stopped at `endedAt`
    private func finalizedTempBasal(endedAt: Date) -> [NewPumpEvent] {
        guard state.basalDose.type == .tempBasal else {
            return []
        }

        return [NewPumpEvent.tempBasal(dose: state.basalDose.toDoseEntry(isMutable: false, endDate: endedAt))]
    }

    func emitReservoirLevel() {
        pumpDelegate.notify { delegate in
            delegate?.pumpManager(
                self,
                didReadReservoirValue: self.state.reservoir.rounded(toPlaces: 1),
                at: Date.now
            ) { result in
                switch result {
                case let .failure(error):
                    self.handlePumpDelegateError(method: "didReadReservoirValue", error)
                case .success:
                    break
                }
            }
        }
    }

    func emitPumpEvents(_ events: [NewPumpEvent], replacePendingEvents: Bool = true,
                        completion: ((Error?) -> Void)? = nil) {
        var events = events

        // With `replacePendingEvents` the host drops every mutable dose it holds.
        // Anything still in flight has to be in here, otherwise it disappears from
        // the host's history until we report it again later.
        if replacePendingEvents {
            if let bolusDose = state.bolusDose, !events.contains(where: { $0.type == .bolus }) {
                events.append(NewPumpEvent.bolus(unfinalizedDose: bolusDose, confirmedProgressOnly: state.bolusDeliveryUncertain || state.awaitingBolusReply))
            }

            if !events.contains(where: { $0.type == .tempBasal }) {
                events.append(contentsOf: runningTempBasal())
            }
        }

        pumpDelegate.notify { delegate in
            guard let delegate = delegate else {
                self.log.warning("No pump delegate, not notifying...")
                completion?(CocoaError(.fileWriteUnknown))
                return
            }

            delegate.pumpManager(
                self,
                hasNewPumpEvents: events,
                lastReconciliation: self.state.lastSync,
                replacePendingEvents: replacePendingEvents
            ) { error in
                if let error = error {
                    self.handlePumpDelegateError(method: "hasNewPumpEvents", error)
                }
                completion?(error)
            }
        }
    }
}
