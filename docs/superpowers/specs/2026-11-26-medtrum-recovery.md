# Medtrum recovery test build

User authorized combining the deferred fresh-cache issue and Nov26 uncertain-delivery recovery/prevention into a new TestFlight build. Subsequent instruction: upload after minimal necessary checks; run detailed regression and review after upload. Existing Codex direct execution and release route remain authorized. Keep the current checkout with a new branch; no worktree or route question.

## Required behavior
- Fresh, certain data on an active current patch returns its real cached observation date, never a fabricated successful refresh date. Unknown/stale/future data remains rejected.
- A lost reply never causes the old command to be resent. A full current-patch status may confirm the matching temp or prove the pre-command segment is still current.
- Save the pre-command basal segment identity before sending new automatic temp commands. A later full status with that exact segment proves the failed replacement did not start; remove only that pending request, preserve basal history, persist recovery.
- Build35 migration: for expired ordinary automatic requests only, compare the retained pre-request scheduled basal with the full current scheduled segment, same patch/session, rate and clock-corrected start (existing two-second pump quantization tolerance). No short-temp or ambiguous later segment may use this path. Historical uncertainty remains blocked when proof is insufficient.
- Do not clear independent bolus uncertainty, unresolved short-temp history, or a live write. Keep pump/model/configuration limits, minimum interval, mode/source/session guards and actual-success timestamps.
- Bounded logs explain recovery versus blocked reason; no raw health values in unified diagnostics. No Live Activity changes.

## Verification and release order
Focused driver checks cover fresh callback and persistent uncertainty recovery plus essential negative cases. Compile and run these before signing; then upload ONE build and verify actual IPA/version/digest/branding and Apple internal group/notes. Detailed full main/driver/algorithm/packages regression and one fresh review continue after upload, per user instruction; report remaining limits honestly and address material findings (new source requires a new verified upload if necessary).

Current physical disconnect cause and iOS background timing cannot be guaranteed by this build.
