import ActivityKit
import Combine
import CoreData
import Foundation
import Swinject
import UIKit
import PrivacyKit
import OttaiKit

@available(iOS 16.2, *) private struct ActiveActivity {
    let activity: Activity<LiveActivityAttributes>

    /// Determines if the current activity needs to be recreated.
    ///
    /// Private content can refresh an expired reading in place; a stale flag alone need not recreate its activity.
    func needsRecreation(updatingPrivateContent: Bool) -> Bool {
        switch activity.activityState {
        case .dismissed,
             .ended:
            return true
        case .stale:
            break
        case .active:
            break
        @unknown default:
            return true
        }
        return false
    }
}

final class LiveActivityData: ObservableObject {
    /// Determination data used to update live activity state.
    @Published var determination: DeterminationData?
    /// The most recent IoB data
    @Published var iob: Decimal?
    /// Array of glucose readings fetched from persistent storage.
    @Published var glucoseFromPersistence: [GlucoseData]?
    /// The current override data (if any).
    @Published var override: OverrideData?
    /// The current temp target data (if any).
    @Published var tempTarget: TempTargetData?
    /// The widget items displayed within the live activity.
    @Published var widgetItems: [LiveActivityAttributes.LiveActivityItem]?
}

/// A service managing live activity updates and state management.
///
/// This class handles the creation, update, and termination of live activities based on various data sources
/// (e.g. Core Data notifications, glucose updates, settings changes). It integrates with system notifications,
/// dependency injection, and user defaults to ensure that the live activity reflects the current app state.
///
/// Additionally, it supports a restart functionality (via `restartActivityFromLiveActivityIntent()`)
/// via iOS shortcuts, similar to other iOS apps like xDrip4iOS or Sweet Dreams.
@available(iOS 16.2, *) final class LiveActivityManager: Injectable, ObservableObject, SettingsObserver {
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var storage: FileStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var iobService: IOBService!

    private let activityAuthorizationInfo = ActivityAuthorizationInfo()
    /// Indicates whether system live activities are enabled.
    @Published private(set) var systemEnabled: Bool

    /// Returns the current Trio settings.
    private var settings: TrioSettings {
        settingsManager.settings
    }

    /// The current active live activity.
    private var currentActivity: ActiveActivity?

    private var data = LiveActivityData()
    private var recoveredGridReceipt: (measuredAt: Date, receivedAt: Date)?
    private var lastPublicationEvent = Date.distantPast
    @MainActor private static var publicationQueue: ActivityPublicationQueue?
    private var activityStateTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var creationWindow: TimeInterval = 0
    private var creationAttempts = 0

    /// A dispatch queue for handling Core Data change notifications.
    private let queue = DispatchQueue(label: "LiveActivityBridge.queue", qos: .userInitiated)
    private var coreDataPublisher: AnyPublisher<Set<NSManagedObjectID>, Never>?
    private var subscriptions = Set<AnyCancellable>()

    /// Initializes a new instance of `LiveActivityBridge` and sets up observers, subscribers, and notifications.
    ///
    /// - Parameter resolver: The dependency injection resolver.
    init(resolver: Resolver) {
        coreDataPublisher =
            CoreDataStack.shared.entityChangePublisher
                .receive(on: queue)
                .share()
                .eraseToAnyPublisher()

        systemEnabled = activityAuthorizationInfo.areActivitiesEnabled
        injectServices(resolver)
        setupNotifications()
        registerHandler()
        monitorForLiveActivityAuthorizationChanges()
        broadcaster.register(SettingsObserver.self, observer: self)
        data.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                // by the time this runs, the object change is done, so we see the new data here
                await self?.pushCurrentContent()
            }
        }.store(in: &subscriptions)
        loadInitialData()
    }

    deinit { activityStateTask?.cancel(); retryTask?.cancel() }

    /// Sets up application notifications that trigger live activity updates when the app state changes.
    private func setupNotifications() {
        let notificationCenter = Foundation.NotificationCenter.default
        notificationCenter.addObserver(self, selector: #selector(privacyChanged), name: PrivacyPreference.changed, object: nil)
        notificationCenter.addObserver(
            forName: OttaiGridRecoveryReceipt.notification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let measuredAt = notification.userInfo?[OttaiGridRecoveryReceipt.measuredAtKey] as? Date,
                  let receivedAt = notification.userInfo?[OttaiGridRecoveryReceipt.receivedAtKey] as? Date
            else { return }
            Task { @MainActor in
                guard let self else { return }
                // Match this receipt to its actual saved sample before granting display freshness.
                self.recoveredGridReceipt = (measuredAt, receivedAt)
                await self.pushCurrentContent()
            }
        }
        notificationCenter
            .addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in
                    await self?.pushCurrentContent()
                }
            }
        notificationCenter
            .addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in
                    await self?.pushCurrentContent()
                }
            }
        notificationCenter.addObserver(
            self,
            selector: #selector(loadWidgetItems),
            name: .liveActivityOrderDidChange,
            object: nil
        )
    }

    @objc private func privacyChanged() {
        Task { @MainActor in await self.pushCurrentContent() }
    }

    /// Called when the app settings change.
    ///
    /// This method triggers an update to the live activity content state based on the new settings.
    /// - Parameter _: The updated `TrioSettings`.
    func settingsDidChange(_: TrioSettings) {
        Task { @MainActor in
            await self.pushCurrentContent()
        }
    }

    /// Registers handlers for Core Data changes related to overrides, glucose readings, and determinations.
    private func registerHandler() {
        coreDataPublisher?.filteredByEntityName("OverrideStored").sink { [weak self] _ in
            Task { await self?.loadOverrides() }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("TempTargetStored").sink { [weak self] _ in
            Task { await self?.loadTempTarget() }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("GlucoseStored").sink { [weak self] _ in
            Task { await self?.loadGlucose() }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("OrefDetermination")
            .debounce(for: .seconds(2), scheduler: DispatchQueue.global(qos: .utility))
            .sink { [weak self] _ in
                Task { await self?.loadDetermination() }
            }.store(in: &subscriptions)

        iobService.iobPublisher
            .debounce(for: .seconds(2), scheduler: DispatchQueue.global(qos: .utility))
            .sink { [weak self] _ in
                self?.data.iob = self?.iobService.currentIOB
            }.store(in: &subscriptions)
    }

    /// Fetches and maps new determination data and updates the live activity content state.
    private func loadDetermination() async {
        do {
            data.determination = try await fetchAndMapDetermination()
        } catch {
            warning(.liveActivity, "Fetching determination for Live Activity failed", error: error)
        }
    }

    /// Fetches and maps override data and updates the live activity content state.
    private func loadOverrides() async {
        do {
            data.override = try await fetchAndMapOverride()
        } catch {
            warning(.liveActivity, "Fetching override for Live Activity failed", error: error)
        }
    }

    /// Fetches and maps temp target data and updates the live activity content state.
    private func loadTempTarget() async {
        do {
            data.tempTarget = try await fetchAndMapTempTarget()
        } catch {
            warning(.liveActivity, "Fetching temp target for Live Activity failed", error: error)
        }
    }

    /// Handles changes to the live activity order.
    ///
    /// Loads widget items from user defaults and triggers an update to the live activity order.
    @objc private func loadWidgetItems() {
        data.widgetItems = UserDefaults.standard.loadLiveActivityOrderFromUserDefaults() ?? LiveActivityAttributes
            .LiveActivityItem.defaultItems
    }

    /// Sets up the array of glucose data from persistent storage and triggers an update to the live activity.
    @MainActor private func loadGlucose() async {
        do {
            data.glucoseFromPersistence = try await fetchAndMapGlucose()
        } catch {
            warning(.liveActivity, "Fetching glucose for Live Activity failed", error: error)
        }
    }

    private func loadInitialData() {
        Task {
            await self.loadGlucose()
            await self.loadOverrides()
            await self.loadTempTarget()
            await self.loadDetermination()
            self.loadWidgetItems()
        }
    }

    /// Monitors live activity authorization changes and updates the `systemEnabled` flag.
    private func monitorForLiveActivityAuthorizationChanges() {
        Task {
            for await activityState in activityAuthorizationInfo.activityEnablementUpdates {
                if activityState != systemEnabled {
                    await MainActor.run {
                        systemEnabled = activityState
                    }
                }
            }
        }
    }

    /// Pushes an update to the live activity with the specified content state.
    ///
    /// If an existing activity requires recreation or is outdated, this method ends it and starts a new one.
    /// Otherwise, it updates the current live activity.
    ///
    /// - Parameter state: The new content state to push to the live activity.
    @MainActor private func pushUpdate(_ state: LiveActivityAttributes.ContentState,
                                      isAuthorized: @escaping @MainActor () -> Bool = { true }) async {
        let queue = Self.publicationQueue ?? ActivityPublicationQueue()
        Self.publicationQueue = queue
        await queue.run(coalescing: true) { [weak self] in
            await self?.pushUpdateInOrder(state, isAuthorized: isAuthorized)
        }
    }

    @MainActor private func pushUpdateInOrder(_ state: LiveActivityAttributes.ContentState,
                                             isAuthorized: @escaping @MainActor () -> Bool) async {
        guard isAuthorized() else { return }
        // Reject an older queued update after the user switches display mode.
        guard (state.privacy != nil) == PrivacyPreference.displayEnabled else { return }
        if !settings.useLiveActivity || !systemEnabled {
            await endActivity(isAuthorized: isAuthorized)
            return
        }

        // Elect a usable owner before retiring duplicates; the tracked owner may have just ended.
        if let currentActivity, currentActivity.needsRecreation(updatingPrivateContent: state.privacy != nil) {
            self.currentActivity = nil
            activityStateTask?.cancel()
        }
        if currentActivity == nil {
            // try to restore an existing activity
            currentActivity = Activity<LiveActivityAttributes>.activities
                .filter { $0.activityState == .active || $0.activityState == .stale }
                .max { $0.attributes.startDate < $1.attributes.startDate }.map {
                    ActiveActivity(activity: $0)
                }

            if let currentActivity {
                debug(.liveActivity, "Restored Live Activity \(currentActivity.activity.id)")
                observeState(of: currentActivity.activity)
            }
        }

        // End all unknown activities except the current one
        for unknownActivity in Activity<LiveActivityAttributes>.activities
            .filter({ self.currentActivity?.activity.id != $0.id && ($0.activityState == .active || $0.activityState == .stale) })
        {
            guard isAuthorized() else { return }
            await unknownActivity.end(nil, dismissalPolicy: .immediate)
        }

        guard isAuthorized(), (state.privacy != nil) == PrivacyPreference.displayEnabled else { return }
        if let currentActivity {
            let terminal = currentActivity.needsRecreation(updatingPrivateContent: state.privacy != nil)
            if terminal && UIApplication.shared.applicationState != .active {
                self.currentActivity = nil
                activityStateTask?.cancel()
                recordLifecycle("deferred")
                return
            }
            if terminal {
                debug(.liveActivity, "Recreating Live Activity \(currentActivity.activity.id)")
                await endActivity(isAuthorized: isAuthorized)
                guard isAuthorized() else { return }
                // After endActivity(), currentActivity is guaranteed to be nil
                // No recursive task, but explicitly restart
                debug(.liveActivity, "Pushing update after recreation")
                await pushUpdateInOrder(state, isAuthorized: isAuthorized)
            } else {
                let content = ActivityContent(
                    state: state,
                    staleDate: state.privacy?.staleDate ?? min(state.glucoseMeasuredAt ?? state.date ?? Date.now, Date.now).addingTimeInterval(300)
                )
                // Before the update, check if currentActivity is still valid
                if let stillCurrent = self.currentActivity, stillCurrent.activity.id == currentActivity.activity.id {
                    guard isAuthorized(), (state.privacy != nil) == PrivacyPreference.displayEnabled else { return }
                    debug(.liveActivity, "Updating Live Activity \(stillCurrent.activity.id)")
                    await stillCurrent.activity.update(content)
                    recordPublication()
                } else {
                    debug(.liveActivity, "Update skipped, activity changed during push")
                }
            }
        } else {
            guard ActivityLifecyclePolicy.action(state: nil,
                foreground: UIApplication.shared.applicationState == .active, enabled: true) == .create else {
                recordLifecycle("deferred")
                return
            }
            let uptime = ProcessInfo.processInfo.systemUptime
            if uptime - creationWindow >= 60 { creationWindow = uptime; creationAttempts = 0 }
            guard creationAttempts < 3 else { scheduleRetry(); recordLifecycle("deferred"); return }
            creationAttempts += 1
            // ... Activity is newly created ...
            do {
                let expired = ActivityContent(
                    state: LiveActivityAttributes
                        .ContentState(
                            unit: settings.units.rawValue,
                            bg: "--",
                            glucose: nil,
                            direction: nil,
                            change: "--",
                            date: Date.now,
                            highGlucose: settings.high,
                            lowGlucose: settings.low,
                            target: data.determination?.target ?? 100 as Decimal,
                            glucoseColorScheme: settings.glucoseColorScheme.rawValue,
                            useDetailedViewIOS: false,
                            useDetailedViewWatchOS: false,
                            simpleViewStyle: LiveActivityAttributes.SimpleViewStyle(settings: settings),
                            detailedViewState: LiveActivityAttributes.ContentAdditionalState(
                                chart: [],
                                rotationDegrees: 0,
                                cob: 0,
                                iob: 0,
                                tdd: 0,
                                isOverrideActive: false,
                                overrideName: "",
                                overrideDate: Date.now,
                                overrideDuration: 0,
                                overrideTarget: 0,
                                isTempTargetActive: false,
                                tempTargetName: "",
                                tempTargetDate: Date.now,
                                tempTargetDuration: 0,
                                tempTargetTarget: 0,
                                widgetItems: [],
                                minForecast: [],
                                maxForecast: [],
                                forecastLines: [],
                                forecastDisplayType: ForecastDisplayType.cone.rawValue
                            ),
                            isInitialState: true,
                            privacy: PrivacyPreference.displayEnabled ? PrivacyActivityState(
                                readings: [], now: Date(),
                                cover: UserDefaults.standard.data(forKey: PrivacyPreference.coverKey)
                            ) : nil
                        ),
                    staleDate: Date.now.addingTimeInterval(60)
                )

                // A private start already has a sanitized snapshot. Do not briefly publish an empty ring first.
                let initialContent = state.privacy != nil
                    ? ActivityContent(state: state, staleDate: state.privacy?.staleDate)
                    : expired
                guard isAuthorized(), (state.privacy != nil) == PrivacyPreference.displayEnabled else { return }
                let activity = try Activity.request(
                    attributes: LiveActivityAttributes(startDate: Date.now),
                    content: initialContent,
                    pushType: nil
                )
                currentActivity = ActiveActivity(activity: activity)
                observeState(of: activity)
                retryTask?.cancel(); retryTask = nil
                recordLifecycle("created")
                recordPublication()
                info(.liveActivity, "Started Live Activity \(activity.id)")

                // Update the newly created activity with actual data
                let updateContent = ActivityContent(
                    state: state,
                    staleDate: state.privacy?.staleDate ?? min(state.glucoseMeasuredAt ?? state.date ?? Date.now, Date.now).addingTimeInterval(300)
                )
                guard isAuthorized() else { return }
                await activity.update(updateContent)
                debug(.liveActivity, "Set initial content for Live Activity \(activity.id)")
            } catch {
                warning(.liveActivity, "Starting Live Activity failed, will retry on next update", error: error)
                // Reset currentActivity on error to allow retry on next update
                currentActivity = nil
                recordLifecycle("failed")
                scheduleRetry()
            }
        }
    }

    @MainActor private func observeState(of activity: Activity<LiveActivityAttributes>) {
        activityStateTask?.cancel()
        activityStateTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled, let self, self.currentActivity?.activity.id == activity.id else { return }
                let outcome: String
                switch state {
                case .active: outcome = "active"
                case .stale: outcome = "stale"
                case .ended: outcome = "ended"
                case .dismissed: outcome = "dismissed"
                @unknown default: outcome = "unknown"
                }
                DiagnosticEventStore.shared.record(feature: "activity", stage: "state", outcome: outcome)
                if state == .ended || state == .dismissed {
                    self.currentActivity = nil
                    self.scheduleRetry()
                    return
                }
            }
        }
    }

    @MainActor private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            guard UIApplication.shared.applicationState == .active, self.settings.useLiveActivity, self.systemEnabled else { return }
            await self.pushCurrentContent()
        }
    }

    @MainActor private func recordLifecycle(_ outcome: String) {
        DiagnosticEventStore.shared.record(feature: "activity", stage: "lifecycle", outcome: outcome)
    }

    /// Ends the current live activity and ensures that all unknown activities are terminated.
    @MainActor private func endActivity(isAuthorized: @escaping @MainActor () -> Bool = { true }) async {
        guard isAuthorized() else { return }
        debug(.liveActivity, "Ending all Live Activities")

        if let currentActivity {
            debug(.liveActivity, "Ending Live Activity \(currentActivity.activity.id)")
            self.currentActivity = nil
            activityStateTask?.cancel()
            await currentActivity.activity.end(nil, dismissalPolicy: .immediate)
            guard isAuthorized() else { return }
            if self.currentActivity?.activity.id == currentActivity.activity.id { self.currentActivity = nil }
        }

        for unknownActivity in Activity<LiveActivityAttributes>.activities.filter({ $0.activityState == .active || $0.activityState == .stale }) {
            guard isAuthorized() else { return }
            debug(.liveActivity, "Ending untracked Live Activity \(unknownActivity.id)")
            await unknownActivity.end(nil, dismissalPolicy: .immediate)
        }

        info(.liveActivity, "All Live Activities ended")
        recordLifecycle("ended")
    }

    /// Restarts the live activity from a Live Activity Intent.
    ///
    /// This method mimics xdrip's `restartActivityFromLiveActivityIntent()` behavior by verifying that a valid content state
    /// exists,
    /// ending the current live activity, and starting a new one using the current state.
    @MainActor func restartActivityFromLiveActivityIntent() async {
        let queue = Self.publicationQueue ?? ActivityPublicationQueue()
        Self.publicationQueue = queue
        await queue.run { [weak self] in await self?.endActivity() }
        await pushCurrentContent()

        info(.liveActivity, "Restarted Live Activity from shortcut")
    }
}

@available(iOS 16.2, *) extension LiveActivityManager {
    @MainActor func refreshCurrentContent(isAuthorized: @escaping @MainActor () -> Bool) async {
        do {
            try await AuthorizedSnapshot.publish(fetch: { try await self.fetchAndMapGlucose() },
                isAuthorized: isAuthorized, commit: { snapshot, authorized in
                    await self.pushContent(glucose: snapshot, isAuthorized: authorized)
                })
        } catch { warning(.liveActivity, "Recovery snapshot fetch failed", error: error) }
    }

    @MainActor func pushCurrentContent() async {
        await pushContent(glucose: data.glucoseFromPersistence, isAuthorized: { true })
    }

    /// Recovery snapshots stay local: they cannot trigger an observer-owned unguarded publication.
    @MainActor private func pushContent(glucose: [GlucoseData]?, isAuthorized: @escaping @MainActor () -> Bool) async {
        guard isAuthorized() else { return }
        guard let glucose, let bg = glucose.first else {
            if PrivacyPreference.displayEnabled {
                let previous = currentActivity?.activity.content.state ?? Activity<LiveActivityAttributes>.activities.first?.content.state
                await pushUpdate(.privateFallback(previous: previous, settings: settings), isAuthorized: isAuthorized)
            }
            debug(.liveActivity, "Live Activity not updated, no glucose available")
            return
        }
        let prevGlucose = glucose.dropFirst().first

        guard data.determination != nil || PrivacyPreference.displayEnabled else {
            debug(.liveActivity, "Live Activity not updated, no determination available")
            return
        }

        let previousPrivacy = currentActivity?.activity.content.state.privacy
            ?? Activity<LiveActivityAttributes>.activities.first?.content.state.privacy
        var recoveredAt: Date?
        if let receipt = recoveredGridReceipt, receipt.measuredAt == bg.date {
            recoveredAt = receipt.receivedAt
        } else if previousPrivacy?.measuredAt == bg.date {
            // Reusing the same reading for a setting/algorithm update must retain, not restart, its deadline.
            recoveredAt = previousPrivacy?.recoveredAt
        }
        let content = LiveActivityAttributes.ContentState(
            new: bg,
            prev: prevGlucose,
            units: settings.units,
            chart: glucose,
            settings: settings,
            determination: data.determination,
            iob: data.iob,
            override: data.override,
            tempTarget: data.tempTarget,
            widgetItems: data.widgetItems,
            privateRecoveredAt: recoveredAt
        )

        await pushUpdate(content, isAuthorized: isAuthorized)
    }

    @MainActor private func recordPublication() {
        guard Date().timeIntervalSince(lastPublicationEvent) >= 300 else { return }
        lastPublicationEvent = Date()
        DiagnosticEventStore.shared.record(feature: "privacy", stage: "activity", outcome: "published")
    }
}
