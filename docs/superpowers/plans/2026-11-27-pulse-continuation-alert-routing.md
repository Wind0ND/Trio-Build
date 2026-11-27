# Pulse Continuation and Alert Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Fix companion self-rejection and notification history routing, then release one test build.

**Architecture:** Keep pump policy in MedtrumPumpManager's existing temp-basal path. Add an independent, in-memory main-actor navigation broker with thin notification and Main.RootView connections.

**Tech Stack:** Swift, XCTest/Swift Testing, SwiftUI, UserNotifications, GitHub macOS CI, TestFlight.

**Spec:** docs/superpowers/specs/2026-11-27-pulse-continuation-alert-routing.md

## Global Constraints

- No upstream merge, actual bolus, synthetic IOB, therapy parameter changes or weakening of validation.
- Minimum iOS 17.6; auto pulse requires iOS 26 AlarmKit authorization and successful scheduling.
- Keep alert snooze semantics, privacy shield and genuine failure alarms. Neutral public hiro copy only.
- Reuse the clean existing checkout; release is explicitly authorized by the user.

## Review Focus

1. Below/equal-profile and zero-rate companions keep their parent while external protective interruption still discards it (Task 1 tests).
2. Stale continuation identifiers cannot clear the current plan; final write validation remains authoritative (Task 1 tests).
3. Cold notification taps survive loading, duplicated taps coalesce, and a replaced view's detach cannot lose a pending request (Task 2 tests).
4. Snooze/dismiss/unknown and unrelated notifications do not navigate; normal taps retain snooze behavior (Task 2 tests).
5. Alert history presentation retains locked-content shielding and supersedes secondary modals without bypassing it (Task 2 integration checks).

### Task 1: Preserve original companion ownership

**Files:** MedtrumPumpManager.swift, Extensions/MedtrumPumpManager+ShortTempBasal.swift; ShortTempBasalTests.swift.

**Interfaces:** Produce `preparePulseContinuationForWrite(protectiveInterrupt: Bool, continuationOf: UUID?)`; consumes current pump state. Task 2 shares no dosing interface.

- [x] Add real manager-state regression tests for below/equal/above-profile and zero companions, stale identifiers, external interruption and non-protective requests.
- [x] Extract the existing clear operation unchanged into the method and call it from the actual pre-write path; run focused native driver tests. Expected: parent-preservation assertion failures on the original behavior.
- [x] Clear the continuation only for protective requests with no continuation identifier; run native driver tests. Expected: zero failures.
- [x] Commit code and evidence.

### Task 2: Route default alert taps to history

**Files:** new HiroExtensions/AlertHistoryNavigation.swift and NotificationResponseHandoff.swift with their Xcode references; AppDelegate.swift; UserNotificationsManager.swift; MainRootView.swift; AlertDismissalSnoozeTests.swift; scripts/check_notification_handoff.swift.

**Interfaces:** `HiroAlertHistoryNavigation.shouldOpenHistory(actionIdentifier:requestIdentifier:userInfo:) -> Bool`; `request()`, `attach(owner:UUID,handler: @escaping () -> Void)`, `detach(owner:UUID)` on MainActor. Existing Router publishes `.alertJournal` and clears secondary modal. `HiroNotificationResponseHandoff<Response>.receive(_:)` buffers early responses and `.attach(handler:)` replays them once; AppDelegate captures without service resolution, then the initialized notification manager forwards to its canonical handler.

- [x] Add behavior tests for payload/action recognition, cold queue, duplicate coalescing, detach/replacement and real BaseRouter routing. Add inert API stubs, run native host tests. Expected: assertion failures, not compiler errors.
- [x] Implement payload recognition and owner-bound asynchronous flushing; connect notification callback and configured root; keep snooze handlers unchanged. Expected: native tests pass and existing snooze tests still pass.
- [x] Verify privacy integration and commit.

### Task 3: Verify and deliver

**Files:** focused workflow, neutral beta metadata, release evidence and current handoff documents.

**Interfaces:** Tested source SHA -> signed archive -> IPA metadata -> App Store Connect build -> Trio Internal.

- [x] Run complete appropriate app/driver/algorithm/module checks and one fresh whole-branch review; resolve material findings in one combined pass. Expected: all required checks pass.
- [x] Trigger one signed build upload, inspect actual IPA/source/version, verify Apple VALID/internal group and bilingual neutral notes. Expected: new installable build, no duplicate upload.
- [x] Record delivery and remaining device checks; report build number and upstream deferral.


## Evidence and review resolution

Native RED46001247632 (driver7 assertion failures, host10 issues) -> final full GREEN46004837530 (App1097/driver156/algorithm229/lifecycle39, zero failures). One whole-branch review found startup registration gap; one fix pass added early capture/canonical replay. Native handoff RED46004558779 -> GREEN46004833159. No repeated review. Signing/upload46008730933 succeeded; actual IPA and Apple VALID / IN_BETA_TESTING / Trio Internal / bilingual neutral notes verified; actual app source remains7df56fdc1b2609dcdd29ebe6ab5cf9f2cc1091bd.
