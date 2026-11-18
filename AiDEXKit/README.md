# AiDEXKit

An independent, display-only Swift package for a first-pass AiDEX foreground
probe in Trio. It is not a CGM driver and is not part of `DeviceCatalog`, any
enabled CGM source, persistence, Nightscout, alerts or loop input.

## What it does

- Accepts the sensor serial from a box code, photo, or manual entry. The serial
  stays in the active view and session.
- Listens in the foreground for Bluetooth advertisements with an exact local
  name match after case/whitespace normalization and one of the observed
  prefixes: `AiDEX X-` or `X-`.
- Decodes only manufacturer data with company ID `0x0059` (little-endian),
  exactly 20 following measurement bytes, and a valid proprietary checksum.
- Shows the last accepted value in mg/dL and mmol/L, the receive timestamp, and
  a local-only status. Repeated or regressing active-minute counters do not
  refresh the timestamp or emit another event.
- Stops on explicit user action, leaving the screen, leaving the foreground, or
  when the selected sensor stops advertising for 60 seconds.

It does **not** connect over GATT, write, calibrate, activate, look up a sensor
online, or infer support for other AiDEX models.

## Protocol attribution

The advertisement layout and checksum were implemented from the public protocol
description in:

- <https://github.com/Arrow36/aidex-x-linx-ble-reader>
- MIT License, Copyright (c) 2026 Arrow36

The full notice is in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). No source
from that project was copied or ported; this is a small independent Swift
implementation written from the documented layout.

## Limits

- Exact domestic firmware behavior remains unverified.
- There is no Apple SDK or Swift compiler in the Windows verification
  environment, so the package tests are provided but could not be executed
  there.
- This is an experimental display-only probe. It must never be used for dosing.

## Tests

```sh
swift test --package-path AiDEXKit
```

The decoder, matcher, session state machine and diagnostic payload are
Foundation-only and build on macOS as well as iOS. The CoreBluetooth transport
and SwiftUI screen are compiled only for iOS.

## Localization

`Sources/AiDEXKit/Resources/Localizable.xcstrings` contains Simplified Chinese
(`zh-Hans`) for every new user-facing string. The package's
`defaultLocalization` is English.
