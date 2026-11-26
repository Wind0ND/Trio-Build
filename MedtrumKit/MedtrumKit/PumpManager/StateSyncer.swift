import Foundation
import LoopKit

enum StateSyncer {
    private static let logger = MedtrumLogger(category: "StateSyncer")

    static func sync(
        syncResponse: SynchronizePacketResponse,
        state: MedtrumPumpState,
        pumpManager: MedtrumPumpManager,
        duringReconnect: Bool,
        fullSync: Bool,
        recoveryQuery: MedtrumBasalSyncContext? = nil,
        legacyEvidence: [MedtrumBasalRecoveryLogEntry] = [],
        historyResolution: MedtrumBasalHistoryResolution? = nil
    ) {
        pumpManager.deliveryLock.lock()
        let priorShortIntent = state.shortTempBasal
        let priorPulseContinuation = state.basalPulseContinuation
        var recovered: (MedtrumBasalSyncContext, String)?
        var recoveryEvents: [NewPumpEvent] = []
        var confirmedRecoveryDose: UnfinalizedDose?
        var historyCommitRequired = false
        defer {
            let shortEnded = state.shortTempBasal == nil && state.shortTempBasalTransitionTime != nil
            let continuationStarted = state.basalPulseContinuation == nil && state.shortTempBasal?.pulseParentCommandID == priorPulseContinuation?.commandID
            pumpManager.deliveryLock.unlock()
            if let priorShortIntent, shortEnded {
                pumpManager.finishEndedShortTempBasal(priorShortIntent)
            }
            if let priorPulseContinuation, continuationStarted {
                pumpManager.finishEndedShortTempBasal(priorPulseContinuation)
            }
            if let recovered {
                if historyCommitRequired {
                    pumpManager.completeBasalHistoryRecovery(query: recovered.0, events: recoveryEvents,
                        reason: recovered.1, scheduledDose: confirmedRecoveryDose)
                } else {
                    pumpManager.completeBasalRecovery(query: recovered.0, events: recoveryEvents, reason: recovered.1,
                        confirmedDose: confirmedRecoveryDose)
                }
            }
        }
        let syncDate = Date.now
        if let recoveryQuery, !recoveryQuery.matches(pumpManager) {
            logger.warning("Ignoring a status query superseded by a delivery command or session change")
            return
        }
        if syncResponse.invalidPayload || syncResponse.truncated || syncResponse.state == .none ||
            syncResponse.basal?.type == .NONE {
            pumpManager.invalidateBasalObservation()
        }

        // Checked on the payload as received: a rebooted base reports a new patch id, and validation
        // would strip exactly the fields that tell a reset apart - and when it happened
        switch baseResetCheck(syncResponse: syncResponse, state: state) {
        case .reset:
            guard !pumpManager.isDeactivatingPatch else {
                break
            }

            // Nothing else in this payload describes the patch we knew
            pumpManager.handleBaseReset(
                deliveryStoppedAt: deliveryStoppedAt(syncResponse: syncResponse, state: state, receivedAt: syncDate)
            )
            return

        case .unconfirmed:
            // `.none` is also what an unknown state byte parses to, don't drop an activated patch over it
            logger.warning("Activated patch reported state none without a new patch id, ignoring")
            return

        case .noReset:
            break
        }

        // Activation ACK supplies a host estimate. Establish its native timestamp once,
        // only without any pending/uncertain delivery; this packet never resolves a request.
        if fullSync, state.patchActivationIsProvisional || state.patchActivatedAt == nil,
           !state.patchSessionEnded, !syncResponse.invalidPayload, !syncResponse.truncated,
           syncResponse.state.isRunning, let incomingStart = syncResponse.startTime,
           let storage = syncResponse.storage, let basal = syncResponse.basal,
           storage.patchId == basal.patchId, storage.patchId.isFinite, storage.patchId > 0,
           storage.patchId.rounded() == storage.patchId, storage.patchId <= Double(UInt32.max),
           (storage.patchId == Double(state.patchId.toUInt64()) ||
            (state.patchId.isEmpty && UInt64(storage.patchId).toData(length: 4) != state.previousPatch?.patchId)),
           state.pendingTempBasal == nil, !state.basalDeliveryUncertain, !state.bolusDeliveryUncertain,
           !state.awaitingBasalReply, !state.awaitingBolusReply, !pumpManager.submittingDelivery,
           state.shortTempBasal == nil {
            state.patchActivatedAt = incomingStart
            state.patchActivationIsProvisional = false
            state.patchId = UInt64(storage.patchId).toData(length: 4)
            pumpManager.invalidateBasalObservation()
            pumpManager.notifyStateDidChange()
            return
        }
        if let knownStart = state.patchActivatedAt, let incomingStart = syncResponse.startTime,
           !state.patchSessionEnded, !state.pumpState.isSetup, incomingStart != knownStart {
            pumpManager.invalidateBasalObservation()
            logger.warning("Ignoring a status packet with a conflicting patch activation")
            return
        }
        let verifiedQuery = fullSync && recoveryQuery != nil &&
            basalRecoverySessionIsCurrent(syncResponse, state: state) &&
            syncDate.timeIntervalSince(recoveryQuery!.startedAt) >= 0 &&
            syncDate.timeIntervalSince(recoveryQuery!.startedAt) <= MedtrumPumpManager.loopSyncFreshnessInterval
        if fullSync, recoveryQuery != nil, !verifiedQuery {
            pumpManager.invalidateBasalObservation()
            logger.warning("Status query did not establish a current-session observation")
            // A verified halt must still update suspend/accounting and alerts. It cannot
            // provide fresh delivery data or clear an uncertain request.
            guard syncResponse.state.isDeliveryHalted,
                  basalRecoverySessionIsCurrent(syncResponse, state: state, requiresDelivery: false) else { return }
        }

        // No session: the id kept can be stale - the previous patch's, or one never started - and would reject the new
        // patch's payloads. The storage gate below decides which id to keep then.
        let expectedPatchId = state.patchSessionEnded ? 0 : state.patchId.toUInt64()
        let syncResponse = syncResponse.validated(expectedPatchId: expectedPatchId)
        if syncResponse.invalidPayload { pumpManager.invalidateBasalObservation() }

        StateSyncer.updatePumpState(syncResponse: syncResponse, pumpManager: pumpManager)

        let hasActivatedPatch = syncResponse.state.rawValue >= PatchState.active.rawValue

        if let reservoir = syncResponse.reservoir {
            if hasActivatedPatch,
               let lowReservoirWarning = state.lowReservoirWarning,
               state.reservoir > lowReservoirWarning,
               reservoir < lowReservoirWarning
            {
                // Send low reservoir warning notification to user
                pumpManager.emitAlert(alertType: .lowReservoir(level: reservoir))
            }

            if state.reservoir != reservoir {
                state.reservoir = reservoir

                if fullSync, hasActivatedPatch {
                    // to prevent spaming the OSAID app with reservoir updates
                    pumpManager.emitReservoirLevel()
                }
            }

            if hasActivatedPatch, state.initialReservoir == nil {
                state.initialReservoir = reservoir
            }
        }

        var events: [NewPumpEvent] = []
        if verifiedQuery, let basal = syncResponse.basal, let query = recoveryQuery {
            pumpManager.verifiedBasalBaseline = MedtrumBasalRecoveryBaseline(segment: basal,
                sessionID: state.patchId, sessionStartedAt: state.patchActivatedAt!, observedAt: query.startedAt)
            pumpManager.verifiedPumpObservation = MedtrumVerifiedPumpObservation(sessionID: state.patchId,
                sessionStart: state.patchActivatedAt!, date: query.startedAt)
        }
        var allowBasalUpdate = state.shortTempBasal == nil
        let pendingShortCommand = state.pendingTempBasal?.decisionId
        if !syncResponse.invalidPayload, !syncResponse.truncated, let basal = syncResponse.basal {
            pumpManager.shortTempBasalObservedSegment = basal
            if fullSync { pumpManager.shortTempBasalLastVerifiedSync = syncDate }
            allowBasalUpdate = reconcileShortTempBasal(state: state, basal: basal, observedAt: syncDate, fullSync: fullSync)
            if let pendingShortCommand, state.pendingTempBasal == nil,
               state.shortTempBasal?.commandID == pendingShortCommand, state.basalDose.type == .tempBasal {
                events.append(NewPumpEvent.tempBasal(dose: state.basalDose.toDoseEntry(isMutable: true)))
            }
        }
        if allowBasalUpdate, fullSync, !syncResponse.invalidPayload, !syncResponse.truncated,
           state.basalDeliveryUncertain, let basal = syncResponse.basal,
           let query = recoveryQuery, verifiedQuery, query.canRecover, query.matches(pumpManager),
           !pumpManager.basalRecoveryInProgress {
            if let requested = state.pendingTempBasal {
                if let history = historyResolution,
                   history.pending == MedtrumPendingBasalSignature(requested),
                   history.activation == state.patchActivatedAt,
                   history.serial == Data(state.pumpSN.reversed()).toUInt64(),
                   MedtrumBasalHistoryResolution.sameSegment(history.current, basal) {
                    if history.executed != nil, let event = history.event(for: requested), let offset = history.clockOffset {
                        events.append(event)
                        let scheduled = UnfinalizedDose(basalRate: basal.rate, insulinType: state.insulinType,
                            startDate: basal.startTime.addingTimeInterval(-offset))
                        events.append(NewPumpEvent.basal(dose: scheduled.toDoseEntry()))
                        confirmedRecoveryDose = scheduled
                        historyCommitRequired = true
                    }
                    recovered = (query, history.executed == nil ? "native_history_no_new_temp" : "native_history_confirmed_temp")
                    pumpManager.basalRecoveryInProgress = true
                } else if let confirmed = confirmedTempBasal(requested, basal: basal, observedAt: syncDate) {
                    confirmedRecoveryDose = confirmed
                    events.append(NewPumpEvent.tempBasal(dose: confirmed.toDoseEntry(isMutable: true)))
                    recovered = (query, "confirmed_native_temp_segment")
                    pumpManager.basalRecoveryInProgress = true
                } else if let reason = unstartedAutomaticBasalReason(state: state, response: syncResponse, now: syncDate,
                    evidence: legacyEvidence, deviceIdentifier: pumpManager.logDeviceIdentifier) {
                    recovered = (query, reason)
                    pumpManager.basalRecoveryInProgress = true
                } else if !pumpManager.basalRecoveryBlockReported {
                    pumpManager.basalRecoveryBlockReported = true
                    logger.warning("Basal recovery blocked: native evidence is insufficient; pending delivery remains protected")
                    NotificationCenter.default.post(name: Notification.Name("com.trio.diagnostics.event"), object: nil,
                        userInfo: ["schema": 1, "feature": "medtrum", "stage": "basal_recovery", "outcome": "blocked"])
                }
            } else if basal.type == .STANDARD || basal.type.isSuspendedByPump() ||
                (basal.type == .ABSOLUTE_TEMP && state.basalDose.type == .tempBasal &&
                    (basal.rate * 20).rounded() == (state.basalDose.value * 20).rounded()) {
                // After an uncertain cancellation, a full status describes whether the known temp is still running.
                state.basalDeliveryUncertain = false
            }
        }
        if allowBasalUpdate, syncResponse.state.isDeliveryHalted {
            // a halted state is authoritative even when the notification carries a cached basal.
            events.append(contentsOf: recordSuspendIfDelivering(
                state: state, basal: syncResponse.basal, receivedAt: syncDate
            ))
            state.basalState = .suspended
        } else if allowBasalUpdate, let basal = syncResponse.basal {
            switch basal.type {
            case .ABSOLUTE_TEMP,
                 .RELATIVE_TEMP:
                state.basalState = .tempBasal

            case .STOP,
                 .STOP_BASE_FAULT,
                 .STOP_BATTERY_EMPTY,
                 .STOP_DISCARD,
                 .STOP_EMPTY,
                 .STOP_EXPIRED,
                 .STOP_OCCLUSION,
                 .STOP_PATCH_FAULT,
                 .STOP_PATCH_FAULT2,
                 .SUSPEND_AUTO,
                 .SUSPEND_KEY_LOST,
                 .SUSPEND_LOW_GLUCOSE,
                 .SUSPEND_MANUAL,
                 .SUSPEND_MORE_THAN_MAX_PER_DAY,
                 .SUSPEND_MORE_THAN_MAX_PER_HOUR,
                 .SUSPEND_PREDICT_LOW_GLUCOSE:
                events.append(contentsOf: recordSuspendIfDelivering(
                    state: state, basal: basal, receivedAt: syncDate
                ))
                state.basalState = .suspended

            default:
                // The patch is delivering on its schedule again
                let eventTime = state.shortTempBasalTransitionTime ?? syncDate

                switch state.basalDose.type {
                case .tempBasal:
                    // A temp basal was running - finalize it, and go back to scheduled basal
                    let finishedTempBasal = state.basalDose.toDoseEntry(isMutable: false, endDate: eventTime)
                    state.basalDose = UnfinalizedDose(
                        basalRate: state.currentBaseBasalRate,
                        insulinType: state.insulinType,
                        startDate: eventTime
                    )

                    events.append(NewPumpEvent.basal(dose: state.basalDose.toDoseEntry()))
                    // Record finalized temp basal, the scheduled basal above is already finalized
                    events.append(NewPumpEvent.tempBasal(dose: finishedTempBasal))

                case .suspend:
                    // Delivery was suspended - report the resume. The suspend is already finalized.
                    state.basalDose = UnfinalizedDose(
                        resumeStartTime: eventTime,
                        insulinType: state.insulinType
                    )

                    events.append(NewPumpEvent.resume(dose: state.basalDose.toDoseEntry()))

                default:
                    break
                }

                state.basalState = .active
            }
        }

        if let prime = syncResponse.primeProgress {
            state.primeProgress = prime
        }

        if let battery = syncResponse.battery {
            state.battery = battery.voltageB
        }

        // An age/start-time field without a same-payload ID cannot be attributed after a patch change.
        let expectedID = Double(state.patchId.toUInt64())
        let provenSession = !state.patchId.isEmpty &&
            (syncResponse.storage?.patchId == expectedID || syncResponse.basal?.patchId == expectedID)
        if provenSession, state.patchActivatedAt == nil, let startTime = syncResponse.startTime {
            state.patchActivatedAt = startTime
        }

        if let storage = syncResponse.storage {
            // No session: the old patch can report its id until it disconnects. A running patch with another id is the new
            // one, its session not started.
            let patchId = UInt64(storage.patchId).toData(length: 4)
            if !state.patchSessionEnded || (syncResponse.state.isRunning && patchId != state.previousPatch?.patchId) {
                state.patchId = patchId
            }
        }

        if provenSession, !syncResponse.invalidPayload, !syncResponse.truncated, !state.patchSessionEnded,
           let age = syncResponse.patchAge {
            state.extendedLifePolicy.observe(age: TimeInterval(age), sessionID: state.patchId, at: syncDate)
        }

        if let bolusProgress = syncResponse.bolus {
            pumpManager.updateBolusProgress(
                delivered: bolusProgress.delivered,
                completed: bolusProgress.completed,
                useEstimatedEndDate: duringReconnect
            )
        } else if duringReconnect {
            pumpManager.checkBolusDone()
        }

        if (fullSync && !syncResponse.invalidPayload && !syncResponse.truncated && syncResponse.basal != nil) || !events.isEmpty {
            pumpManager.state.lastSync = syncDate
            if recovered == nil { pumpManager.emitPumpEvents(events) }
            else { recoveryEvents = events }
        }

        if recovered == nil { pumpManager.notifyStateDidChange() }
        if !syncResponse.invalidPayload, !syncResponse.truncated, state.shortTempBasal != nil {
            DispatchQueue.global(qos: .utility).async { [weak pumpManager] in
                pumpManager?.serviceShortTempBasalDeadline()
            }
        }
    }

    /// Recover the requested duration only when a fresh patch segment matches its start and rate.
    static func confirmedTempBasal(_ request: UnfinalizedDose, basal: BasalData, observedAt: Date) -> UnfinalizedDose? {
        guard basal.type == .ABSOLUTE_TEMP, (basal.rate * 20).rounded() == (request.value * 20).rounded(),
              basal.startTime.timeIntervalSince1970 >= floor(request.startDate.timeIntervalSince1970),
              basal.startTime <= observedAt, basal.startTime < request.estimatedEndDate
        else { return nil }
        let duration = request.estimatedEndDate.timeIntervalSince(request.startDate)
        return UnfinalizedDose(decisionId: request.decisionId, tempRate: basal.rate, duration: duration,
                               insulinType: request.insulinType, automatic: request.automatic, startDate: basal.startTime)
    }

    private static func recordSuspendIfDelivering(
        state: MedtrumPumpState,
        basal: BasalData?,
        receivedAt: Date
    ) -> [NewPumpEvent] {
        guard state.basalDose.type == .basal || state.basalDose.type == .resume || state.basalDose.type == .tempBasal
        else {
            return []
        }

        var events: [NewPumpEvent] = []
        // accurate time would require pump-history reconciliation
        let eventTime: Date
        if let transition = state.shortTempBasalTransitionTime {
            eventTime = transition
        } else if let basal = basal,
           basal.type.isSuspendedByPump(),
           basal.startTime >= state.basalDose.startDate,
           basal.startTime <= receivedAt
        {
            eventTime = basal.startTime
        } else {
            eventTime = receivedAt
        }
        let dose = state.basalDose.toDoseEntry(isMutable: false, endDate: eventTime)
        state.basalDose = UnfinalizedDose(suspendStartTime: eventTime)

        events.append(NewPumpEvent.suspend(dose: state.basalDose.toDoseEntry()))
        if dose.type == .tempBasal {
            events.append(NewPumpEvent.tempBasal(dose: dose))
        }

        return events
    }

    enum BaseResetCheck {
        case noReset
        case reset
        case unconfirmed
    }

    /// An activated patch never goes back to a setup state on its own: when it does, the base has
    /// rebooted and came back as a blank patch - with a new patch id, its age and sequence restarted,
    /// and no delivery.
    static func baseResetCheck(syncResponse: SynchronizePacketResponse, state: MedtrumPumpState) -> BaseResetCheck {
        // No session: the old patch, stopped, is still reported until the new one is set up - that setup is no reset
        guard !state.pumpState.isSetup, syncResponse.state.isSetup,
              !(state.patchSessionEnded && state.pumpState.isTerminated)
        else {
            return .noReset
        }

        guard syncResponse.state == .none else {
            return .reset
        }

        guard let storage = syncResponse.storage, !state.patchId.isEmpty else {
            return .unconfirmed
        }

        return UInt64(storage.patchId) != state.patchId.toUInt64() ? .reset : .unconfirmed
    }

    /// The base counts the patch age from its boot, which is when delivery stopped - unless we have
    /// heard from the activated patch after that
    static func deliveryStoppedAt(
        syncResponse: SynchronizePacketResponse,
        state: MedtrumPumpState,
        receivedAt: Date
    ) -> Date {
        guard let patchAge = syncResponse.patchAge else {
            return receivedAt
        }

        let bootedAt = receivedAt.addingTimeInterval(-TimeInterval(patchAge))
        return min(max(bootedAt, state.lastSync), receivedAt)
    }

    public static func fetchPatchTimeIfStale(pumpManager: MedtrumPumpManager) {
        let age = Date.now.timeIntervalSince(pumpManager.state.pumpTimeSyncedAt)
        guard age > MedtrumPumpManager.patchTimeRefreshInterval else {
            return
        }

        fetchPatchTime(pumpManager: pumpManager)
    }

    public static func fetchPatchTime(pumpManager: MedtrumPumpManager) {
        let started = Date()
        let session = pumpManager.deliveryLock.withLock { (pumpManager.state.patchId, pumpManager.state.patchActivatedAt) }
        let timeData = pumpManager.bluetooth.write(GetTimePacket())

        switch timeData {
        case let .failure(error: error):
            logger.warning("Failed to get current Patch time: \(error.errorDescription)")
            return
        case let .success(data: data):
            guard let timeResponse = data as? GetTimePacketResponse else {
                logger.error("Failed to get time: invalid response")
                return
            }

            pumpManager.state.pumpTime = timeResponse.time
            pumpManager.state.pumpTimeSyncedAt = Date.now
            pumpManager.deliveryLock.withLock {
                let ended = Date()
                if let activation = session.1, !pumpManager.state.patchSessionEnded,
                   session.0 == pumpManager.state.patchId, activation == pumpManager.state.patchActivatedAt,
                   ended.timeIntervalSince(started) >= 0, ended.timeIntervalSince(started) <= 1 {
                    let offset = timeResponse.time.timeIntervalSince(ended).rounded()
                    pumpManager.verifiedClockMapping = abs(offset) <= 120 ? MedtrumFrozenClockMapping(
                        sessionID: session.0, activation: activation, sampledAt: ended, offset: offset) : nil
                } else { pumpManager.verifiedClockMapping = nil }
            }
            pumpManager.notifyStateDidChange()
        }
    }

    public static func syncTime(pumpManager: MedtrumPumpManager) {
        pumpManager.deliveryLock.withLock { pumpManager.verifiedClockMapping = nil }
        let timeData = pumpManager.bluetooth.write(SetTimePacket(date: Date.now))
        switch timeData {
        case let .failure(error: error):
            logger.error("Failed to sync time: \(error.errorDescription)")
            return
        default:
            break
        }

        let timeZoneData = pumpManager.bluetooth.write(
            SetTimeZonePacket(date: Date.now, timeZone: TimeZone.current)
        )
        switch timeZoneData {
        case let .failure(error: error):
            logger.error("Failed to sync timezone: \(error.errorDescription)")
            return
        default:
            StateSyncer.fetchPatchTime(pumpManager: pumpManager)
        }
    }

    private static func updatePumpState(syncResponse: SynchronizePacketResponse, pumpManager: MedtrumPumpManager) {
        let previousState = pumpManager.state.pumpState
        pumpManager.state.pumpState = syncResponse.state

        guard syncResponse.state != previousState else {
            return
        }

        // Send notification for specific states
        switch syncResponse.state {
        case .dailyMaxSuspended:
            pumpManager.emitAlert(alertType: .patchDailyMaxNotification)
        case .hourlyMaxSuspended:
            pumpManager.emitAlert(alertType: .patchHourlyMaxNotification)
        case .occlusion:
            pumpManager.emitAlert(alertType: .occlusionNotification)
        case .baseFault,
             .patchFault,
             .patchFaultd2:
            pumpManager.emitAlert(alertType: .patchFaultNotification)
        case .reservoirEmpty:
            pumpManager.emitAlert(alertType: .reservoirEmptyNotification)
        default:
            break
        }
    }
}
