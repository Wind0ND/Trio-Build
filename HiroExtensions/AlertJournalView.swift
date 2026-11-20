import PrivacyAppKit
import Foundation
import PrivacyKit
import SwiftUI

struct HiroAlertJournalView: View {
    @ObservedObject private var viewingLock = PrivacyLockController.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var rows: [JournalAlert] = []
    @State private var unavailable = false

    var body: some View {
        Group {
            if viewingLock.isLocked || scenePhase != .active {
                Color.clear
            } else {
                List {
                    Section {
                        HStack {
                            Text("Time").frame(width: 58, alignment: .leading)
                            Text("Original alert content").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Status")
                        }.font(.caption).foregroundStyle(.secondary)
                        ForEach(rows) { row in
                            NavigationLink {
                                HiroAlertJournalDetail(row: row)
                            } label: {
                                HStack(alignment: .top) {
                                    Text(row.issuedAt, format: .dateTime.hour().minute())
                                        .font(.caption.monospacedDigit()).frame(width: 58, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(row.title).font(.subheadline)
                                        Text(row.source).font(.caption).foregroundStyle(.secondary)
                                        Text(row.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Text(status(row)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if unavailable { Text("History is temporarily unavailable. Try again after unlocking the device.").foregroundStyle(.secondary) }
                        else if rows.isEmpty { Text("No alerts in the past 24 hours").foregroundStyle(.secondary) }
                    } footer: {
                        Text("Issued or scheduled does not confirm that a sound was heard.")
                    }
                }
            }
        }
        .navigationTitle("Alert History (24 Hours)")
        .onAppear { reload() }
        .onReceive(Foundation.NotificationCenter.default.publisher(for: HiroAlertJournal.changed)) { _ in reload() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { reload() } else { rows = [] } }
        .onChange(of: viewingLock.isLocked) { _, _ in reload() }
    }

    private func reload() {
        rows = viewingLock.isLocked || scenePhase != .active ? [] : HiroAlertJournal.shared.recent()
        unavailable = HiroAlertJournal.shared.unavailable
    }

    private func status(_ row: JournalAlert) -> LocalizedStringKey {
        if row.resolvedAt != nil { return "Resolved" }
        if row.acknowledgedAt != nil { return "Acknowledged" }
        if let scheduled = row.scheduledFor, scheduled > Date() { return "Scheduled" }
        return "Issued"
    }
}

private struct HiroAlertJournalDetail: View {
    let row: JournalAlert
    @ObservedObject private var viewingLock = PrivacyLockController.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            if !viewingLock.isLocked && scenePhase == .active {
                Form {
                    Section("Original alert content") { Text(row.title); Text(row.body) }
                    Section("Source") { Text(row.source); Text(row.kind) }
                    Section("Time") {
                        LabeledContent("Issued at", value: row.issuedAt.formatted())
                        if let date = row.scheduledFor { LabeledContent("Scheduled for", value: date.formatted()) }
                        if let date = row.acknowledgedAt { LabeledContent("Acknowledged at", value: date.formatted()) }
                        if let date = row.resolvedAt { LabeledContent("Resolved at", value: date.formatted()) }
                    }
                }
            } else { Color.clear }
        }.navigationTitle("Alert Details")
    }
}
