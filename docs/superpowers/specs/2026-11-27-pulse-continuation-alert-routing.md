# Pulse continuation and alert history repair

Approved scope: repair build 38's companion continuation self-rejection and open Alert History on a normal alert notification tap, then deliver one new TestFlight build. Keep the current upstream base (1.0.2.74); do not merge 1.0.2.91.

The companion still belongs to its original pulse after a successful pulse cancellation. A below/equal-schedule companion must retain its parent through the final Bluetooth validation. Only an external protective request (no continuation identifier) may discard that plan. Wrong/stale continuation identifiers must never erase a newer plan, and existing write/session/deadline/alarm/saved-limit checks still apply. Do not delay or silence genuine cancellation/companion failure alarms to conceal this bug.

A normal tap on a recognized alert notification opens the existing Alert History screen. Preserve current snooze/acknowledgement semantics and explicit snooze/dismiss actions. Retain a cold-start navigation request until Main.RootView is configured, coalesce duplicates, and prevent an older view's detachment from removing its replacement's handler. Reuse the existing journal and privacy shield; do not expose locked history or introduce external URLs. The AlarmKit Stop intent remains unchanged.

All pump commands remain temporary basal SET/CANCEL only. Preserve actual-basal-history IOB, the three-minute loop minimum, original algorithm, unknown-delivery protection, identity/persistence checks and AlarmKit prearming. iOS deployment minimum remains 17.6; auto pulse requires iOS 26 AlarmKit authorization and successful scheduling. Neutral public hiro copy only.

Acceptance: regression tests visibly fail on the existing behavior and pass on the repair, full app/driver/algorithm checks pass, one whole-change review is resolved, signed IPA matches tested source and new build number, Apple reports VALID and membership in Trio Internal. Device delivery and system alert presentation require subsequent on-device observation.
