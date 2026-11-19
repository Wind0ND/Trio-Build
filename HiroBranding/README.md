# hiro branding

Independent iPhone branding assets; original Trio artwork stays in its upstream catalog.

- `Branding.xcconfig`: default `APP_ICON = hiroCorgi` (F). Included by root `Config.xcconfig` before optional user overrides.
- `Assets.xcassets`: five opaque 1024px app icons plus 256px previews for the existing icon picker.
- `Artwork`: unmodified generated master PNGs, retained for future export.
- `HiroAppIcon.swift`: resolves the real primary icon from the built Info.plist, lists alternatives without duplicating that primary, and supplies preview/name lookup. Icon selection itself uses the existing `Icons` model.
- `HiroBranding.xcstrings`: independent English/Simplified Chinese icon names.

Selected 2026-11-20: F corgi default; B sleeping cat, C round-faced cat, D Shiba Inu, E floppy-eared dog alternatives. Previous abstract candidates A–F were discarded, not installed.

Generation: built-in image generation with the original `catWithPod` and `catWithPodWhiteBG` assets as style references. Each animal generated individually. Shared prompt: a square, flat, clean medium-weight outlined animal, generous negative space, no text, external rounding, patch, collar or medical/device markings. B: curled sleeping cat, ivory line on dark indigo/plum. C: round-faced seated cat, teal/sage line on pale warm gray. D: seated Shiba, terracotta/caramel line on ivory. E: seated floppy-eared spaniel, ivory line on dark teal. F: standing short-legged corgi, slate-blue/violet line on pale cool gray.

Export: RGB opaque PNG, full-bleed square, no pre-rounded mask. System.Drawing used only for technical size conversion (masters → 1024px icons and 256px previews), without redrawing content.

Upstream integration points: one root config include, three main-target project resources/source references, enum cases and primary/preview lookup in existing icon settings. Bundle identifiers, app groups, URL scheme, watch icons and device logic are unaffected.
