//
//  CGMManager+Observers.swift
//  OttaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

public protocol OttaiStateObserver: AnyObject {
    func ottaiCGMManager(
        _ manager: OttaiCGMManager,
        didUpdate state: OttaiCGMManagerState,
        latestSample: GlucoseSample?
    )
}

public extension OttaiCGMManager {
    func addStateObserver(_ observer: OttaiStateObserver) { stateObservers.add(observer) }
    func removeStateObserver(_ observer: OttaiStateObserver) { stateObservers.remove(observer) }

    internal func notifyStateObservers() {
        Task { @MainActor in self.evaluateAlerts() }
        stateObservers.notify { [weak self] observer in
            guard let self else { return }
            observer.ottaiCGMManager(self, didUpdate: self.state, latestSample: self.latestSample)
        }
    }
}

final class OttaiWeakObserverSet<Observer> {
    private let lock = NSLock()
    private var observers: [WeakBox] = []
    private struct WeakBox { weak var ref: AnyObject? }

    func add(_ observer: Observer) {
        let ref = observer as AnyObject
        lock.lock()
        observers.removeAll { $0.ref === ref || $0.ref == nil }
        observers.append(WeakBox(ref: ref))
        lock.unlock()
    }

    fileprivate func remove(_ observer: Observer) {
        let ref = observer as AnyObject
        lock.lock()
        observers.removeAll { $0.ref === ref || $0.ref == nil }
        lock.unlock()
    }

    func notify(_ body: @escaping (Observer) -> Void) {
        lock.lock()
        let snapshot = observers.compactMap { $0.ref as? Observer }
        observers.removeAll { $0.ref == nil }
        lock.unlock()
        DispatchQueue.main.async { for obs in snapshot { body(obs) } }
    }
}
