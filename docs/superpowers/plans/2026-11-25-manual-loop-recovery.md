# Manual loop recovery implementation plan

> **For agentic workers:** Use superpowers:executing-plans. Execute directly in the existing checkout; user selected Codex and approved implementation/verification, then TestFlight delivery.

**Goal:** Withdraw obsolete manual-basal loop alarms, preserve an independent recovery window, coalesce early loop requests, and deliver the requested defaults/durations.
**Architecture:** Keep reminder state in HiroExtensions with persisted transition timestamps; NotLoopingMonitor subscribes to actual manual state. LoopGuard owns one cancellable deferred request and keeps the existing minimum interval and all delivery guards.
**Tech Stack:** Swift, Combine, Swift Testing/XCTest, existing macOS CI.
**Spec:** F:/Codex/2026-11-24/f-codex-projects-trio-outputs-2/outputs/hiro-闭环超时与恢复间隔-修复方案-20261125.md (approved); subsequent user defaults30 U/h/1min, add6–9min, publish for testing.

## Global constraints
- No Live Activity changes; investigation deferred until recurrence.
- Minimum interval remains180 seconds; successful loop date changes only on real success.
- No retry of uncertain pump commands or stale determinations; only coalesce requests rejected before starting.
- Reminder recovery anchor survives restart; no repeated state/toggle can extend it.
- Defaults30 U/h/1min;1–10 every1min,15–60 every5min,90–720 every30min. Existing pump/configuration limits remain strict.

## Review focus
- Restart/repeated manual state must not indefinitely defer the overdue window.
- Deferred task races with normal start/new manual state must not duplicate dosing.
- Open loop, suspension, changed pump/data must retain normal safeguards.
- Async cancellation must retract this reminder group without disabling other alarms.
- Model/configuration may reject30 U/h; never raise saved limits automatically.

### Task1: Reproduce and fix recovery/reminder behavior
Files: APSManager.swift (LoopGuard/entry/manual callbacks), NotLoopingMonitor.swift, HiroExtensions/LoopTimeoutReminderPreferences.swift, TrioTests/NotLoopingMonitorTests.swift, DiagnosticEvents.swift; paths under existing source folders.
Interfaces: HiroLoopReminderWindow(defaults: UserDefaults?); setManualTempBasal(_:at:) -> Bool; anchor(lastSuccess:) -> Date. LoopGuard.requestStart(minInterval:lastLoopDate:lastLoopStartDate:now:retry:) -> Bool; pendingRetryDate; cancelPendingRetry(). Inject reminder manual publisher and clock for deterministic tests.
- [ ] Add inert test seams retaining baseline behavior, regression tests, and scoped CI. Runtime RED must show manual plans survive / deferred requests absent, not unrelated compilation failures.
- [ ] Implement persisted transition window, manual publisher withdrawal/resume and one pending retry. Add diagnostics for actual decisions.
- [ ] Run targeted GREEN then full main/driver/algorithm/independent package regression.
- [ ] Commit code and actual evidence.

### Task2: Defaults and6–9min
Files: ManualTempBasalViewModel.swift, MedtrumShortTempBasal.swift, existing policy/driver tests.
- [ ] Extend parameterized policy/driver tests and expected defaults; observe actual runtime RED.
- [ ] Set requested defaults and supported minutes. Assert new intervals use native30min plus requested phone deadline and keep driver upper limits.
- [ ] Include in final full CI. Commit.

### Task3: Review, release and delivery
- [ ] One fresh whole-branch review under executing-plans; fix material findings with RED→GREEN and final suite.
- [ ] Freeze final source, publish one signed build, inspect IPA and Apple/internal group/bilingual neutral metadata.
- [ ] Record actual run/build/source, update handoff and user test instructions. Do not mark device timing as software verified.
