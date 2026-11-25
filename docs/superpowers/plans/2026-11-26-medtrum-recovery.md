# Medtrum recovery implementation plan

Spec: docs/superpowers/specs/2026-11-26-medtrum-recovery.md
Base: 93b63ad4fd4b0f551778d963377ba25611485f69 (released35).

1. Add focused MedtrumKitTests/DeliveryRecoveryTests.swift: fresh-cache callback, saved baseline identity and checkpoint roundtrip, full same-segment recovery, changed/later/wrong-patch/cached/in-flight rejection, expired35 scheduled-baseline migration and later-transition blocking; independent bolus/short-history remains blocked. User explicitly deferred detailed testing; implement focused checks with fix, do not spend a separate Apple CI cycle on RED.
2. MedtrumPumpManager.ensureCurrentPumpData returns validated cached lastSync; full invalid payload does not claim fresh success. New PumpManager/MedtrumBasalRecovery.swift owns Codable baseline/checkpoint and policy. State persists checkpoint. checkpointBasal captures baseline before write; cancel ACK refreshes baseline. StateSyncer invokes policy only on authoritative same-session full status, then retains normal history handling. Persist resolution before notifying the host; restore uncertain state if persistence fails.
3. Extend bounded medtrum recovery diagnostics and debug state to identify pending flags/reasons without private IDs. Existing alert/success semantics stay unchanged.
4. Focused CI only on DeliveryRecoveryTests using existing release toolchain. Compile/targeted PASS -> freeze source -> signed TestFlight upload -> verify actual artifact/source/digest/name/icons/versions and Apple/group/bilingual copy. Do not claim full suite passed at upload.
5. After upload run complete unit_tests.yml (release runner) and one independent whole-branch review. Handle critical/important findings with regression checks; no repeat review. Update handoff, pending tasks, and user test note with actual build and checks.

Review focus: stale/detached baseline; packet-clock drift and same-second legacy ambiguity; checkpoint failure must never unlock; full status claiming another session; invalid refresh cannot satisfy APS; generic and short/manual commands must retain independent guards.
