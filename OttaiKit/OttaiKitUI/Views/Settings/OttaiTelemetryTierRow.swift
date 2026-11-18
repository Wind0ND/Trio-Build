//
//  OttaiTelemetryTierRow.swift
//  OttaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import SwiftUI
import OttaiKit

struct OttaiTelemetryTierRow: View {
    let tier: OttaiTelemetryTier
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundColor(selected ? .accentColor : .secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    OttaiTelemetryTierDetail.title(tier).foregroundColor(.primary)
                    if tier == .full {
                        Text("Recommended", bundle: .ottaiUI, comment: "recommended tier badge")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundColor(.accentColor)
                            .clipShape(Capsule())
                    }
                }
                OttaiTelemetryTierDetail.description(tier)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

enum OttaiTelemetryTierDetail {
    static func title(_ tier: OttaiTelemetryTier) -> Text {
        switch tier {
        case .minimal: return Text("Minimal", bundle: .ottaiUI, comment: "tier: minimal")
        case .standard: return Text("Standard", bundle: .ottaiUI, comment: "tier: standard")
        case .full: return Text("Full", bundle: .ottaiUI, comment: "tier: full")
        }
    }

    static func description(_ tier: OttaiTelemetryTier) -> Text {
        switch tier {
        case .minimal:
            return Text(
                "Only what pairing a sensor requires.", bundle: .ottaiUI,
                comment: "tier detail: minimal"
            )
        case .standard:
            return Text(
                "Also tells Ottai when your sensor connects, disconnects, or reports a problem.", bundle: .ottaiUI,
                comment: "tier detail: standard"
            )
        case .full:
            return Text(
                "Also uploads your glucose readings, exactly as the official app does. Allows your doctor/caregivers to keep following your treatment.", bundle: .ottaiUI,
                comment: "tier detail: full"
            )
        }
    }
}
