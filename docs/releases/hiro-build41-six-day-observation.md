# hiro 1.0.2 (41) — build39 baseline, six-day observation

Published2026-11-28 to TestFlight **Trio Internal**. Apple VALID / IN_BETA_TESTING;
en-US and zh-Hans descriptions and notes read back and verified.

This supersedes the build40 native-short experiment. Preserve build39 alarms,
prearming, phone deadline cancellation, failure protection, companion ownership
fix and alert-history routing. Only selected `closed` uses protected basal pulses
from patch age120h to<144h on an eligible extended MD8301 session. Extended144h
total, no extra8h;128–144h is observation, no128h transition. Stored choice and
other modes stay unchanged; replacement uses the new session. Verified device
age and latched144h closure prevent clock rollback reopening the window.

Production is identical to the candidate verified by full46135041548 (App1097,
driver161, algorithm230, lifecycle44, zero failures), focused46135041680 and
supplemental app-adapter46137289935 (5 passed/0 failed/0 skipped). Only notes and
documentation changed for publication; successful checks were not repeated.

- Source: `396c343f91d6fe4829acb87ee9fe7133ab72a4ab`.
- One signed-upload workflow: `46139535280`, success.
- Actual artifact: `15263015289`; digest/source/build/resources verified.
- IPA SHA256: `88a18194590c1e96cdad6a59000a09b0d689d9d7070760e869da57cd3f444b91`.
- Actual1.0.2/build41; hiro identity, unchanged Bundle ID, Corgi+13 alternatives,
  iOS17.6 minimum, extension41, AlarmKit usage/audio, Chinese144h pump copy and
  absence of the native-short option checked in the actual IPA.
- Historical dev retained as a merge parent; no force push or upstream sync.

`bundle exec fastlane build_trio` and `bundle exec fastlane release` both exited0.
Apple verification helper exited0; internal membership and both locale copies
matched. Original logs, actual artifact and Apple proof are under project
`work/build41-release-20261128/`.

Update after the current short delivery ends and pump state is confirmed. This
release does not prove144h hardware operation; the prior128h fault remains real.
Fault/unknown safeguards remain; no clock rewrite, fault102 suppression or
automatic reactivation. Physical cancellation and alarm audibility retain their
device-verification limits.
