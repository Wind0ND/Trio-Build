# Basal pulse SMB trial implementation

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. User approved direct implementation and delivery of one trial; no route selection or repeated design approval.

**Goal:** Deliver a TestFlight trial that uses native SMB decisions but sends only temp-basal set/cancel packets for the new opt-in mode, with protected cancellation alarms.

**Architecture:** Keep dosing mathematics unchanged. Add a native SMB calculation capability separate from physical bolus capability; coordinate the pulse and its companion basal as one persisted transaction. Reuse short-temp monitoring, actual basal history and AlarmKit; never synthesize a bolus history dose.

**Tech Stack:** Swift, SwiftUI, MedtrumLifecycleKit, LoopKit, AlarmKit, GitHub macOS26/Xcode26.5 and existing TestFlight delivery tooling.

**Spec:** ../specs/2026-11-26-basal-pulse-correction-design.md and user-approved chat sequence of 2026-11-26; latest user authorizes a test build.

## Global constraints

- Native SMB/UAM math and saved settings stay unchanged; no actual bolus packet on simulated route or fallback.
- Preserve session identity, persistent delivery guards, real freshness, limits and 3-minute loop minimum.
- New mode defaults off by preserving saved mode. User chooses it explicitly. Native short duration remains 30 minutes with phone cancellation.
- Alarm authorization plus actual async prearm success required before new automatic pulse. Cancellation never requires alarm authorization.
- Critical alarm bypasses app mute; stopping sound never clears delivery protection. Existing manual short-temp remains available.
- Windows has no Swift compiler. RED and GREEN execute on actual macOS runner, not a Python imitation. Reuse clean current checkout on feature branch; no new worktree needed per project preference.

## Review focus

1. Bolus-restricted patch still calculates native candidate but no bolus transport can be reached.
2. Native low/zero companion basal cannot conflict with pulse or extend its original deadline.
3. Lost set/cancel reply, process death and stale callbacks cannot replay dose or release unknown accounting.
4. Clock changes, alarm quota and authorization changes cannot erase the only prearmed warning.
5. Simulated execution updates native interval input without inventing bolus insulin or double counting basal IOB.

### Task 1: Pin absent features with RED

Files: TrioTests/OpenAPSSwiftTests/BasalOnlyDosingModeTests.swift; MedtrumKit/MedtrumKitTests/PumpManager/ShortTempBasalTests.swift; .github/workflows/basal_pulse_tests.yml.

- [x] Add runtime tests requiring DosingMode(rawValue: "basalPulse") to exist, preserve preferences and forbid physical SMB; require cancellation alert critical + audible.
- [x] Commit tests/workflow only, push existing release dev route, dispatch focused Apple tests and observe actual assertion failures (not compile errors).

### Task 2: Native plan and persistent driver transaction

Files: MedtrumLifecycleKit/Sources and Tests; MedtrumPumpManager+ShortTempBasal.swift; MedtrumShortTempBasal.swift; MedtrumPumpManager.swift; MedtrumPumpState.swift.

Interfaces: MedtrumBasalPulsePlan.make(units:companionRate:companionMinutes:supportedRates:maximumRate:) -> optional plan; plan holds whole-minute pulse, native paired-basal absolute deadline, requested budget. MedtrumShortTempBasal optional automatic-pulse metadata decodes old manual intents unchanged. Driver enactAutomaticBasalPulse(plan:isValid:completion:) never calls bolus.

- [x] Add meaningful tests for dose never rounded upward, invalid inputs/limits, companion remaining duration, persistence compatibility, automatic vs manual cancellation identity, unresolved block and last execution time.
- [x] Implement policy and shared short-temp automatic context. Checkpoint before write; no success for whole planned dose on initial acknowledgement; confirmed cancelled history feeds existing basal IOB.
- [x] Persist effective SMB interval timestamp scoped to patch. Preserve original cancellation guards and bounded retries; after confirmed cancellation apply only still-current remaining companion plan.

### Task 3: Protected alarm integration

Files: CriticalAlertAlarmScheduler.swift; TrioAlertManager.swift; HiroExtensions/BasalOnlyDosingMode.swift; DeviceDataManager.swift; MedtrumAlert.swift.

Interfaces: driver armShortTempAlarm(commandID:deadline:completion:) returns actual async scheduling result; retireShortTempAlarm(commandID:) only for verified completion or definite no-execution. Host protected alarm IDs are request-specific. Reuse critical alert presentation and sound with protected alarm policy.

- [x] Add assertions for critical audible cancellation alert, protected schedule acknowledgement, unavailable alarm refusal, and request-specific alarm identity.
- [x] Prearm before pulse write. Keep earliest safe warning across real-start reconciliation; never create unprotected interval on replacement. Continue failed cancellation alarms independently of normal user mute; stopping alarm only affects sound.
- [x] Reattach hooks and reconcile persisted pending requests after restore; callbacks recheck current manager identity. Use 15-second initial warning grace and 60-second finite followup from approved engineering draft; log scheduling vs firing separately.

### Task 4: Host routing, UI and interval/history

Files: DosingMode.swift; OpenAPS.swift; APSManager.swift; HiroExtensions/BasalOnlyDosingMode.swift; Chinese localization; relevant tests and Xcode project if needed.

- [x] Add explicit basalPulse full automation mode with physical SMB disabled; preserve existing basalOnly behavior.
- [x] Permit native SMB calculation for supported pulse mode separately from pump bolus permission, with all non-capability safety constraints retained.
- [x] Route before ordinary basal/bolus enactment; pulse route consumes the determination once and returns before performBolus. No fallback to bolus.
- [x] Feed last verified/possibly-started pulse timestamp into native SMB interval guard; keep insulin history solely actual basal doses. Add Chinese labels and clear system alarm availability status.

### Task 5: Verify, one review, deliver one trial

- [ ] Run targeted pulse/short-temp/mode tests and project regression through existing unit_tests.yml release runner; inspect actual logs and counts.
- [x] One fresh whole-branch review per executing-plans; resolve material findings in one test-backed fix pass; no repeated reviews.
- [ ] Freeze final source SHA; verify remote ref and Apple latest version; dispatch one signed upload. Validate actual IPA source/version/brand/localization/hash plus Apple VALID/internal group and bilingual neutral notes.
- [ ] Update project handoff and user-facing test instructions in current chat outputs. Report exactly what is verified vs pending device trial; do not call therapy or fault safety proven by software tests.
