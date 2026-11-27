import Foundation

@main enum NotificationHandoffChecks {
    @MainActor static func main() {
        let handoff = HiroNotificationResponseHandoff<String>()
        var delivered: [String] = []
        handoff.receive("default tap")
        handoff.receive("snooze action")
        precondition(delivered.isEmpty, "Must not invoke unavailable services")
        handoff.attach { delivered.append($0) }
        precondition(delivered == ["default tap", "snooze action"], "Cold responses must replay once in order")
        handoff.attach { delivered.append($0) }
        precondition(delivered.count == 2, "Attaching again must not replay old responses")
        handoff.receive("dismiss action")
        precondition(delivered == ["default tap", "snooze action", "dismiss action"], "Warm responses must forward once")
        print("Notification response handoff: cold replay, no duplicate replay, and warm forwarding passed")
    }
}
