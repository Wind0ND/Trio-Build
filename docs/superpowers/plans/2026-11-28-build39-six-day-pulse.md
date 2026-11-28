# Build39 six-day pulse implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline, then one fresh whole-branch review. Track the steps below.

**Goal:** Implement the user's120h pulse transition and total144h observation on build39, preserving alarms.
**Architecture:** Keep build39 transport and safety mechanisms; extend its existing effective-mode adapter and expiry dates.
**Tech Stack:** Swift, Swift Testing/XCTest, macOS26/Xcode26.5 CI (Windows has no Swift/Xcode).
**Spec:** `docs/superpowers/specs/2026-11-28-build39-six-day-pulse.md`

## Global constraints

- Baseline7df56fdc1b2609dcdd29ebe6ab5cf9f2cc1091bd; no build40 native timer.
- Only selected `closed` routes to pulses during [120h,144h);128h is observation only.
-144h total, normal72+8 unchanged. All build39 alarms and safety guards retained.
- Reuse the clean main checkout on a new branch; keep the build40 branch/history.
- No signed release or shared dev branch rewrite.

## Review focus

- Exact120/128/144h boundaries; test with fixed activation times in driver tests.
- Other modes and patch replacement; exercise effective-mode routing and selection preservation.
- Unsupported, provisional, ended, faulted sessions; driver eligibility tests.
- Alarm prearming, failed cancellation and companion ownership; unchanged build39 sources plus existing regression tests.
- Actual144h expiry, not152h; assert both derived dates and the normal80h endpoint.

## Task1: regression tests and runtime RED

- [x] Add driver lifetime/window tests to `MedtrumKitTests/PumpManager/ShortTempBasalTests.swift`.
- [x] Add closed-only mode tests to `TrioTests/OpenAPSSwiftTests/BasalOnlyDosingModeTests.swift`.
- [x] Add inert signatures only for compilation: `effectiveForDevice(basalOnly:pulseAvailable:)` and `isExtendedPulseWindow(at:)` returning existing behavior/false.
- [x] Run focused macOS CI and retain runtime assertion failures.

## Task2: implementation and GREEN

- [x] Set extended lifespan144h/grace0 in `MedtrumPumpState.swift`.
- [x] Implement confirmed active MD8301 window in `Extensions/MedtrumPumpManager+ExtendedLife.swift`.
- [x] Route only closed via `DosingMode.swift` and `HiroExtensions/BasalOnlyDosingMode.swift`; use effective mode in `DeviceDataManager.swift` pulse ownership closure.
- [x] Update only lifetime copy and Simplified Chinese localization; keep the build39 pulse description and all alarm settings.
- [x] Run focused/new tests and the full existing manual macOS unit suite, inspect actual results.

## Task3: review and handoff

- [x] One fresh branch review (one Important time-authority finding).
- [x] One fix pass: share `MedtrumExtendedLifePolicy` effective age, latch144h closure through existing persistence, verify disagreements/rollback/restoration/replacement and legacy data.
- [x] Verify changed-file list against build39, especially exact alarm/transport identity.
- [x] Mark build40 superseded in current handoff; preserve original release proof.
- [x] Register the existing mode-test file in the app target after the log audit exposed its package-only registration; run only the5-test app suite, not the unaffected full suite.
- [x] Commit source and save implementation/validation notes; no signed upload.

## Actual verification

Production source941b8a0ea6bb30eb720d76e78afa269aadce6927:
full46135041548 succeeded with App1097/143 suites, driver161, algorithm230,
lifecycle44, all0failures;5 standalone packages and privacy iOS build succeeded.
Focused46135041680:48 driver tests and3 mode tests passed.
Test-registration-only1330804d9cf1138f60fa919b837508c77ebae057 changes no production
Swift/localization; app-adapter46137289935 xcresult passed5/failed0/skipped0.
The full App count remains1097; do not present the supplemental5 as part of that run.
Evidence and exact commands: project work/build39-six-day-pulse-20261128/verification.json
and project outputs/hiro-build39基线-六天观察与警报保留-实施记录-20261128.txt.
