# Native short temporary basal and final eight hours

User-approved scope (latest correction is binding): only the stored `closed` mode
automatically uses `basalPulse` during hours 120–128 of an extended MD8301 patch.
Every other selected mode stays unchanged. Do not overwrite the stored selection;
a new patch restores its normal interpretation. After hour 128 preserve the existing
automatic-bolus restriction and pump-fault protections, without extending lifetime.

Add an initially disabled pump setting for native minute timing. Latch its value in
each persisted manual/pulse/companion intent. Enabled requests use minute duration
directly, without dedicated cancellation AlarmKit prearming or automatic deadline
cancellation. Ordinary fault/unknown protections and verified history remain. No
fallback to 30 minutes after a rejected or ambiguous native write. Keep the legacy
path and its build39 continuation-ownership fix. Native acceptance and autonomous
ending remain device acceptance tests, not claims from software checks.

Extended nominal lifetime is 120 hours plus the existing 8-hour grace period,
128 hours total. Do not write the pump clock or ignore fault 102. Preserve the SMB
algorithm, safety caps, three-minute interval and actual-basal IOB accounting.

## Tasks

1. Runtime RED tests: persisted native duration, legacy decoding, closed-only
   effective mode and 128-hour dates. Add inert API scaffolding where necessary.
2. Implement latched timing, manual/pulse/companion transport, natural completion,
   setting/localization, lifetime and effective mode. Test real packet bytes,
   no native alarm tickets/deadline cancellation, history/companion ownership.
3. One fresh whole-branch review, one material fix pass if needed; run final native
   lifecycle/algorithm and full app/driver checks on macOS/Xcode.
4. Freeze source, one signed build upload, inspect actual IPA and Apple/internal
   group/bilingual metadata; deliver test instructions and update handoff.

No local Swift/Xcode/Bash: use existing Windows Python release tools and macOS CI.
Already-authorized TestFlight publication needs no additional approval.

## Binding user amendment: six-day observation window

User confirmed total lifetime144h and closed-only pulse fallback120–144h. Hour128 is an observation point, with no software mode transition there. Extended lifespan144h with zero added grace (normal72+8 unchanged), so both displayed extended endpoints are144h; do not accidentally produce152h. Existing firmware faults still stop/guard delivery. This supersedes all 128h/final-eight-hour scope above.
