# Medtrum recovery test build

User authorized combining the deferred fresh-cache issue and Nov26 uncertain-delivery recovery/prevention into a new TestFlight build. Subsequent instruction: upload after minimal necessary checks; run detailed regression after upload. One source review ran in parallel with the minimal checks; its safety findings were fixed before release, without a repeat review. Existing Codex direct execution and release route remain authorized. Keep the current checkout with a new branch; no worktree or route question.

## Required behavior
- Fresh, certain data on an active current patch returns its real cached observation date, never a fabricated successful refresh date. Unknown/stale/future data remains rejected.
- A lost reply never causes the old command to be resent. A full current-patch status may confirm the matching temp or prove the pre-command segment is still current.
- Save the pre-command basal segment identity before sending new automatic temp commands. A later full status with that exact segment proves the failed replacement did not start; remove only that pending request, preserve basal history, persist recovery.
- Build35 migration: for expired ordinary automatic 30-minute requests only, require an independently timestamped strictly pre-request native temp predecessor from the retained driver log, same device/patch/activation in one full packet, incompatible with the pending request. The current STANDARD segment must have the immediately adjacent native sequence without rollover. Newer conflicting, malformed, post-request or ambiguously attributed entries cannot establish the proof. Timestamp approximation alone cannot unlock. Missing history remains protected.
- Bind each recovery to a query started after the failed write, immutable delivery generation, session and pending signature; recheck before committing. A held pre-command response or activation conflict cannot resolve it.
- Stage a candidate while live/raw snapshots stay conservative; serialize host storage and driver commit, use an atomic protected write, and only then open delivery. Missing/throwing persistence stays blocked.
- Keep verified observation provenance separate from generic lastSync. Permit first native activation to replace a provisional host estimate only without pending/uncertain delivery; that establishment packet cannot recover a request or supply cached freshness. Preserve authoritative halt accounting and normal resume/rate schedule admission.
- Do not clear independent bolus uncertainty, unresolved short-temp history, or a live write. Keep pump/model/configuration limits, minimum interval, mode/source/session guards and actual-success timestamps.
- Bounded logs explain recovery versus blocked reason; no raw health values in unified diagnostics. No Live Activity changes.

## Verification and release order
Focused driver checks cover fresh callback and persistent uncertainty recovery plus essential negative cases. Compile and run these before signing; then upload ONE build and verify actual IPA/version/digest/branding and Apple internal group/notes. Detailed full main/driver/algorithm/packages regression continues after upload, per user instruction. The one fresh source review and its single critical/important fix pass are already completed; report remaining limits honestly and address material findings (new source requires a new verified upload if necessary).

Current physical disconnect cause and iOS background timing cannot be guaranteed by this build.
