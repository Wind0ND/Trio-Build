//
//  OttaiSampleDetailView.swift
//  OttaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import LoopKit
import LoopKitUI
import SwiftUI
import OttaiKit

/// All the diagnostic data on one glucose sample, pushed when the user taps
/// a row in Recent Readings.
struct OttaiSampleDetailView: View {
    let sample: GlucoseSample
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference

    var body: some View {
        List {
            Section {
                row(String(localized: "Value", bundle: .ottaiUI, comment: "sample detail: glucose value"), value: displayGlucosePreference.format(
                    LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: sample.valueMgDL)
                ))
                row(
                    String(localized: "Time", bundle: .ottaiUI, comment: "sample detail: time"),
                    value: sample.date.formatted(date: .abbreviated, time: .standard)
                )
                row(String(localized: "Time (relative)", bundle: .ottaiUI, comment: "sample detail: relative time")) {
                    Text(sample.date, style: .relative)
                        .foregroundStyle(.secondary)
                }
                row(String(localized: "Trend", bundle: .ottaiUI, comment: "sample detail: trend"), value: trendLabel)
                if let rate = sample.rateOfChangeMgDLPerMinute {
                    row(
                        String(localized: "Rate of change", bundle: .ottaiUI, comment: "sample detail: rate of change"),
                        value: displayGlucosePreference.formatMinuteRate(
                            LoopQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: rate)
                        )
                    )
                } else {
                    row(String(localized: "Rate of change", bundle: .ottaiUI, comment: "sample detail: rate of change"), value: "—")
                }
            } header: {
                Text("Reading", bundle: .ottaiUI, comment: "sample detail section: reading")
            }

            if sample.condition != nil || sample.hasBlockingIssue {
                Section {
                    if let condition = sample.condition {
                        row(String(localized: "Range", bundle: .ottaiUI, comment: "sample detail: range condition")) {
                            Text(
                                condition == .belowRange
                                    ? String(localized: "Below display range (LO)", bundle: .ottaiUI, comment: "sample detail: below range")
                                    : String(localized: "Above display range (HI)", bundle: .ottaiUI, comment: "sample detail: above range")
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                    if sample.hasBlockingIssue {
                        row(String(localized: "Issue", bundle: .ottaiUI, comment: "sample detail: quality issue")) {
                            Text("Sensor reported fault", bundle: .ottaiUI, comment: "sample detail: sensor fault")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Quality", bundle: .ottaiUI, comment: "sample detail section: quality")
                }
            }

            Section {
                row(String(localized: "Sent", bundle: .ottaiUI, comment: "sample detail: sent to Trio")) {
                    HStack(spacing: 6) {
                        Image(systemName: sentIcon)
                            .foregroundStyle(sentColor)
                        Text(sentLabel)
                    }
                }
                if let reason = sample.forwardSkipReason, !sample.wasForwarded {
                    row(String(localized: "Reason", bundle: .ottaiUI, comment: "sample detail: not-forwarded reason")) {
                        Text(reason)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Forwarding to Trio", bundle: .ottaiUI, comment: "sample detail section: forwarding")
            }

            Section {
                row(String(localized: "Path", bundle: .ottaiUI, comment: "sample detail: source path"), value: sourceLabel)
                row("Sequence", value: "\(sample.sequence)")
                    .monospacedDigit()
                if abs(sample.rawBaseMgDL - sample.valueMgDL) > 0.5 {
                    row(
                        String(localized: "Raw base", bundle: .ottaiUI, comment: "sample detail: raw base before range clamp"),
                        value: displayGlucosePreference.format(
                            LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: sample.rawBaseMgDL)
                        )
                    )
                }
            } header: {
                Text("Source", bundle: .ottaiUI, comment: "sample detail section: source")
            }
        }
        .navigationTitle(Text("Sample detail", bundle: .ottaiUI, comment: "sample detail screen title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// `LabeledContent` is iOS 16+; this project's floor is 15.1, so a plain
    /// title/value row does the same job.
    @ViewBuilder private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
            Spacer()
            content()
        }
    }

    /// Every paired sensor carries real calibration, so a forwarded sample
    /// is always dosing-grade here — no separate "display only" state.
    private var sentIcon: String {
        sample.wasForwarded ? "checkmark.circle.fill" : "minus.circle"
    }

    private var sentColor: Color {
        sample.wasForwarded ? .green : .secondary
    }

    private var sentLabel: String {
        sample.wasForwarded
            ? String(localized: "Yes", bundle: .ottaiUI, comment: "sample detail: sent to Trio")
            : String(localized: "No", bundle: .ottaiUI, comment: "sample detail: not sent to Trio")
    }

    private var trendLabel: String {
        switch sample.trend {
        case .notDetermined: return "—"
        case .risingQuickly: return String(localized: "Rising quickly ⇈", bundle: .ottaiUI, comment: "trend: rising quickly")
        case .rising: return String(localized: "Rising ↗", bundle: .ottaiUI, comment: "trend: rising")
        case .stable: return String(localized: "Stable →", bundle: .ottaiUI, comment: "trend: stable")
        case .falling: return String(localized: "Falling ↘", bundle: .ottaiUI, comment: "trend: falling")
        case .fallingQuickly: return String(localized: "Falling quickly ⇊", bundle: .ottaiUI, comment: "trend: falling quickly")
        }
    }

    private var sourceLabel: String {
        switch sample.source {
        case .realtime: return String(localized: "Realtime (live BLE)", bundle: .ottaiUI, comment: "sample source: realtime")
        case .historicalBackfill: return String(localized: "Historical backfill", bundle: .ottaiUI, comment: "sample source: historical backfill")
        }
    }
}
