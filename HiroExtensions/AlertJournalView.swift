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
                        ForEach(rows.filter { $0.triggeredAt != nil }) { row in journalRow(row) }
                        if unavailable { Text("History is temporarily unavailable. Try again after unlocking the device.").foregroundStyle(.secondary) }
                        else if !rows.contains(where: { $0.triggeredAt != nil }) { Text("No observed alerts").foregroundStyle(.secondary) }
                    } footer: {
                        Text("Only observed triggers or delivered notifications appear above. Delivery does not confirm that a sound was heard. Records are kept for 24 hours.")
                    }
                    Section("Upcoming plans") {
                        ForEach(rows.filter(isUpcoming)) { row in journalRow(row) }
                        if !rows.contains(where: isUpcoming) { Text("No upcoming plans").foregroundStyle(.secondary) }
                    }
                    Section {
                        DisclosureGroup("Cancelled or unverified records") {
                            ForEach(rows.filter { $0.triggeredAt == nil && !isUpcoming($0) }) { row in journalRow(row) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Alert History")
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
        if row.triggeredAt != nil && row.resolvedAt != nil { return "Resolved" }
        if row.acknowledgedAt != nil { return "Acknowledged" }
        if row.cancelledAt != nil { return "Cancelled" }
        if row.triggeredAt != nil { return "Observed trigger" }
        if isUpcoming(row) { return "Scheduled" }
        return "Unverified"
    }
    private func isUpcoming(_ row: JournalAlert) -> Bool {
        row.triggeredAt == nil && row.resolvedAt == nil && row.acknowledgedAt == nil &&
            row.scheduledFor.map { $0 > Date() } == true
    }
    private func journalRow(_ row: JournalAlert) -> some View {
        NavigationLink { HiroAlertJournalDetail(row: row) } label: {
            HStack(alignment: .top) {
                Text(row.triggeredAt ?? row.scheduledFor ?? row.issuedAt, format: .dateTime.hour().minute())
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
                        if let date = row.triggeredAt { LabeledContent("Observed at", value: date.formatted()) }
                        if let date = row.acknowledgedAt { LabeledContent("Acknowledged at", value: date.formatted()) }
                        if let date = row.cancelledAt { LabeledContent("Cancelled at", value: date.formatted()) }
                        else if let date = row.resolvedAt { LabeledContent(LocalizedStringKey(row.triggeredAt == nil ? "Ended at" : "Resolved at"), value: date.formatted()) }
                    }
                }
            } else { Color.clear }
        }.navigationTitle("Alert Details")
    }
}
