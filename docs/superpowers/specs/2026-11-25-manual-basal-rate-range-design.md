# Manual temporary basal rate range

The user requested removing the manual editor's fixed limit below 10 U/h after testing build33. The builder's implementation choice is to use the existing driver's supported rates for the connected pump model; this does not certify or change the pump's manufacturer specifications.

## Approach

Use the current pump manager's supportedBasalRates for the editor and the same configured-maximum validation for submission. A new fixed number would duplicate the model capability table; changing the host's saved maximum would change a separate user setting and is outside this request.

The user subsequently requested five-minute increments between30 and60minutes. Offer5–60minutes in five-minute steps, then90minutes through12hours in30-minute steps. Durations35–55minutes use the existing packet's whole-minute duration field, consistent with the primary AndroidAPS Medtrum packet implementation; this is protocol evidence, not a physical-device acceptance claim.

Preserve the default 6 U/h and 5 minutes, estimated total, native30-minute command for durations below30minutes, deadline cancellation, history reconciliation and automatic-delivery guards. Keep invalid/nonfinite/off-step rates and unknown configured limits blocked. Values above the configured maximum remain visible with the existing warning and disabled apply button, preserving the requested visible default even when it exceeds that maximum.

Scope: editor rate choices/selection validation/duration choices and the two driver rate checks. No automatic meal dosing, algorithm changes, new defaults or automatic maximum increase. Follow existing TestFlight release authorization for this feature; verify the actual next build rather than assuming its number.
