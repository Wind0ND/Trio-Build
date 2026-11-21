# hiro branding

Independent iPhone branding assets; original Trio artwork stays in its upstream catalog.

- `Branding.xcconfig`: default `APP_ICON = hiroCorgi` (F). Included by root `Config.xcconfig` before optional user overrides.
- `Assets.xcassets`: five opaque 1024px app icons, explicit iPhone/iPad notification/settings/Spotlight/launcher sizes, plus 256px previews for the existing icon picker. Small-size files use versioned names. `Tools/export-icons.ps1` regenerates those technical size variants without changing the artwork.
- `Artwork`: unmodified generated master PNGs, retained for future export.
- `HiroAppIcon.swift`: resolves the real primary icon from the built Info.plist, lists alternatives without duplicating that primary, and supplies preview/name lookup. Icon selection itself uses the existing `Icons` model.
- `HiroBranding.xcstrings`: independent English/Simplified Chinese icon names.

Selected 2026-11-20: F corgi default; B sleeping cat, C round-faced cat, D Shiba Inu, E floppy-eared dog alternatives. Previous abstract candidates A–F were discarded, not installed.

Generation: built-in image generation with the original `catWithPod` and `catWithPodWhiteBG` assets as style references. Each animal generated individually. Shared prompt: a square, flat, clean medium-weight outlined animal, generous negative space, no text, external rounding, patch, collar or medical/device markings. B: curled sleeping cat, ivory line on dark indigo/plum. C: round-faced seated cat, teal/sage line on pale warm gray. D: seated Shiba, terracotta/caramel line on ivory. E: seated floppy-eared spaniel, ivory line on dark teal. F: standing short-legged corgi, slate-blue/violet line on pale cool gray.

Export: RGB opaque PNG, full-bleed square, no pre-rounded mask. System.Drawing used only for technical size conversion (masters → 1024px icons and 256px previews), without redrawing content.

Upstream integration points: one root config include, three main-target project resources/source references, enum cases and primary/preview lookup in existing icon settings. Bundle identifiers, app groups, URL scheme, watch icons and device logic are unaffected.

Notification-icon feedback: the user confirmed the Home Screen already uses corgi, while ordinary banners/Notification Center showed the old icon. This does not identify a unique device-side cause. Build24 already declared corgi as primary. The update supplies explicit notification-scale assets for every animal; no private API, forced icon choice, app deletion or invented per-notification icon override. Verify the signed IPA and new notifications on-device; old delivered notifications/system caches can differ from the new bundle.

2026-11-21 follow-up: inspected the actual signed build25 IPA: display/bundle names alreadyhiro, primary icons alreadycorgi, but executable/product stillTrio. The new config unifies the public product/executable and explicit English/Simplified Chinese localized names ashiro, retaining the Swift moduleTrio for dependency/test compatibility. Test hosts, schemes and release-note IPA lookup follow the product name. BundleID, entitlements, user-selected alternate icon and ASC registered app name remain unchanged. A finite startup diagnostic records only whether all three public-name fields agree, with no identifiers or raw bundle metadata. This is a registration-consistency change, not proof that iOS will immediately replace a previously cached notification header.
