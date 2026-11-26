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
