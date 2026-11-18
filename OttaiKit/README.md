# OttaiKit

Trio/Loop CGM driver for the mainland-China Ottai M8 sensor.

This target is a self-contained fork of the vendored MIT-licensed SyaiKit driver
(copyright (c) 2026 Nightscout Foundation), derived from the Syai Ultra protocol
implementation in this repository. It does **not** import, subclass, link against,
or otherwise depend on the SyaiKit target.

## Maintenance

- The wire protocol, GATT UUIDs, backend routes, signing preimages and persisted
  `rawValue` keys are shared with Syai and must not be renamed for cosmetics.
- The deployed plugin identifier (`OttaiCGMManager`) and Keychain service/account
  namespace are deliberately unchanged so upgrades keep the existing account
  session and sensor record.
- Ottai keeps its own `Documents/ottai/` log and sensor-history files. The
  historical `Documents/syai/` tree belongs to SyaiKit and is never ingested:
  it cannot be attributed to Ottai after the split, and silently importing it
  would mix two accounts. On first launch after the split the active sensor is
  restored from the persisted `OttaiCGMManager` rawState instead, whose keys
  are unchanged.
- `Scripts/gen_pbxproj.py` is the controlled generator for `OttaiKit.xcodeproj`.
  Re-run it after adding/removing target-level folders; both targets use Xcode
  synchronized folder groups, so source files themselves need no project edits.
