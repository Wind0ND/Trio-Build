# Manual short temporary basal implementation plan

> **For agentic workers:** Use executing-plans inline; one independent final review before release. Track evidence in the project work record.

**Goal:** Add a Medtrum manual temporary basal of 5, 10, 15, 20 or 25 minutes, default 6 U/h and 5 minutes, with an estimated total and a TestFlight delivery.
**Architecture:** Preserve the native 30-minute pump command and persist a short-duration cancellation intent beside the driver's existing pending dose. Confirm the pump segment, cancel only the same patch and command, and reconcile uncertain outcomes before retrying. A pure policy lives in MedtrumLifecycleKit. Reuse the manual editor from the home basal-rate pill.
**Tech Stack:** Swift, SwiftUI, LoopKit, XCTest, macOS/iOS GitHub Actions.
**Spec:** User-approved design in the current chat and `F:/Codex/2026-11-24/f-codex-projects-trio-outputs-2/outputs/手动临时基础率5至25分钟-设计.md`.

## Global constraints

- User explicitly authorized implementation and TestFlight upload on 2026-11-24; Codex implements directly.
- Default 6 U/hour and 5 minutes; explicit confirmation before any delivery. Preserve existing supported manual rates, limits and longer durations.
- Estimated total = rate × minutes / 60; label as estimated, never as confirmed actual delivery.
- Manual only. Native dose remains 30 minutes in pump history until actually cancelled. Never shorten history or fabricate a successful cancellation.
- Persist before sending; keep a stable command UUID and patch identity; validate again immediately before BLE writes.
- iOS execution and BLE availability may delay cancellation; disclose before confirming and alert on failure.
- Home keeps the actual rate readout from the user's screenshot; make it a button. Existing pump settings entry stays available.
- Keep independent code, accurate zh-Hans strings, bounded anonymous diagnostics and neutral public TestFlight copy.
- Reuse the clean existing checkout on a feature branch; Windows has no Swift/Xcode. Apple CI is the execution evidence.

## Review focus

- Process dies between checkpoint, write and reply: recover pending intent without losing the deadline or dosing twice.
- Older timer, reconnect payload or session must never cancel a later manual/automatic temp.
- A failed/uncertain cancellation remains manual and blocks loop dosing until actual pump state is known.
- Deadline passes while bolus, link loss, or system suspension prevents execution: preserve state, throttle retries, expose delay, avoid fake success.
- Opening the home editor before service injection or while a temp already runs must not crash or send a new dose.

## Task 1: Pure policy and regression specification

**Files:** `MedtrumLifecycleKit/Sources/MedtrumLifecycleKit/MedtrumShortTempBasal.swift`, `MedtrumLifecycleKit/Tests/MedtrumLifecycleKitTests/MedtrumShortTempBasalTests.swift`.
**Interface:** `MedtrumShortTempBasal` Codable/Equatable; validating initializer; `confirmed(startedAt:observedAt:)`, `targetEnd`, `estimatedUnits`, and `canCancel(sessionID:sessionStartedAt:commandID:startDate:rate:automatic:now:)`.

- [ ] Write fixtures for 0.50 U at 6 U/h × 5 minutes, all five durations, invalid inputs, confirmation start, pre-deadline, session/UUID/rate/start mismatch, automatic dose and Codable restart.
- [ ] Commit tests only, push to dev, dispatch unit_tests.yml; observe expected missing policy failure in the package job. Existing production source remains build32.
- [ ] Implement the policy after observing RED. Verify GREEN in final Apple CI.

## Task 2: Driver and reusable editor

**Files:** MedtrumPumpState.swift, MedtrumPumpManager.swift and a dedicated short-temp extension; StateSyncer.swift; MedtrumAlert.swift; ManualTempBasalViewModel.swift, ManualTempBasalView.swift; MedtrumKit localization; HomeRootView.swift; DiagnosticEvents.swift; driver XCTest regression file.
**Interfaces:** state `shortTempBasal`; thread-safe manager snapshot and deadline service; public reusable SwiftUI editor wrapper.

- [ ] Add driver tests for persisted intent, no premature local short end, confirmed status recovery, stale UUID/patch rejection, natural completion and uncertain cancellation.
- [ ] Checkpoint intent together with pending 30-minute dose before writing. Use confirmed start, preserve identity after uncertain replies, and clear only after actual replacement/completion.
- [ ] Service due work through a weak timer, foreground and pump updates, with fresh full sync, existing command reservation, final validation, bounded retry rate and one failure alert.
- [ ] Add default values, editable five-minute slots, estimated total, active countdown/status and immediate cancellation; opening the page is read-only. Reuse from actual home rate pill and pump settings.
- [ ] Add translations and anonymous events. Review diff and commit.

## Task 3: Verification, independent review and release

- [ ] Push candidate and run full unit_tests.yml: algorithm/policy packages, iOS app, Medtrum and existing standalone packages pass.
- [ ] Dispatch one fresh reviewer for the full change against f79c988531eef493cff550d2178063a7b36da5fa. Resolve material findings with regression tests and rerun affected/full CI as warranted.
- [ ] Freeze final SHA; trigger one build_trio.yml upload. Monitor through upload, inspect actual IPA version/branding/localized strings, and verify Apple VALID, IN_BETA_TESTING, internal group and both public localizations.
- [ ] Update project handoff/current status and provide an acceptance note linked from current outputs. Keep physical timing reliability as a real-device validation item.
