# Build39 baseline: six-day observation with pulse routing

The user's current instruction supersedes build40. Start from the delivered
build39 app source `7df56fdc1b2609dcdd29ebe6ab5cf9f2cc1091bd`. Preserve build40
and its release evidence as history; do not include native short timing.

For a confirmed, active extended MD8301 patch, the selected `closed` mode uses
the existing build39 `basalPulse` actuator from age >=120h to age <144h. Keep
the stored selection so a new patch resumes its normal interpretation. Other
selected modes remain unchanged. Hour128 has no mode transition: [128h,144h)
is the observation period. Extended lifetime is a total of144h, with no added
8h grace; normal lifetime remains72+8h. A suspended, failed, provisional or
ended session cannot gain pulse capability from its age.

Use the existing policy's older of valid activation-derived and same-session
verified pump ages for both120h and144h. Persist a session-scoped144h closure
once observed/evaluated, so clock rollback or restart cannot reopen that patch.
Old persisted policy data must still decode; a different patch cannot inherit
the old patch's age or closure.

Keep all build39 alarm code, prearming requirements, phone cancellation,
watchdogs, companion ownership fix, notification routing and unknown/fault
protections. Failed alarm preparation must still prevent automatic pulses.
Do not send automatic physical boluses as a fallback, change insulin limits,
rewrite the pump clock, suppress102 or reactivate a session automatically.

## Approaches

Use a new branch directly from the exact build39 app source with only lifetime,
effective-mode routing, related copy and tests. This directly follows the
requested baseline. Reverting selected build40 files risks retaining native
timing dependencies and is unnecessary. Do not mutate saved settings at120h:
the existing effective-mode mechanism preserves the user's choice per patch.

Software checks cannot demonstrate that firmware continues delivery to144h.
The previous128h stop remains a real observation. No signed upload is included
in this implementation request; a later build must use a new build number.
A later release must preserve shared-dev history when integrating this39-based
branch; do not force-push over the historical40 release. Recheck the final tree
and running request/session compatibility before a separately authorized release.

## Candidate acceptance record

Implemented on the39 baseline. Full software regression46135041548 and focused
regression46135041680 passed on production source941b8a0ea; app1097, driver161,
algorithm230, lifecycle44, all0failures. The existing mode tests were subsequently
registered in the app test target at1330804d9; supplemental run46137289935 proves
5passed/0failed/0skipped, including actual pump-adapter routing and replacement.
Production Swift/localization did not change after the full run, so it was not repeated.
All10 selected core alarm/delivery sources retain their build39 Git content identity.
No signed build, shared-dev rewrite, native-minute validation or144h device acceptance
was performed. Current task proof is outside the repo in work/build39-six-day-pulse-20261128.
