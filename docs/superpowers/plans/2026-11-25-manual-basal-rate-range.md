# Manual basal rate range implementation plan

> **For agentic workers:** Use executing-plans inline with one fresh whole-change review before release. Reuse the clean feature checkout and record evidence in the plan ledger.

**Goal:** Replace the manual temporary basal editor's fixed below10 U/h cap with current driver model capabilities, retaining the configured maximum, and add five-minute choices from30 through60minutes.
**Architecture:** Use MedtrumPumpManager.supportedBasalRates in the existing editor and manualTempBasalRateAllowed as the shared short-command validation. Keep all cancellation, persistence and automatic-delivery logic.
**Tech Stack:** Swift, SwiftUI, LoopKit, XCTest, Apple GitHub Actions.
**Spec:** docs/superpowers/specs/2026-11-25-manual-basal-rate-range-design.md

## Global Constraints

- Defaults6 U/h and5minutes; current maximum UI duration12hours.
- Offer5–60minutes every5minutes, then90minutes through12hours every30minutes. Only durations below30minutes use phone-side cancellation.
- Respect pump model supported rates AND the saved host maximum; never increase either in this change.
- Unknown maximum, invalid/off-step values and unresolved history remain blocked.
- Windows has no Swift/Xcode: observe actual RED and GREEN on Apple CI.
- Production remains build33 until reviewed final CI and signed release pass.

## Review Focus

- A model changes after the editor opens: options and validation must use current capabilities.
- Programmatic/stale selections cannot submit unsupported rates even with a higher configured maximum.
- Limits lowered after opening the editor are enforced again immediately before BLE writes.
- Short durations above10 U/h reach the normal connection/write path without changing packet duration.
- New35–55minute choices preserve exact requested native packet minutes; durations above60minutes and the user's successful5-minute cancellation keep their existing behavior.

## Task 1: Model-aware editor and driver validation

**Files:** MedtrumKit/MedtrumKitUI/ViewModels/Settings/ManualTempBasalViewModel.swift; MedtrumKit/MedtrumKit/PumpManager/Extensions/MedtrumPumpManager+ShortTempBasal.swift; MedtrumKit/MedtrumKit/PumpManager/MedtrumPumpManager.swift; existing MedtrumKitTests/PumpManager/ShortTempBasalTests.swift.
**Interface:** existing allowedRates, selectionWithinLimit, manualTempBasalRateAllowed(_:) and enactTempBasal remain the boundaries.

- [ ] Add real editor/driver tests with synthetic MD8201/MD8301 fixtures: allow10 and25 for both,30 only for300U, reject25.05 for200U; retain lower saved maximum, unknown maximum, invalid/off-step rejection and live capability changes. Check high-rate short enact reaches communication failure with deliberately absent Bluetooth rather than an obsolete configuration rejection. Assert35/40/45/50/55minute choices, exact packet durations,90minute next choice,12hour cap and estimated total.
- [ ] Push tests only and run manual_basal_tests.yml. Expected: new above10/model-range assertions fail while prior18short regressions pass. Use macos15 with the same pinnedXcode26.2 as the full test workflow.
- [ ] Implement model-aware options and supported-selection check; remove both fixed below10 restrictions, reusing manualTempBasalRateAllowed in the initial short-command guard. Set allowedDurations to5–60minutes every5minutes plus90–720minutes every30minutes.
- [ ] Run full unit_tests.yml on final SHA. Expected: app compile and all prior/new tests pass; inspect actual logs.
- [ ] One fresh reviewer examines the net diff against4873234177b5bd368d8498e09b4dd76654417e0b, the spec and Review Focus; address material findings with regressions. Freeze SHA.

## Task 2: Internal test release

**Consumes:** Task1's frozen reviewed/testedSHA.

- [ ] Dispatch one build_trio.yml upload. Expected: signed build/upload success.
- [ ] Verify actual IPA version/branding/Chinese resources and artifact digest; verify AppleVALID/IN_BETA_TESTING, TrioInternal membership and both public localizations.
- [ ] Update project handoff and the current thread's user-facing acceptance note. Preserve build33's single successful5-minute physical test as baseline; higher-rate actual delivery remains unverified.
