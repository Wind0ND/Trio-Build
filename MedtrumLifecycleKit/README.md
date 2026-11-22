# Medtrum extended-session capability

Foundation-only policy; no dosing math and no BLE commands. After 120 hours an extended session disables automatic boluses. Basal delivery still uses the native non-SMB calculation and unchanged limits.

A validated device age is stored with its patch ID. Host activation time and device age are both considered; the older valid age wins. Unknown age fails closed for automatic boluses in extended mode. A new activation resets the observation.

Adapters:
- MedtrumKit snapshots and checks capability before an automatic bolus, including after connecting.
- APSManager carries the same session/capability in its determination context and revalidates before delivery.
- DetermineBasalGenerator applies availability before all SMB branches, without changing stored preferences.
- Pump settings/highlight consume the same policy. This is a capability label, not a claim that hardware will accept delivery beyond its rated lifetime.

Verify with `swift test --package-path MedtrumLifecycleKit`, then the existing Trio/Medtrum simulator workflow. Real device behavior past five days remains a user test, and ten days is a configuration, not a verified hardware guarantee.
