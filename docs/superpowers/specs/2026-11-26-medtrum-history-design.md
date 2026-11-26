# On-demand native basal history recovery — approved trial design

User chose approach1 and explicitly directed implementation and TestFlight release. First run minimal compilation/targeted verification, then wait for their device result. Do not launch full regression or additional post-upload test work without their decision. This supersedes the prior test/build pause only for this authorized trial.

## Approach and scope
Use existing driver, adding on-demand GET_RECORD for ordinary automatic pending basal requests. Keep normal synchronization unchanged; do not add continuous-history/background sync architecture (approach2). Preserve no-replay, independent bolus/short-history protection, pump limits and actual loop success times. Current36 failed because current segment advanced from907 to908/909; never fix by relaxing sequence comparisons or clearing unknown flags by elapsed time.

## Evidence and behavior
- Parse native history read-only, validating packet length, header/type, requested index, raw pump serial, patch and native basal fields. Unsupported/malformed/foreign data fails closed.
- For a pending ordinary automatic request, anchor at its durable pre-command STANDARD baseline, or the existing independently logged legacy predecessor. Read completed native records up to the current native basal tip; require every index and continuous native intervals, then bind to a fresh post-read same-session status. Recheck immutable query/pending identity before commit.
- A complete chain of only scheduled segments after the anchor proves no new temporary segment in that interval. Allow arbitrary ordinary segment changes and operation times. A single matching completed temporary segment may be reconciled only with an unambiguous stable host/native time mapping and durable host history acceptance. Ambiguous, missing, changed-clock, extra temp/bolus/unknown records remain protected.
- Never write a new dose to discover whether the old one ran. Recovery only reads; normal APS makes a fresh decision afterward. Existing active-temp confirmation remains. Durable state commit keeps conservative raw snapshots until successful; recovered actual events must be accepted by the host before unlock and use deterministic identity for retry deduplication.
- Bounded history batches, cached only for the same request/session, with progress diagnostics; failed/unsupported records keep the gate and identify the failing index. No bulk whole-lifetime download.

## Minimal verification/release
Golden primary-reference packet, malformed/foreign/index cases; incident-shaped906→907→908→909, multiple schedule boundaries, missing/reordered/wrong-session/extra-temp cases; successful/failed event persistence and stale query protection. Focused CI plus signed host compile only before TestFlight. One fresh source review can run in parallel. Do not start full tests after upload. Device firmware history compatibility and actual restoration remain unverified until user tests. Exclude log-volume cleanup from this trial.

## Approved explicit user choice (latest steering)
User selected restoring the current loop mode, which can permit automatic insulin delivery, and approved a permanent pump-settings section. Keeping protection only dismisses confirmation; it never consumes the choice, disables its future entry or sends a pump suspend command. Do not repeatedly force a modal.

If native history remains unverified, ordinary automatic basal uncertainty can be acknowledged explicitly through device-owner authentication and an incident-bound confirmation. Save the original pending/checkpoint record before any action. Read current native state; if a temp is active, the confirmation permits one cancellation followed by a fresh native read. Only a same-session active STANDARD result permits durable clearing of this incident. A failed read or persistence keeps protection. Never replay the old request, mark history verified, manufacture a loop success time or clear independent bolus/short-history gates. Retain a permanent audit note and original evidence. The unchanged current loop mode makes subsequent fresh decisions.

Completed-temp automatic reconciliation requires an actual, verified pre-request same-session clock sample frozen in the durable checkpoint. Restored default clock dates do not count; legacy incidents without this provenance remain protected for this path. Batches start at most 12 record reads and stop starting new record reads after 20 seconds; transport/status overhead is additional.

User wants this trial delivered first; joint multi-platform code review is their later decision and is not part of this release task. Preserve the incident evidence regardless of trial outcome; do not assert the basal-only algorithm caused the initial BLE failure.
