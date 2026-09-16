import CoreAudio
import Foundation

struct DiscoveredObject: Sendable {
    let objectID: AudioObjectID
    let key: SourceID
    let pid: pid_t
    let isDirect: Bool
}

struct DiscoveryCoverage: Sendable {
    let live: [AudioObjectID]
    let fresh: [DiscoveredObject]
}

final class DiscoveryWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.buriedanchor.discovery", qos: .userInitiated)
    private let registry = ProcessRegistry()
    private var activityListeners: [AudioObjectID: [PropertyListener]] = [:]
    private let onActivity: @Sendable (Int) -> Void

    private static let activitySelectors: [AudioObjectPropertySelector] = [
        kAudioProcessPropertyIsRunning,
        kAudioProcessPropertyIsRunningOutput
    ]

    init(onActivity: @escaping @Sendable (Int) -> Void) {
        self.onActivity = onActivity
    }

    func snapshot(generation: Int, _ completion: @escaping @Sendable ([AudioAppGroup]) -> Void) {
        queue.async { [self] in
            let groups = registry.snapshot()
            syncActivityListeners(generation: generation)
            completion(groups)
        }
    }

    func cover(known: Set<AudioObjectID>, _ completion: @escaping @Sendable (DiscoveryCoverage) -> Void) {
        queue.async { [self] in
            let live = registry.objectIDList()
            let fresh = live.filter { !known.contains($0) }.compactMap { objectID -> DiscoveredObject? in
                guard let owner = registry.owner(of: objectID) else { return nil }
                let pid = objectID.value(propertyAddress(kAudioProcessPropertyPID), default: pid_t(-1))
                return DiscoveredObject(
                    objectID: objectID, key: owner.key, pid: pid, isDirect: owner.isDirect
                )
            }
            completion(DiscoveryCoverage(live: live, fresh: fresh))
        }
    }

    func forgetTerminated() {
        queue.async { [self] in registry.forgetTerminated() }
    }

    func reset() {
        queue.async { [self] in
            activityListeners.removeAll()
            registry.reset()
        }
    }

    func shutdown() {
        queue.async { [self] in activityListeners.removeAll() }
    }

    private func syncActivityListeners(generation: Int) {
        let objectIDs = registry.objectIDs
        for objectID in activityListeners.keys where !objectIDs.contains(objectID) {
            activityListeners.removeValue(forKey: objectID)
        }
        for objectID in objectIDs where activityListeners[objectID] == nil {
            activityListeners[objectID] = Self.activitySelectors.compactMap { selector in
                PropertyListener(objectID, propertyAddress(selector)) { [onActivity] in
                    onActivity(generation)
                }
            }
        }
    }
}
