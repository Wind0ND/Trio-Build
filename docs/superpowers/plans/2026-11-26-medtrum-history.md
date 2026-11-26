# On-demand basal history recovery implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:executing-plans inline.

**Goal:** Recover an ordinary failed automatic basal across later scheduled changes using attributable native records, without replay or discarding uncertainty.
**Architecture:** Read-only packet parser; focused history evidence/policy; bounded request-bound driver collector; existing host persistence transaction plus event acceptance; existing release path.
**Tech:** Swift/LoopKit, GET_RECORD99, macOS26/Xcode26.5 CI.
**Spec:** docs/superpowers/specs/2026-11-26-medtrum-history-design.md (user-selected approach1 trial).

## Constraints and review focus
No full regression or post-upload testing until user device result/decision. Do not change algorithm, dose limits, manual defaults, Live Activity or log volume. Preserve unknown bolus/short-history gates. Validate every record identity and uninterrupted coverage; never accept skipped/unsupported records or infer non-execution merely from current normal basal. Respect request/session changes during BLE reads or durable commit. No new dose retries. New ended-temp events require durable acceptance and deterministic mapping/deduplication before unlock.

- [x] Add minimal packet/policy tests first (golden reference, actual incident shape, critical rejects). Local Windows has no Xcode; user fast-path authorizes one focused Apple cycle after implementing, not a separate RED CI/full cycle.
- [x] Add GetBasalRecordPacket.swift and native-history model/policy; integrate bounded on-demand reads into syncPumpData, keep existing narrow fast proofs as safe optimizations. Store unambiguous confirmed history before existing recovery transaction clears pending. Add diagnostics and targeted workflow scope.
- [x] Run focused compile/tests and one parallel fresh source review; fix material findings, freeze SHA, sign/upload next build and inspect actual artifact+Apple/group/copy. Report real-device unknowns. STOP test work after release and await user feedback; do not dispatch unit_tests.yml.

- [x] Implement approved permanent pump-settings recovery section, reversible keep choice, authenticated incident-bound manual resume of current mode, original-request audit and fresh STANDARD/persistence gates. Independent bolus and short-history uncertainty remains protected.
- [x] Restrict positive history mapping to verified pre-request frozen clock checkpoints; add focused manual-persistence/status/clock cases before release.
- [x] Validate final source with focused CI and signed host compilation, distribute TestFlight, then stop and await the user's actual device result. No joint-platform audit or full regression now.

Delivered hiro1.0.2(37), application source ba4f6604c963f1536aaf09ca1f21355426aae16e, targeted71/0/0, signed45736155129 and actualIPA15080552036 verified; AppleVALID/IN_BETA_TESTING/TrioInternal and bilingual copy verified. No further tests dispatched; wait user device result. Documentation-only completion commits do not require a new build.
