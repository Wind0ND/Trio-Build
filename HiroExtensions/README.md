# hiro host extensions

Small host adapters for independent PrivacyKit and BackgroundKeepAliveKit features. The upstream Trio source only wires routes, accepted storage, original alarm events and the existing recovery pipeline.

- `ExtensionsSettingsView`: Settings → Trio Configuration → Extensions, after Services. Original feature/settings keys are preserved. CGM pairing/direct/probe routes remain at their original locations.
- `AlertJournalStore` / `AlertJournalView`: original issue/acknowledgement/resolution records retained for24hours, newest first, protected by the existing viewing lock and app lifecycle shield. This store is not an active-alert replay queue and is excluded from default diagnostics/backups. Scheduling or issuing does not prove audio was heard. The new journal starts recording after this update; removed historical events cannot be reconstructed.

Private history content never enters the default diagnostic ZIP. Allowlisted recovery/journal outcomes do. The repository distinguishes file absence from read/decode failures; it retries protected-data access and merges pending events before any write. Generic acknowledgement applies to active groups and never rewrites closed occurrences. The UI clears history rows while inactive or viewing-locked. Public notifications/AlarmKit remain private; active, unlocked in-app banners display original content. The synchronous snapshot shield also covers private alerts when no viewing PIN is configured. Audio selection/sounds and clinical thresholds are unchanged.

Background execution remains conditional: timers, silent audio and user actions do not guarantee revival after force-quit or indefinite running. Validate interruption notices, competing audio and battery use on an actual phone.

Apple references: [interactive widgets/Live Activities](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities), [LiveActivityIntent](https://developer.apple.com/documentation/appintents/liveactivityintent).

## Curve and recovery update

The two optional curves are implemented in PrivacyKit, with independently persisted display references (defaults4/10 and5, editable1–30). They preserve six real grid slots, disconnect gaps and use bounded monotone cubic segments. References and geometry never change samples or clinical alarms. Old bars, marker style and six palettes remain available.

The host serializes ActivityKit mutations across suspension points, updates active/stale activities in place, observes terminal states and retries foreground creation within a finite budget. Private expanded content lives below the camera, sharing a full-row recovery button with the lock-screen card. A compact/minimal system tap may still open the app; the recovery button is reached by long-pressing first. ActivityKit state and API completion do not prove renderer visibility.

Every newly issued alert carries an independent occurrence UUID through persistence, modal callbacks and notification userInfo. The protected journal separates observed triggers/deliveries, upcoming plans and cancelled/unverified records. Old records without delivery evidence remain unverified; elapsed time alone cannot turn a plan into a fired alert. Delivered notifications are captured before removal; exact OS receipts are distinct from stale timer callbacks. These local UUIDs and original content are never exported in diagnostic events.

Final review refinements: pending activity snapshots coalesce behind one suspended publication, with explicit lifecycle operations acting as ordering barriers. Legacy clamped bars are never reverse-engineered into raw curve values; the old bars remain until real slots arrive. Notification retirement is ordered per identifier: capture old receipt, remove old delivery, then register the latest queued plan. Exact system receipts remain evidence even if an in-flight delivery lands after retraction; stale timer callbacks do not. Retraction is displayed as ended/cancelled, not clinical recovery. The local delivered timestamp makes re-import idempotent, and no-op healthy checks emit no cancellation. Diagnostics retain at most4000 events with separate finite evidence reservations and exported coverage bounds, not a guarantee of complete history under arbitrary floods.
