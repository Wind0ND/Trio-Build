//
//  OttaiOnboardingView.swift
//  OttaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import LoopKitUI
import SwiftUI

struct OttaiOnboardingView: View {
    @Environment(\.dismissAction) private var dismiss
    let onContinue: () -> Void
    let onShowPlacement: () -> Void
    /// The Ottai catalogue entry reuses this screen with its own artwork and
    /// account name, so neither is hard-coded here.
    var imageName: String = "sensor"
    var accountName: String = "Ottai"

    /// Printed on the first screen so a build under test can be identified without
    /// guessing which binary the phone is running.
    static var buildStamp: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Trio \(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Spacer()
                            Image(imageName: imageName)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 150)
                                .padding(.bottom, 10)
                            Spacer()
                        }
                        Text(Self.buildStamp)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Before you begin", bundle: .ottaiUI, comment: "onboarding header")
                            .font(.title3).bold()
                        Text(
                            "Apply the sensor and sign in to your \(accountName) account. Then, you can activate the sensor and read from it directly in the app.", bundle: .ottaiUI,
                            comment: "onboarding BYOA explanation"
                        )
                    }
                }
            }

            Spacer()
            VStack(spacing: 10) {
                Button(action: onShowPlacement) {
                    Text("Placement Guide", bundle: .ottaiUI, comment: "placement guide button")
                }
                .buttonStyle(ActionButtonStyle(.secondary))

                Button(action: onContinue) {
                    Text("Continue", bundle: .ottaiUI, comment: "continue button")
                }
                .buttonStyle(ActionButtonStyle())
            }
            .padding(.horizontal)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: dismiss) { Text("Cancel", bundle: .ottaiUI, comment: "cancel") }
            }
        }
    }
}
