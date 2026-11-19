# PrivacyKit

Independent privacy presentation and optional viewing lock for Trio.

## Products

`PrivacyKit` contains the Foundation display policy, six-color palette, bounded activity snapshot and extension-safe SwiftUI cover/waveform. `PrivacyAppKit` contains app-only settings, photo thumbnail generation, secure credentials and the viewing shield. Link only `PrivacyKit` in the Live Activity extension.

Privacy options start disabled. The app provides settings under Features → Privacy and Live Activity → Privacy, a home-screen privacy button, and the Enable private activity Shortcut.

## Display

Six five-minute slots are chronological and preserve gaps. Heights use a fixed 0–15 mmol/L scale with a visible minimum. The entire meter takes its color from the latest valid sample, using the approved deep-purple, blue, green, yellow-green, orange and red palette. Five editable boundaries default to 3, 4, 6, 8 and 12 mmol/L, with a short continuous blend around each boundary.

Freshness uses the measurement timestamp. At five minutes without a new valid sample, the waveform becomes an outline circle retaining the last color. ActivityKit stale rendering is system-scheduled and requires device verification.

Custom covers are downsampled, cropped and re-encoded without original metadata. Serialized thumbnails are bounded to 1,200 bytes. Private ActivityKit content omits the normal chart, forecasts, numeric reading, treatment values and labels. The app regression test checks the complete encoded state against ActivityKit's 4 KB limit.

## Viewing lock

The optional lock supports a four-digit PIN or a hidden-trace pattern, with optional biometrics. Salted PBKDF2-HMAC-SHA256 credentials use a device-only Keychain item. Failed-attempt cooldown survives relaunch. Forgotten credentials can be cleared after iOS device-owner authentication.

The shield is installed above the app's presented views, ends underlying editing and covers inactive/background snapshots. Background generations prevent late authentication callbacks from unlocking after a background transition. Glucose acquisition, algorithm execution and alert delivery remain separate from UI authentication.

## Alerts

Trio integrates private presentation at the notification, AlarmKit and in-app-banner boundaries, preserving the original alert record and identifiers. Public glucose alerts use 注意 in Simplified Chinese. Low, forecasted-low and carb-required alarms use cool accent colors, urgent low uses deep purple, and high uses red. Ordinary notification text colors are controlled by iOS.

AlarmKit doesn't expose a presentation-only update for an existing alarm. An already-started system alarm retains its original title until stopped. Users should enable private wording before an alarm starts. Changing privacy doesn't stop or recreate sounding alarms.

Existing notification redaction is coordinated with per-identifier scheduling/cancellation generations. Delivered replacements are silent, while new notifications retain their configured sound and urgency. Current glucose alarms are immediate requests. Future repeating glucose producers need explicit review of interval phase when pending requests are rewritten.

## Integration points

- `TrioPrivacyIntegration.swift` connects alert presentation, notification reconciliation and the safe enable-privacy Shortcut.
- `LiveActivityAttributes+Helper.swift` creates sanitized snapshots and fallback states.
- `LiveActivityManager.swift` listens for preference changes and updates all ActivityKit presentations.
- `TrioApp.swift` attaches the viewing shield.
- `DiagnosticEvents.swift` accepts finite privacy transitions. Credentials, photo bytes and health values are excluded from feature-event payloads.

## Verification

```sh
swift test --package-path PrivacyKit
```

The repository's manual test workflow additionally cross-builds both products against the iOS Simulator SDK and runs the app's payload/fallback regression tests. Lock-screen appearance, keyboard/snapshot shielding, biometrics, photo selection, system notification behavior and alarms require simulator/device QA.
