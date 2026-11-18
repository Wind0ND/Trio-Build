//
//  CGMManager.swift
//  OttaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation
import HealthKit
@preconcurrency import LoopKit
import os.log
import UIKit

open class OttaiCGMManager: CGMManager, @unchecked Sendable {
    /// Id persisted in Trio's CGM selection. `open` so a variant that speaks a
    /// different account backend registers as its own manager instead of
    /// overwriting this one's device settings.
    open class var pluginIdentifier: String { "OttaiCGMManager" }
    open class var localizedTitle: String { "Ottai" }
    public static let healthKitStorageDelay: TimeInterval = 0

    /// Backend template an account session is rebuilt from. OttaiKit is a
    /// single-region driver: this is always the mainland service.
    open class var backendTemplate: OttaiBackend { .ottaiCnTemplate }

    public var localizedTitle: String { type(of: self).localizedTitle }
    public var pluginIdentifier: String { type(of: self).pluginIdentifier }

    /// Which service this account points at decides the product name, not which
    /// class Trio instantiated. Trio rebuilds the manager from persisted state, so
    /// the runtime class can be this parent even when the sensor is an Ottai M8
    /// on the mainland service; the session already knows the difference.
    public var usesCnService: Bool {
        account?.isOttaiCn ?? type(of: self).backendTemplate.isOttaiCn
    }

    public var brandTitle: String { usesCnService ? "Ottai M8" : localizedTitle }

    /// Model as the cloud reports it, falling back to the shipped name while
    /// `getBindDevice` has not answered yet.
    public var brandModel: String {
        usesCnService ? (state.sensors.current()?.deviceInfo.deviceType ?? "M8") : "X1"
    }

    public var brandArtwork: String { usesCnService ? "ottaiSensor" : "sensor" }
    public func markAsDepedency(_: Bool) {}

    public weak var cgmManagerDelegate: CGMManagerDelegate?
    public var delegateQueue: DispatchQueue!

    public internal(set) var state: OttaiCGMManagerState
    public var rawState: OttaiCGMManager.RawStateValue { state.rawValue }

    var monitor: OttaiSensorMonitor? {
        didSet { notifyStateObservers() }
    }

    /// A link to the sensor is up. On device that means a live monitor; the
    /// simulator build also counts its stand-in link.
    var hasLiveLink: Bool {
        #if targetEnvironment(simulator)
            return monitor != nil || simulatedLinkUp
        #else
            return monitor != nil
        #endif
    }

    #if targetEnvironment(simulator)
        var simulatedLinkUp = false { didSet { notifyStateObservers() } }
        var simulatedAccount = false
        var simulatedBound: OttaiBoundSensor?
        var simulationTimer: Timer?
    #endif

    internal let logger = OttaiLogger(category: "CgmManager")

    var sensorKit: OttaiBLE?
    var calibrationProvider: CalibrationProvider?
    var telemetryService: OttaiTelemetryService?

    public internal(set) var account: OttaiAccountSession? {
        didSet { notifyStateObservers() }
    }

    let sessionRecovery = OttaiSessionRecovery()

    public internal(set) var connectedAt: Date? { didSet { notifyStateObservers() } }
    var reconnectAttempt: Task<Void, Never>?
    private(set) var isDeleted = false

    var firingAlertConditions: Set<OttaiAlertCondition> = []

    var pendingBackfillFrom: UInt16?
    var pendingBackfillSamples: [NewGlucoseSample] = []
    var checkPriorityGridOnLiveFrame = false
    var priorityGridSequence: UInt16?
    var priorityGridTask: Task<Void, Never>?
    var lastPriorityGrid: (sequence: UInt16, date: Date)?

    /// Client-side data-plausibility engine. Lives manager-side so streaks survive
    /// BLE reconnects; only the latched `broken` verdict is persisted.
    var plausibilityGuard = OttaiPlausibilityGuard()

    public var latestSample: GlucoseSample? { state.latestSample }
    public private(set) var recentSamples: [GlucoseSample] {
        get {
            recentSamplesLock.lock()
            defer { recentSamplesLock.unlock() }
            return _recentSamples
        }
        set {
            recentSamplesLock.lock()
            _recentSamples = newValue
            recentSamplesLock.unlock()
        }
    }

    private var _recentSamples: [GlucoseSample] = []
    private let recentSamplesLock = NSLock()
    private static let recentSamplesCap = 100

    let stateObservers = OttaiWeakObserverSet<OttaiStateObserver>()

    public internal(set) var statusDetail: String? { didSet { notifyStateObservers() } }
    public func updateStatusDetail(_ text: String?) {
        if Thread.isMainThread { statusDetail = text }
        else { DispatchQueue.main.async { [weak self] in self?.statusDetail = text } }
    }

    var isReconnecting: Bool = false { didSet { notifyStateObservers() } }

    /// A connection attempt failed for a sensor the host app has never connected to.
    /// In-memory only: the first successful connection clears it.
    var firstConnectionFailed = false { didSet { notifyStateObservers() } }

    public enum ConnectionStatus: Equatable {
        case notPaired
        case connecting
        case connected
        case reconnecting
        case disconnected
    }

    public var connectionStatus: ConnectionStatus {
        guard state.mac != nil else { return .notPaired }
        if hasLiveLink { return .connected }
        return isReconnecting ? .reconnecting : .disconnected
    }

    /// Seconds since activation, from the sensor's own clock. The UI reads this
    /// rather than doing its own `Date()` arithmetic against `activatedAt`.
    public var sensorAge: TimeInterval? {
        OttaiSensorLifecycle.age(activatedAt: state.activatedAt, sensorAge: sensorAgeReading)
    }

    public var sensorExpirationDate: Date? {
        guard let activatedAt = state.activatedAt, let activeDuration = state.activeDuration else {
            return nil
        }
        // Report the window we actually enforce: the cloud duration plus the
        // user's extra days, so "Ends at" and the lifecycle agree.
        return activatedAt.addingTimeInterval(OttaiWearExtension.extendedWear(activeDuration))
    }

    public var sensorWarmupEndDate: Date? {
        guard let activatedAt = state.activatedAt, let preheatDuration = state.preheatDuration else {
            return nil
        }
        return activatedAt.addingTimeInterval(preheatDuration)
    }

    private var sensorAgeReading: (elapsed: TimeInterval, at: Date)? {
        state.latestElapsedSeconds.flatMap { elapsed in
            state.latestElapsedReceivedAt.map { (elapsed, $0) }
        }
    }

    public var sensorLifecycle: OttaiSensorLifecycle {
        OttaiSensorLifecycle.compute(
            sensorPaired: state.mac != nil,
            activatedAt: state.activatedAt,
            sensorAge: sensorAgeReading,
            latestReadingAt: state.latestReadingTimestamp,
            hasLiveMonitor: hasLiveLink,
            reportedFault: state.sensorFault,
            activeDuration: state.activeDuration,
            preheatDuration: state.preheatDuration
        )
    }

    public let isOnboarded = true
    public var appURL: URL? { nil }
    public var providesBLEHeartbeat: Bool { true }
    public var shouldSyncToRemoteService: Bool { true }
    public var managedDataInterval: TimeInterval? { nil }

    public var glucoseDisplay: GlucoseDisplayable? {
        guard let sample = state.latestSample else { return nil }
        guard abs(Date().timeIntervalSince(sample.date)) <= OttaiSensorLifecycle.signalLostThreshold else { return nil }
        return OttaiGlucoseDisplay(sample: sample)
    }

    public var inSignalLoss: Bool {
        guard state.mac != nil else { return false }
        return !hasLiveLink
    }

    public var isInoperable: Bool { state.sensorNeedsReplacement }

    public var inSensorWarmup: Bool {
        if case .warmup = sensorLifecycle { return true }
        return false
    }

    public var cgmManagerStatus: CGMManagerStatus {
        CGMManagerStatus(
            hasValidSensorSession: state.mac != nil && !state.sensorNeedsReplacement,
            inSensorWarmup: inSensorWarmup,
            isInoperable: isInoperable,
            lastCommunicationDate: state.latestReadingTimestamp,
            device: device
        )
    }

    public var device: HKDevice? {
        HKDevice(
            name: "Ottai CGM",
            manufacturer: "Ottai",
            model: usesCnService ? "M8" : "X1",
            hardwareVersion: nil,
            firmwareVersion: nil,
            softwareVersion: nil,
            localIdentifier: state.mac,
            udiDeviceIdentifier: nil
        )
    }

    public var debugDescription: String {
        """
        ## OttaiCGMManager
        * mac: \(OttaiRedact.mac(state.mac))
        * activatedAt: \(String(describing: state.activatedAt))
        * latestReadingTimestamp: \(String(describing: state.latestReadingTimestamp))
        """
    }

    public convenience init() {
        self.init(initialState: OttaiCGMManagerState())
    }

    public required convenience init?(rawState: OttaiCGMManager.RawStateValue) {
        self.init(initialState: OttaiCGMManagerState(rawValue: rawState) ?? OttaiCGMManagerState())

        if let pending = state.sensors.pendingBind {
            logger
                .warning(
                    "pending bind for \(OttaiRedact.mac(pending.mac)): the sensor was activated but its bind didn't complete. Re-run pairing for it to resume at the bind."
                )
        }
    }

    /// The stack (and with it the telemetry service, which snapshots the
    /// persisted upload queue) is wired exactly once, from the final state.
    /// Wiring from a blank state first would restore an empty queue.
    private init(initialState: OttaiCGMManagerState) {
        state = initialState
        recentSamples = initialState.recentSamples
        account = OttaiKeychain.loadAccount(namespace: type(of: self).pluginIdentifier)
        // A CN session stored before the userId fix carries no userId, so every
        // encrypted call would send an empty customerId and the server would keep
        // answering "no such sensor". Force one fresh sign-in instead of looping.
        if type(of: self).backendTemplate.isOttaiCn, let staleAccount = account, staleAccount.userId == nil {
            OttaiKeychain.deleteAccount(namespace: type(of: self).pluginIdentifier)
            account = nil
        }
        syncSensorHistoryFile()
        if state.mac != nil {
            wireStackForRestoreIfNeeded()
            Task { @MainActor in self.scheduleReconnect() }
        }
    }

    @MainActor func recordSample(_ sample: GlucoseSample) {
        recentSamplesLock.lock()
        // Newest-first by the reading's own timestamp, not by arrival: a
        // backfilled record is always ingested after the newer live sample that
        // triggered the request, so inserting by arrival would list it above
        // that sample and push a stale reading into the "latest" prefix.
        let insertionIndex = _recentSamples.firstIndex { $0.date <= sample.date } ?? _recentSamples.count
        _recentSamples.insert(sample, at: insertionIndex)
        if _recentSamples.count > Self.recentSamplesCap {
            _recentSamples.removeLast(_recentSamples.count - Self.recentSamplesCap)
        }
        let persistedPrefix = Array(_recentSamples.prefix(OttaiCGMManagerState.recentSamplesPersistenceCap))
        recentSamplesLock.unlock()
        var updated = state
        updated.recentSamples = persistedPrefix
        setState(updated)
    }

    @MainActor func recordForwardingOutcome(forSequence sequence: UInt16, wasForwarded: Bool, skipReason: String?) {
        recentSamplesLock.lock()
        guard let idx = _recentSamples.firstIndex(where: { $0.sequence == sequence }) else {
            recentSamplesLock.unlock()
            return
        }
        let updated = _recentSamples[idx].withForwardingOutcome(wasForwarded: wasForwarded, skipReason: skipReason)
        _recentSamples[idx] = updated
        let persistedPrefix = Array(_recentSamples.prefix(OttaiCGMManagerState.recentSamplesPersistenceCap))
        recentSamplesLock.unlock()
        var s = state
        s.recentSamples = persistedPrefix
        setState(s)
    }

    @MainActor public func applyCalibration(_ calibration: Calibration) {
        var updated = state
        updated.sensors.updateActiveCalibration(calibration)
        setState(updated)
    }

    @MainActor public func discardSensor() {
        cancelReconnect()
        logger.info("discard sensor: releasing BLE link (mac=\(OttaiRedact.mac(state.mac)))")

        monitor?.disconnect()
        monitor = nil
        #if targetEnvironment(simulator)
            stopSimulation()
        #endif
        isReconnecting = false
        recentSamples = []
        plausibilityGuard = OttaiPlausibilityGuard()
        pendingBackfillFrom = nil
        pendingBackfillSamples = []
        checkPriorityGridOnLiveFrame = false
        finishPriorityGridRequest(.cancelled)
        lastPriorityGrid = nil
        if let mac = state.mac {
            let event = PersistedCgmEvent(date: Date(), type: .sensorEnd, deviceIdentifier: mac)
            delegateQueue?.async { [weak self] in
                guard let self else { return }
                self.cgmManagerDelegate?.cgmManager(self, hasNew: [event])
            }
        }

        clearState()

        if let service = telemetryService {
            Task { await service.clearQueue() }
        }
    }

    @MainActor private func clearState() {
        var blank = state
        blank.sensors.discardActive()
        blank.resetSensorSession()
        setState(blank)
    }

    @MainActor public func delete() async {
        isDeleted = true
        cancelReconnect()
        logger.info("cgm delete: releasing BLE link")
        monitor?.disconnect()
        monitor = nil
        #if targetEnvironment(simulator)
            stopSimulation()
        #endif

        await cgmManagerDelegate?.cgmManagerWantsDeletion(self)
    }

    public func fetchNewDataIfNeeded(_ completion: @escaping (CGMReadingResult) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            if !self.hasLiveLink, self.state.mac != nil {
                self.scheduleReconnect()
            }

            self.evaluateAlerts()
        }
        completion(.noData)
    }

    public func acknowledgeAlert(alertIdentifier _: Alert.AlertIdentifier) async throws {}

    public func getSoundBaseURL() -> URL? { nil }
    public func getSounds() -> [Alert.Sound] { [] }

    private let statusObservers = WeakSynchronizedSet<CGMManagerStatusObserver>()
    public func addStatusObserver(_ observer: CGMManagerStatusObserver, queue: DispatchQueue) {
        statusObservers.insert(observer, queue: queue)
    }

    public func removeStatusObserver(_ observer: CGMManagerStatusObserver) {
        statusObservers.removeElement(observer)
    }

    private func notifyStatusObservers() {
        let status = cgmManagerStatus
        statusObservers.forEach { $0.cgmManager(self, didUpdate: status) }
    }

    private func syncSensorHistoryFile() {
        // Modern Ottai history first, then the one legacy record the persisted
        // activeMAC points at. The legacy file is never bulk-imported.
        let migrated = OttaiSensorHistoryStore.migrateActiveSensor(
            activeMAC: state.sensors.activeMAC,
            existing: OttaiSensorHistoryStore.load()
        )
        state.sensors.mergeHistory(migrated)
        OttaiSensorHistoryStore.save(state.sensors.records)
    }

    @MainActor func setState(_ newState: OttaiCGMManagerState) {
        if newState.sensors.records != state.sensors.records {
            OttaiSensorHistoryStore.save(newState.sensors.records)
        }
        state = newState
        delegateQueue?.async { [weak self] in
            guard let self else { return }
            self.cgmManagerDelegate?.cgmManagerDidUpdateState(self)
        }
        notifyStateObservers()
    }
}

struct OttaiGlucoseDisplay: GlucoseDisplayable {
    let sample: GlucoseSample
    var isStateValid: Bool { !sample.hasBlockingIssue }
    var isLocal: Bool { true }
    var glucoseRangeCategory: GlucoseRangeCategory? { nil }
    var trendType: GlucoseTrend? { Self.mapTrend(sample.trend) }

    static func mapTrend(_ trend: GlucoseSample.Trend) -> GlucoseTrend? {
        switch trend {
        case .notDetermined: return nil
        case .fallingQuickly: return .downDown
        case .falling: return .down
        case .stable: return .flat
        case .rising: return .up
        case .risingQuickly: return .upUp
        }
    }

    var trendRate: LoopQuantity? {
        sample.rateOfChangeMgDLPerMinute.map {
            LoopQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: $0)
        }
    }
}


public extension OttaiCGMManager {
    /// Sign in to the mainland service with a phone number and SMS code.
    ///
    /// `requestId` comes from `OttaiCnLoginProvider.requestCode`, which must be
    /// called first; the code the user receives is bound to it.
    func loginCn(phone: String, requestId: String, code: String) async throws {
        let provider = OttaiCnLoginProvider(phone: phone, requestId: requestId, code: code)
        let backend = try await provider.backend()
        let session = OttaiAccountSession(email: phone, backend: backend, password: nil)
        await MainActor.run { self.installSession(session) }
    }
}
