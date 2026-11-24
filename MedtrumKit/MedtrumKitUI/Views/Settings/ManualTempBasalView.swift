import LoopKitUI
import SwiftUI

struct ManualTempBasalView: View {
    @Environment(\.appName) private var appName
    @ObservedObject var viewModel: ManualTempBasalViewModel

    var body: some View {
        VStack {
            List {
                if let active = viewModel.activeShortTemp {
                    Section("Manual temporary basal running") {
                        if active.accountingUnresolved {
                            Text("Delivery history is uncertain. Automatic delivery is blocked until the records can be verified.")
                                .foregroundStyle(.orange)
                        }
                        LabeledContent("Rate", value: viewModel.rateFormatter(for: active.rate))
                        LabeledContent("Estimated total", value: String(format: "%.2f U", active.estimatedUnits))
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            if active.awaitingConfirmation {
                                Text("Waiting for pump confirmation")
                            } else if active.endDate > context.date {
                                LabeledContent("Remaining time") {
                                    Text(active.endDate, style: .timer).monospacedDigit()
                                }
                            } else {
                                Text("Cancellation pending. The temporary basal may still be running.")
                                    .foregroundStyle(.orange)
                            }
                        }
                        LabeledContent("Planned cancellation", value: active.endDate.formatted(date: .omitted, time: .standard))
                        if active.cancellationFailed {
                            Text("Cancellation could not be confirmed. Check the pump connection.")
                                .foregroundStyle(.orange)
                        }
                        Button("Cancel manual temporary basal", role: .destructive, action: viewModel.cancel)
                            .disabled(viewModel.enacting || viewModel.enactingBolus)
                    }
                } else if viewModel.hasManualTemp {
                    Section {
                        Text("Manual temporary basal running")
                        Button("Cancel manual temporary basal", role: .destructive, action: viewModel.cancel)
                            .disabled(viewModel.enacting || viewModel.enactingBolus)
                    }
                }
                Section {
                    HStack {
                        Text("Rate", comment: "Label text for basal rate summary")
                        Spacer()
                        Text(String(
                            format: String(
                                localized: "%@ for %@",
                                comment: "Summary string for temporary basal rate configuration page"
                            ),
                            viewModel.rateFormatter(for: viewModel.selectedRate),
                            viewModel.durationFormatter(for: viewModel.selectedDuration)
                        ))
                    }
                    HStack {
                        Picker(selection: $viewModel.selectedRate) {
                            ForEach(viewModel.allowedRates, id: \.self) { item in
                                Text(viewModel.rateFormatter(for: item))
                            }
                        } label: { EmptyView() }
                            .pickerStyle(.wheel)
                            .disabled(viewModel.enacting || viewModel.hasManualTemp)
                        Picker(selection: $viewModel.selectedDuration) {
                            ForEach(viewModel.allowedDurations, id: \.self) { item in
                                Text(viewModel.durationFormatter(for: item))
                            }
                        } label: { EmptyView() }
                            .pickerStyle(.wheel)
                            .disabled(viewModel.enacting || viewModel.hasManualTemp)
                    }
                    .frame(maxHeight: 162.0)
                    HStack {
                        Text("Estimated total")
                        Spacer()
                        Text(viewModel.estimatedUnits).monospacedDigit().fontWeight(.semibold)
                    }
                    if let maximum = viewModel.maximumRate {
                        LabeledContent("Configured maximum", value: viewModel.rateFormatter(for: maximum))
                        if viewModel.selectedRate > maximum + 0.000001 {
                            Text("The selected rate exceeds the configured maximum. Change the rate before applying.")
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Text("Waiting for the configured delivery limit. Applying is unavailable.")
                            .foregroundStyle(.orange)
                    }
                    if viewModel.historyNeedsReview {
                        Text("Delivery history is uncertain. Automatic delivery is blocked until the records can be verified.")
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Estimated total = rate × minutes ÷ 60. Actual delivery depends on the pump history.")
                    if viewModel.selectedDuration < .minutes(30) {
                        Text("The pump is set for 30 minutes. hiro sends a cancellation at your selected time. Disconnection or background restrictions may delay cancellation, so delivery may continue for up to 30 minutes.")
                    }
                    Text(
                        String(
                            format:
                            String(
                                localized: "%@ will not automatically adjust your insulin delivery until the temporary basal rate finishes or is canceled.",
                                comment: "Description text on manual temp basal action sheet"
                            ),
                            appName
                        )
                    )
                }
            }

            if let error = viewModel.error {
                Text(error)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.red)
            }
            Button(action: viewModel.enact) {
                HStack(alignment: .center, spacing: 10) {
                    if viewModel.enactingBolus {
                        ActivityIndicator()
                        Text("Bolus in progress...", comment: "Button text for setting manual temporary basal rate")
                    } else if viewModel.enacting {
                        ActivityIndicator()
                    } else {
                        Text("Set Manual Temp Basal", comment: "Button text for setting manual temporary basal rate")
                    }
                }
            }
            .buttonStyle(ActionButtonStyle(.primary))
            .disabled(viewModel.enacting || viewModel.enactingBolus || viewModel.hasManualTemp || !viewModel.selectionWithinLimit)
            .padding()
        }
    }
}

/// The same editor is used by the home rate button and the pump's existing settings route.
public struct MedtrumManualTempBasalView: View {
    @StateObject private var viewModel: ManualTempBasalViewModel
    private let onDismiss: () -> Void

    public init(pumpManager: MedtrumPumpManager, onDismiss: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: ManualTempBasalViewModel(pumpManager: pumpManager, goBack: onDismiss))
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationStack {
            ManualTempBasalView(viewModel: viewModel)
                .navigationTitle(String(localized: "Manual Temp Basal", bundle: Bundle(for: MedtrumPumpManager.self)))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: onDismiss) { Text("Done") }
                    }
                }
        }
    }
}
