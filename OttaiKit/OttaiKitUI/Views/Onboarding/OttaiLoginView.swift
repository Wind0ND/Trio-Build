//
//  OttaiLoginView.swift
//  OttaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Combine
import LoopKitUI
import SwiftUI
import OttaiKit

struct OttaiLoginView: View {
    @Environment(\.dismissAction) private var dismiss
    @ObservedObject var viewModel: OttaiLoginViewModel

    /// Last few CN wire exchanges, mirrored on screen: the sign-in failures so far could
    /// not be diagnosed without exporting the log file.
    @State private var traceLines: [String] = []
    private let traceTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if !traceLines.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(traceLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(UIColor.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if viewModel.mode == .phone {
                    VStack(spacing: 0) {
                        fieldRow(icon: "phone.fill") {
                            TextField(
                                String(localized: "Phone number", bundle: .ottaiUI, comment: "phone field placeholder"),
                                text: $viewModel.phone
                            )
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                        }
                        Divider().padding(.leading, 54)
                        fieldRow(icon: "message.fill") {
                            HStack(spacing: 10) {
                                TextField(
                                    String(localized: "Code", bundle: .ottaiUI, comment: "sms code placeholder"),
                                    text: $viewModel.smsCode
                                )
                                .keyboardType(.numberPad)
                                .textContentType(.oneTimeCode)
                                Button(viewModel.codeSent ? "Resend" : "Send code") {
                                    viewModel.requestCode()
                                }
                                .font(.footnote)
                                .buttonStyle(.plain)
                                .foregroundColor(.accentColor)
                                .disabled(!viewModel.canRequestCode)
                            }
                        }
                    }
                    .cardBackground()
                } else {
                    VStack(spacing: 0) {
                        fieldRow(icon: "envelope.fill") {
                            TextField(
                                String(localized: "Email", bundle: .ottaiUI, comment: "email field placeholder"),
                                text: $viewModel.email
                            )
                            .keyboardType(.emailAddress)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                        }
                        Divider().padding(.leading, 54)
                        fieldRow(icon: "lock.fill") {
                            SecureField(
                                String(localized: "Password", bundle: .ottaiUI, comment: "password field placeholder"),
                                text: $viewModel.password
                            )
                            .textContentType(.password)
                            .onSubmit(viewModel.submit)
                        }
                    }
                    .cardBackground()
                }

                if viewModel.mode == .email {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $viewModel.keepLoggedIn) {
                            Label {
                                Text("Keep me logged in", bundle: .ottaiUI, comment: "keep logged in toggle")
                            } icon: {
                                Image(systemName: "key.fill").foregroundColor(.accentColor)
                            }
                        }
                        Text(
                            viewModel.keepLoggedIn
                                ?
                                "Your session stays signed in for months. Your password is kept in the iOS Keychain so Trio can sign you back in if the session expires."
                                :
                                "Your password is used only to sign in and is never stored. If the session expires you'll be asked to sign in again.",
                            comment: "login password footer"
                        )
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16)
                    .cardBackground()
                }

                if let error = viewModel.errorMessage {
                    Label {
                        Text("Failed to login: \(error)", bundle: .ottaiUI)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.footnote)
                    .foregroundColor(.red)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding()
        }
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .onReceive(traceTicker) { _ in
            let next = Array(OttaiWireTrace.shared.snapshot.suffix(8))
            if next != traceLines { traceLines = next }
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: viewModel.submit) {
                HStack {
                    if viewModel.isBusy {
                        ActivityIndicator(isAnimating: .constant(true), style: .medium)
                    }
                    Text("Log In", bundle: .ottaiUI, comment: "log in button")
                }
            }
            .buttonStyle(ActionButtonStyle())
            .disabled(!viewModel.canSubmit)
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: dismiss) { Text("Cancel", bundle: .ottaiUI, comment: "cancel") }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 76, height: 76)
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 34))
                    .foregroundColor(.accentColor)
            }
            Text(
                viewModel.mode == .phone ? "Sign in to Ottai" : "Sign in to Ottai",
                comment: "login header"
            )
                .font(.title2).bold()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func fieldRow<Content: View>(
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private extension View {
    func cardBackground() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
