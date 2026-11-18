//
//  OttaiRecentReadingsView.swift
//  OttaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import SwiftUI
import OttaiKit

struct OttaiRecentReadingsView: View {
    let samples: [GlucoseSample]
    let onSelect: (GlucoseSample) -> Void

    var body: some View {
        List {
            if samples.isEmpty {
                Section {
                    Text("No readings yet.", bundle: .ottaiUI, comment: "empty recent readings")
                        .foregroundColor(.secondary)
                }
            } else {
                Section {
                    OttaiReadingRowHeader()
                    ForEach(samples.indices, id: \.self) { idx in
                        Button(action: { onSelect(samples[idx]) }) {
                            OttaiReadingRow(sample: samples[idx])
                        }
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
    }
}
