//
//  CGMManager+Ingest.swift
//  OttaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation
@preconcurrency import LoopKit

extension OttaiCGMManager {
    @MainActor func ingest(_ sample: GlucoseSample) {
        if sample.source == .realtime { OttaiDiagnosticEvent.recordPipeline(.transport, .received) }
        // A live reading is proof the sensor is running. A fault latched from a
        // pre-stream cmd-state readout must not outlive it, or the sensor stays
        // "uninitialized" forever and every later reading is dropped on the
        // doorstep.
        if state.sensorNeedsReplacement, sample.source == .realtime,
           case .deviceStateUnactivated? = state.sensorFault, state.activatedAt != nil
        {
            logger.info("clearing a stale unactivated fault: the sensor is streaming")
            var healed = state
            healed.sensorFault = nil
            setState(healed)
        }

        if state.sensorNeedsReplacement {
            logger.debug("sensor marked for replacement; dropping seq=\(sample.sequence) (\(Int(sample.valueMgDL)) mg/dL)")
            return
        }

        var sample = sample
        // The frame's arrival instant, captured before `date` is replaced by
        // sensor time. The only thing it is ever used for is spanning the
        // silence since the sensor last spoke; it never dates a reading.
        let receivedAt = sample.date

        // `activatedAt` is normally exact already: captured once, at the
        // moment the activation write reset the sensor's RTC to 0
        // (`OttaiPairingService.swift`), and persisted from then on — nothing
        // needs to re-derive it in the common case. This only fills it in if
        // it's somehow missing, using a realtime frame's own wall-clock
        // receipt time and elapsed-seconds field; backfilled frames' receipt
        // time is "when we requested history", not "when the reading was
        // taken", so it must never feed this.
        var activatedAt = state.activatedAt
        if activatedAt == nil, sample.source == .realtime, let elapsedSeconds = sample.elapsedSeconds {
            activatedAt = sample.date.addingTimeInterval(-elapsedSeconds)
        }

        // A mis-decoded frame carries its sequence and its elapsed counter from
        // unrelated bytes: the 2026-11-18 logs show frames claiming seq=17935 and
        // seq=53982 with counters months ahead, which dated a reading 2026-11-23 —
        // five days into the future. Trio keeps the newest reading by date, so one
        // such row froze the home screen on itself for hours. A live frame can
        // never run ahead of the wall clock since activation.
        if sample.source == .realtime, let elapsedSeconds = sample.elapsedSeconds, let activatedAt {
            let wallAge = Date().timeIntervalSince(activatedAt)
            let projected = activatedAt.addingTimeInterval(elapsedSeconds)
            // A live frame describes "now", so anything dated ahead of the clock is garbage
            // outright; the six-hour slack only guards the (harmless) case of a counter that
            // runs slightly ahead of the wall clock.
            if elapsedSeconds > wallAge + 6 * 3600 || projected > Date().addingTimeInterval(120) {
                logger.info(
                    "dropping a mis-decoded live frame: seq=\(sample.sequence) elapsed=\(Int(elapsedSeconds))s wall=\(Int(wallAge))s value=\(Int(sample.valueMgDL)) mg/dL"
                )
                return
            }
        }

        let sensorElapsed = sample.elapsedSeconds
        if let elapsedSeconds = sample.elapsedSeconds, let activatedAt {
            var trueDate = activatedAt.addingTimeInterval(elapsedSeconds)
            if sample.source == .realtime, trueDate < Date().addingTimeInterval(-30 * 60) {
                // Recover the timestamp only when the independent minute index agrees with
                // receipt time. A replayed or mis-sliced frame cannot be made fresh by arrival.
                let indexedDate = activatedAt.addingTimeInterval((Double(sample.sequence) + 1) * 60)
                guard indexedDate <= receivedAt, receivedAt.timeIntervalSince(indexedDate) <= 120 else {
                    logger.info("withheld live frame with inconsistent sensor clocks: seq=\(sample.sequence)")
                    return
                }
                trueDate = indexedDate
            }
            sample = GlucoseSample(
                date: trueDate, valueMgDL: sample.valueMgDL, trend: sample.trend,
                rateOfChangeMgDLPerMinute: sample.rateOfChangeMgDLPerMinute,
                sequence: sample.sequence, rawBaseMgDL: sample.rawBaseMgDL,
                rawCurrent: sample.rawCurrent, elapsedSeconds: elapsedSeconds,
                condition: sample.condition, hasBlockingIssue: sample.hasBlockingIssue,
                source: sample.source
            )
        }

        let isWarmupReading = Self.isWarmup(
            elapsedSeconds: sample.elapsedSeconds,
            preheatDuration: state.preheatDuration
        )
        // Two clocks must agree before a reading is thrown away as past wear.
        // The sensor's own elapsed counter dates a reading, but a reconnect can
        // hand back a counter from a different base, and a counter that is months
        // ahead would silently drop every live reading while painting the sensor
        // as expired. Wall-clock age against the activation record is the second
        // opinion.
        let wallPastWear: Bool
        if let activatedAt = state.activatedAt,
           let wear = state.activeDuration.map(OttaiWearExtension.extendedWear)
        {
            wallPastWear = Date().timeIntervalSince(activatedAt) >= wear
        } else {
            wallPastWear = false
        }
        let isExpiredReading = wallPastWear && Self.isPastWear(
            elapsedSeconds: sample.elapsedSeconds,
            activeDuration: state.activeDuration
        )
        if !isWarmupReading, !isExpiredReading { recordSample(sample) }

        let previousGridSequence = state.lastGridSequence
        var updated = state

        // Never move the freshness marker backwards for an old backfilled
        // record. Ordered by the sensor's elapsed field rather than by the
        // dates themselves, so nothing here depends on the phone's clock or on
        // `activatedAt` being right.
        // Only a live record can be the newest one, and it updates both halves
        // of the pair together: an elapsed value paired with a receipt instant
        // from a different frame would misstate the age by the difference.
        if sample.source == .realtime,
           let elapsedSeconds = sample.elapsedSeconds,
           elapsedSeconds >= (updated.latestElapsedSeconds ?? -1)
        {
            updated.latestReadingTimestamp = sample.date
            updated.latestElapsedSeconds = elapsedSeconds
            updated.latestElapsedReceivedAt = receivedAt
        }

        if state.activatedAt == nil, let activatedAt {
            updated.sensors.setActivatedAt(activatedAt)
        }
        setState(updated)
        notifyStateObservers()

        updateStatusDetail(nil)

        if isWarmupReading {
            logger.debug("preheat: \(Int(sample.valueMgDL)) mg/dL seq=\(sample.sequence); not forwarding")
            return
        }

        // The sensor keeps streaming past the end of its wear window; those
        // records are beyond what the calibration covers, so like warmup they
        // are dropped here rather than shown or dosed on. The freshness
        // markers above still advance, so a chatty dead sensor doesn't read
        // as signal loss.
        if isExpiredReading {
            logger.debug("past wear: \(Int(sample.valueMgDL)) mg/dL seq=\(sample.sequence); not forwarding")
            return
        }

        // Treatment availability is bounded by the manufacturer's timing on both clocks.
        // A display extension, a stale counter, or missing metadata cannot extend it.
        guard Self.acceptsForHost(
            elapsed: sensorElapsed, wallAge: state.activatedAt.map { receivedAt.timeIntervalSince($0) },
            warmup: state.preheatDuration, ratedWear: state.activeDuration
        ) else {
            recordForwardingOutcome(forSequence: sample.sequence, wasForwarded: false, skipReason: "Outside verified sensor wear")
            return
        }

        if sample.hasBlockingIssue {
            logger.debug("blocking issue: \(Int(sample.valueMgDL)) mg/dL seq=\(sample.sequence); not forwarding")
            recordForwardingOutcome(
                forSequence: sample.sequence,
                wasForwarded: false,
                skipReason: "Sensor reported fault"
            )
            return
        }

        // Data-plausibility guard (fed post-warmup samples only). `attention`
        // suppresses forwarding while it holds; `broken` latches the sensor as
        // failed, persisted, with no destructive action.
        if let rawCurrent = sample.rawCurrent {
            if let event = plausibilityGuard.record(
                sequence: sample.sequence,
                current: rawCurrent,
                glucoseMmolL: sample.rawBaseMgDL / OttaiGlucoseDecoder.mmolToMgDL
            ) {
                switch event.level {
                case .attention:
                    logger
                        .warning(
                            "implausible data streak (\(event.reason.rawValue)) at seq=\(sample.sequence); suppressing forwarding while it holds"
                        )
                case .broken:
                    logger
                        .error(
                            "implausible data broken tier (\(event.reason.rawValue)) at seq=\(sample.sequence); declaring sensor failed"
                        )
                    markSensorFailed(OttaiSensorFault(kind: .signalImplausible, raw: Data(), receivedAt: sample.date))
                }
            }
        }
        if state.sensorFault != nil {
            recordForwardingOutcome(
                forSequence: sample.sequence,
                wasForwarded: false,
                skipReason: "Sensor declared failed (implausible data)"
            )
            return
        }
        if plausibilityGuard.attentionActive {
            updateStatusDetail(LocalizedString(
                "Sensor data looks wrong, readings paused — if this persists, replace the sensor",
                comment: "Status: implausible data streak"
            ))
            recordForwardingOutcome(
                forSequence: sample.sequence,
                wasForwarded: false,
                skipReason: "Implausible data streak"
            )
            return
        }

        if sample.source == .realtime {
            if Self.isOnForwardGrid(sequence: sample.sequence), let preheat = state.preheatDuration {
                var received = state
                received.observeGrid(sample.sequence, firstUsable: Self.firstBackfillableSequence(preheatDuration: preheat))
                if received != state { setState(received) }
            }
            // A still-connected link can miss a grid point too. Each valid live wake may repair it.
            Foundation.NotificationCenter.default.post(name: .init("com.trio.cgm.sourceActivity"), object: nil)
            firePendingBackfill(newest: sample.sequence, previousGridSequence: previousGridSequence)
        }

        // The sensor pushes every minute; Loop doses on a 5-minute cadence.
        // Which readings get forwarded is decided entirely by the sensor's own
        // counter — every 5th record, live or backfilled, no wall-clock
        // comparison anywhere — for the same reason `date` comes from the
        // sensor's elapsed-seconds field: receipt times drift with BLE latency
        // and reconnect churn, the sequence doesn't. One grid shared by both
        // sources is what stops them landing a minute apart or out of order,
        // and every point on it clears stock Trio's 3.5-min backfill dedupe.
        guard Self.isOnForwardGrid(sequence: sample.sequence) else {
            logger.debug("not forwarding \(Int(sample.valueMgDL)) mg/dL seq=\(sample.sequence): off the 5-min grid")
            recordForwardingOutcome(
                forSequence: sample.sequence,
                wasForwarded: false,
                skipReason: "不在 5 分钟网格上"
            )
            return
        }

        // The ordinary history walk may pass the point already submitted by
        // the priority request. Leave the older cursor intact, but submit that
        // exact sample only once.
        if sample.source == .historicalBackfill,
           !state.pendingHistoryGrid.contains(sample.sequence),
           let lastPriorityGrid, lastPriorityGrid.sequence == sample.sequence, lastPriorityGrid.date == sample.date
        {
            recordForwardingOutcome(forSequence: sample.sequence, wasForwarded: true, skipReason: nil)
            return
        }

        let loopCondition: GlucoseCondition?
        switch sample.condition {
        case .belowRange?: loopCondition = .belowRange
        case .aboveRange?: loopCondition = .aboveRange
        case nil: loopCondition = nil
        }

        let newSample = NewGlucoseSample(
            date: sample.date,
            quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: sample.valueMgDL),
            condition: loopCondition,
            trend: Self.mapTrend(sample.trend),
            trendRate: sample.rateOfChangeMgDLPerMinute.map {
                LoopQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: $0)
            },
            isDisplayOnly: false,
            wasUserEntered: false,
            syncIdentifier: "syai-\(state.mac ?? "unknown")-\(sample.sequence)",
            syncVersion: 1,
            device: device
        )

        logger.debug("forwarding to Loop: \(Int(sample.valueMgDL)) mg/dL seq=\(sample.sequence)")

        // Presence only, never the value, and only after a live sample actually
        // passes every forwarding gate. `latestSample` is cleared on attach and
        // set only by forwarded live samples, so this is once per new sensor;
        // warmup/backfill/off-grid frames cannot trigger or repeat it.
        let isFirstForwardedLiveSample = sample.source != .historicalBackfill && state.latestSample == nil

        var stamped = state

        if sample.source != .historicalBackfill {
            stamped.latestSample = sample.withForwardingOutcome(wasForwarded: true, skipReason: nil)
        }
        setState(stamped)
        recordForwardingOutcome(forSequence: sample.sequence, wasForwarded: true, skipReason: nil)
        if isFirstForwardedLiveSample {
            OttaiDiagnosticEvent.record(.firstReading, .present)
        }

        if sample.source == .historicalBackfill {
            if !submitPriorityGridIfReady(sample, newSample: newSample) {
                pendingBackfillSamples.append(newSample)
            }
        } else {
            flushPendingBackfill()
            submitGridSamples([newSample])
        }
    }

    /// Whether a sample sits on the 5-minute forwarding grid (LibreLoop's
    /// `lifeCount % 5` pattern, so no Trio-side patch is needed). The sequence
    /// ticks exactly 1/min from activation, so `% 5` is a 5-min grid fixed by
    /// the sensor itself — the same grid for live and backfilled readings,
    /// which is what keeps the two sources from interleaving. Stock Trio
    /// dedupes incoming backfill against any stored point within 3.5 min, and
    /// every point on this grid clears that window.
    static func isOnForwardGrid(sequence: UInt16) -> Bool {
        sequence % forwardGridStep == 0
    }

    /// One forwarded reading per this many sensor records (1 record = 1 min).
    static let forwardGridStep: UInt16 = 5

    /// Whether a reading was taken during warmup, judged by the sensor's own
    /// elapsed-seconds field rather than `date - activatedAt`: same answer when
    /// the anchor is right, independent of it when it isn't.
    ///
    /// Deliberately not expressed as a sequence range. The record index ticks
    /// from 0 at activation at exactly 60 s on both firmwares, but index 0 is
    /// not at the same offset — measured `60·idx + 60` on V1.6 and
    /// `60·idx + 62` on V1.7 — so a 30-minute preheat ends after index 29 on
    /// one and index 28 on the other. Testing elapsed seconds is right on both
    /// without knowing which. A sensor with no known preheat isn't in warmup:
    /// the durations arrive together with the rest of `DeviceInfo`.
    static func isWarmup(elapsedSeconds: TimeInterval?, preheatDuration: TimeInterval?) -> Bool {
        guard let elapsedSeconds, let preheatDuration else { return false }
        return elapsedSeconds <= preheatDuration
    }

    static func acceptsForHost(elapsed: TimeInterval?, wallAge: TimeInterval?, warmup: TimeInterval?, ratedWear: TimeInterval?) -> Bool {
        guard let elapsed, let wallAge, let warmup, let ratedWear, warmup >= 0, ratedWear > warmup else { return false }
        return elapsed > warmup && wallAge > warmup && elapsed < ratedWear && wallAge < ratedWear
    }

    /// Advance durable recovery only after the host has saved or deliberately deduplicated
    /// these exact samples. Confirming a newer priority point never acknowledges older gaps.
    @MainActor public func acknowledgeHistoryGrid(syncIdentifiers: [String]) {
        guard let mac = state.mac else { return }
        let prefix = "syai-\(mac)-"
        var confirmed = state
        for identifier in syncIdentifiers where identifier.hasPrefix(prefix) {
            if let sequence = UInt16(identifier.dropFirst(prefix.count)) {
                confirmed.pendingHistoryGrid.remove(sequence)
            }
        }
        if confirmed != state { setState(confirmed) }
    }

    static func isPastWear(elapsedSeconds: TimeInterval?, activeDuration: TimeInterval?) -> Bool {
        guard let elapsedSeconds, let activeDuration else { return false }
        return elapsedSeconds >= OttaiWearExtension.extendedWear(activeDuration)
    }

    /// First sequence index worth requesting in a historical backfill.
    /// Warmup-era records do exist on the sensor (idx 0 of a fresh activation
    /// is a real, stored, wildly-wrong ~31 mmol/L record) and are technically
    /// backfillable, but the ingest preheat gate always drops them, so
    /// requesting them just buys airtime for guaranteed-dropped records.
    ///
    /// Index 0 is emitted ~1 min after activation, so `preheatMinutes` is the
    /// first index safely past preheat on either firmware mapping (see
    /// `isWarmup`: the exact boundary is index 29 on V1.6 and 28 on V1.7). One
    /// index conservative on V1.7, which costs nothing — `backfillRange` snaps
    /// the start up to the grid, and the first grid index at or after either
    /// boundary is 30 regardless.
    static func firstBackfillableSequence(preheatDuration: TimeInterval) -> UInt16 {
        let first = max(0, preheatDuration / 60)
        return UInt16(min(first, Double(UInt16.max)))
    }

    @MainActor func flushPendingBackfill() {
        guard !pendingBackfillSamples.isEmpty else { return }
        let batch = pendingBackfillSamples
        pendingBackfillSamples.removeAll()
        logger.debug("backfill: flushing \(batch.count) sample(s) to Loop in one batch")
        submitGridSamples(batch)
    }

    @MainActor @discardableResult func submitGridSamples(_ samples: [NewGlucoseSample]) -> Bool {
        guard let delegateQueue, cgmManagerDelegate != nil, let newest = samples.map(\.date).max() else { return false }
        if newest > (state.latestForwardedToLoopAt ?? .distantPast) {
            var submitted = state
            submitted.latestForwardedToLoopAt = newest
            submitted.lastGridSubmissionAt = Date()
            setState(submitted)
        }
        delegateQueue.async { [weak self] in
            guard let self else { return }
            self.cgmManagerDelegate?.cgmManager(self, hasNew: .newData(samples))
        }
        OttaiDiagnosticEvent.recordPipeline(.forwarding, .submitted)
        return true
    }

    private static func mapTrend(_ trend: GlucoseSample.Trend) -> GlucoseTrend? {
        OttaiGlucoseDisplay.mapTrend(trend)
    }

    /// Records that fit in one history notify packet, which is the largest
    /// request the sensor is trusted to serve. Asking for more makes it page,
    /// and one V1.7 build mis-serves paged responses: the packet headers count
    /// correctly while the bodies replay earlier records, so the readings are
    /// real but attributed to the wrong minutes. Paging is sound by protocol
    /// and works on V1.6, so this is a firmware workaround, not a limit.
    ///
    /// A packet is an 8-byte header plus fixed-width records, capped at 176 B
    /// by the ATT MTU: 18 records on V1.7, 20 on V1.6. Both observed on the
    /// wire. Only a confirmed V1.6 gets the larger count, since 18 fits one
    /// packet at either record width.
    ///
    /// A smaller MTU would invalidate these; `OttaiSensorMonitor` warns if a
    /// request ever pages, and its per-record clock check stops a mis-served
    /// batch from being believed.
    static func maxBackfillRequestCount(parseVersion: String) -> UInt16 {
        parseVersion == "V1.6" ? 20 : 18
    }

    /// The records a backfill request should ask for, given the newest grid
    /// record we already hold (`have`) and the live sequence that just arrived.
    ///
    /// Both ends snap to the grid. Off-grid records at the head or tail of a
    /// hole would be thinned out on arrival, so fetching them only spends
    /// airtime on a link that has usually just come back up — the same
    /// reasoning as the preheat clamp. A hole with no grid record in it snaps
    /// to nothing and is not requested at all.
    ///
    /// `newest` is excluded: it is the frame that triggered this request, so we
    /// already have it. Asking for it anyway re-delivers a reading that was
    /// just ingested live, which shows up in Loop as a duplicate at the same
    /// timestamp. `remaining` is the tail left over when the hole is wider than
    /// one request, to be picked up by the next live sample.
    static func backfillRange(
        have: UInt16,
        newest: UInt16,
        firstRequestable: UInt16,
        maxCount: UInt16
    ) -> (start: UInt16, count: UInt16, remaining: UInt16?)? {
        let step = Int(forwardGridStep)
        guard maxCount > 0 else { return nil }
        let start = Self.nextOnGrid(atOrAfter: max(Int(have) + 1, Int(firstRequestable)))
        let last = (Int(newest) - 1) / step * step
        guard last >= start else { return nil }
        // Chunked walks stop on a grid index too, so resuming from `remaining`
        // can't step over the records the chunk didn't reach.
        let end = min(last, (start + Int(maxCount) - 1) / step * step)
        guard end >= start else { return nil }
        return (UInt16(start), UInt16(end - start + 1), end < last ? UInt16(end) : nil)
    }

    private static func nextOnGrid(atOrAfter sequence: Int) -> Int {
        let step = Int(forwardGridStep)
        return sequence + ((step - sequence % step) % step)
    }

    /// Requests whatever is missing between the newest record we hold and the
    /// live one that just arrived. A reconnect can submit a priority grid point
    /// first while the older history cursor remains queued.
    @MainActor private func firePendingBackfill(newest: UInt16, previousGridSequence: UInt16?) {
        guard priorityGridSequence == nil else { return }
        guard let have = pendingBackfillFrom ?? state.historyCursor ?? previousGridSequence else { return }
        guard let monitor else {
            logger.debug("backfill: skipped, no live monitor (have=\(have), seq=\(newest))")
            return
        }
        guard let preheat = state.preheatDuration else {
            logger.debug("backfill: skipped, no preheat duration for the current sensor (have=\(have), seq=\(newest))")
            return
        }
        let firstUsable = Self.firstBackfillableSequence(preheatDuration: preheat)
        if startPriorityGridRequest(newest: newest, have: have, firstUsableSequence: firstUsable, monitor: monitor) {
            return
        }

        let parseVersion = OttaiFrameParser.parseVersion(
            forDeviceVersion: state.sensors.current()?.deviceInfo.deviceVersion ?? ""
        )
        guard let range = Self.backfillRange(
            have: have,
            newest: newest,
            firstRequestable: firstUsable,
            maxCount: Self.maxBackfillRequestCount(parseVersion: parseVersion)
        ) else {
            pendingBackfillFrom = nil
            logger.debug("backfill: nothing missing at seq=\(newest) (have=\(have))")
            return
        }
        pendingBackfillFrom = range.remaining
        let end = range.start + range.count - 1
        if let remaining = range.remaining {
            logger.debug("backfill: requesting records \(range.start)…\(end) (of \(newest - 1); more queued from \(remaining))")
        } else {
            logger.debug("backfill: requesting records \(range.start)…\(end)")
        }
        Task { [weak self] in
            do {
                try await monitor.requestHistoricalBackfill(fromSequence: range.start, count: range.count)
            } catch {
                self?.logger.debug("historical backfill request failed: \(String(describing: error)); hole stays queued")

                Task { @MainActor in
                    guard let self, self.monitor === monitor, self.priorityGridSequence == nil,
                          self.pendingBackfillFrom == range.remaining
                    else { return }
                    self.pendingBackfillFrom = have
                }
            }
        }
    }
}
