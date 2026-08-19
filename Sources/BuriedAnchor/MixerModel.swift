import AppKit
import CoreAudio
import Foundation
import Observation

@MainActor
@Observable
final class MixerModel {
    struct Row: Identifiable {
        let id: SourceID
        var name: String
        var icon: NSImage?
        var objectIDs: [AudioObjectID]
        var isPlaying: Bool
        var percent: Double
        var level: Float
        var isControlled: Bool
        var isActive: Bool
    }

    private(set) var rows: [Row] = []
    private(set) var permission: CapturePermission = .unknown(noErr)
    private(set) var clipping = false
    private(set) var engineError: String?
    private(set) var launchAtLogin = false
    private(set) var loginItemNotice: String?
    private(set) var outputDeviceName = "-"

    var softClip: Bool {
        didSet {
            UserDefaults.standard.set(softClip, forKey: Self.softClipKey)
            engine.renderer.setSoftClip(softClip)
        }
    }

    private struct Presentation {
        let name: String
        let icon: NSImage?
    }

    private let registry = ProcessRegistry()
    private let engine = TapEngine()
    private var percents: [SourceID: Double] = [:]
    private var premute: [SourceID: Double] = [:]
    private var timer: Timer?
    private var processListListener: PropertyListener?
    private var activityListeners: [AudioObjectID: [PropertyListener]] = [:]
    private var objectOwners: [AudioObjectID: SourceID] = [:]
    private var objectBaseline = false
    private var reconcilePending = false
    private var tick = 0
    private var idleSince: Date?
    private var started = false
    private var presentation: [SourceID: Presentation] = [:]
    private var lastPlaying: [SourceID: Date] = [:]
    private var lastLive: [SourceID: Date] = [:]
    private var liveKeys: Set<SourceID> = []
    private var playingKeys: Set<SourceID> = []

    private let suspendAfter: TimeInterval = 1.5
    private let meterFloor: Float = 0.0002
    private let lingerInterval: TimeInterval = 300
    private let tapRetention: TimeInterval = 300
    private static let activitySelectors: [AudioObjectPropertySelector] = [
        kAudioProcessPropertyIsRunning,
        kAudioProcessPropertyIsRunningOutput
    ]
    private static let defaultsKey = "appVolumePercents"
    private static let premuteKey = "appVolumePremute"
    private static let softClipKey = "softClip"

    init() {
        percents = Self.loadPercents(Self.defaultsKey)
        premute = Self.loadPercents(Self.premuteKey)
        softClip = UserDefaults.standard.bool(forKey: Self.softClipKey)
        launchAtLogin = LoginItem.isEnabled
        normalizeStorage(Self.defaultsKey, percents)
        normalizeStorage(Self.premuteKey, premute)
    }

    func start() {
        guard !started else { return }
        started = true
        permission = AudioCapturePermission.probe()
        engine.renderer.setSoftClip(softClip)
        engine.start()
        outputDeviceName = engine.outputDeviceName
        processListListener = PropertyListener(
            systemObject,
            propertyAddress(kAudioHardwarePropertyProcessObjectList)
        ) { [weak self] in
            Task { @MainActor in self?.handleProcessListChange() }
        }
        refreshList()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        processListListener = nil
        activityListeners.removeAll()
        engine.shutdown()
    }

    func savedPercent(for id: SourceID) -> Double? { percents[id] }

    func setPercent(_ value: Double, for id: SourceID) {
        let clamped = min(max(value, 0), 150).rounded()
        percents[id] = clamped
        persist(percents, forKey: Self.defaultsKey)
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].percent = clamped
        if !permission.isGranted {
            permission = AudioCapturePermission.probe()
        }
        if clamped != 100 {
            _ = claimSlot(for: id, force: true)
        }
        applyGain(clamped, for: id, objectIDs: rows[index].objectIDs)
        rows[index].isControlled = engine.isControlled(id)
        rows[index].isActive = engine.isActive(id)
        engineError = engine.lastError
        idleSince = nil
        updateSuspension()
    }

    func toggleMute(_ id: SourceID) {
        let current = rows.first { $0.id == id }?.percent ?? percents[id] ?? 100
        if current > 0 {
            premute[id] = current
            persist(premute, forKey: Self.premuteKey)
            setPercent(0, for: id)
        } else {
            let restored = premute[id].flatMap { $0 > 0 ? $0 : nil } ?? 100
            premute.removeValue(forKey: id)
            persist(premute, forKey: Self.premuteKey)
            setPercent(restored, for: id)
        }
    }

    func reset(_ id: SourceID) {
        percents.removeValue(forKey: id)
        persist(percents, forKey: Self.defaultsKey)
        premute.removeValue(forKey: id)
        persist(premute, forKey: Self.premuteKey)
        engine.release(id)
        lastLive.removeValue(forKey: id)
        engineError = engine.lastError
        if let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].percent = 100
            rows[index].isControlled = false
            rows[index].isActive = false
            rows[index].level = 0
        }
    }

    func recheckPermission() {
        permission = AudioCapturePermission.probe()
    }

    func refreshSettingsState() {
        launchAtLogin = LoginItem.isEnabled
        permission = AudioCapturePermission.probe()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            loginItemNotice = LoginItem.requiresApproval
                ? "Buried Anchor is waiting for approval in System Settings › General › Login Items."
                : nil
        } catch {
            loginItemNotice = "Could not \(enabled ? "enable" : "disable") it: \(error.localizedDescription)"
            log.error("login item toggle failed: \(error.localizedDescription, privacy: .public)")
        }
        launchAtLogin = LoginItem.isEnabled
    }

    func engineDiagnostics() -> [String] { engine.diagnostics() }

    private static func loadPercents(_ key: String) -> [SourceID: Double] {
        let stored = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        var result: [SourceID: Double] = [:]
        for (raw, value) in stored where value.isFinite {
            let id = SourceID(raw: raw)
            guard id.isDurable else { continue }
            result[id] = min(max(value, 0), 150).rounded()
        }
        return result
    }

    private func normalizeStorage(_ key: String, _ values: [SourceID: Double]) {
        let stored = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        let normalized = Self.encode(values)
        guard stored != normalized else { return }
        log.debug("normalized \(key, privacy: .public): \(stored.count) -> \(normalized.count) entries")
        UserDefaults.standard.set(normalized, forKey: key)
    }

    private static func encode(_ values: [SourceID: Double]) -> [String: Double] {
        values.reduce(into: [String: Double]()) { result, entry in
            guard entry.key.isDurable else { return }
            result[entry.key.raw] = entry.value
        }
    }

    private func persist(_ values: [SourceID: Double], forKey key: String) {
        UserDefaults.standard.set(Self.encode(values), forKey: key)
    }

    private func applyGain(_ percent: Double, for id: SourceID, objectIDs: [AudioObjectID]) {
        guard permission.isGranted || engine.isControlled(id) else { return }
        engine.setGain(Float(percent / 100), for: id, objectIDs: objectIDs)
        if engine.isControlled(id) { lastLive[id] = Date() }
    }

    private func claimSlot(for id: SourceID, force: Bool = false) -> Bool {
        if engine.isControlled(id) { return true }
        guard engine.controlledCount >= MixRenderer.maxSlots else { return true }
        guard force || playingKeys.contains(id) else { return false }
        let victims = engine.controlledKeys
            .filter { !playingKeys.contains($0) }
            .sorted { (lastLive[$0] ?? .distantPast) < (lastLive[$1] ?? .distantPast) }
        guard let victim = victims.first else { return false }
        log.debug("evicting \(victim.raw, privacy: .public) to make room for \(id.raw, privacy: .public)")
        engine.release(victim)
        lastLive.removeValue(forKey: victim)
        return true
    }

    private func updateSuspension() {
        let keys = engine.controlledKeys
        guard !keys.isEmpty else {
            idleSince = nil
            return
        }
        let rendering = keys.contains { key in
            let gain = engine.gain(for: key)
            return gain != 0 && gain != 1 && playingKeys.contains(key)
        }
        guard !rendering else {
            idleSince = nil
            engine.resume()
            return
        }
        let now = Date()
        let since = idleSince ?? now
        idleSince = since
        guard now.timeIntervalSince(since) >= suspendAfter else { return }
        engine.suspend()
    }

    private func scheduleReconcile() {
        guard !reconcilePending else { return }
        reconcilePending = true
        Task { @MainActor in
            self.reconcilePending = false
            self.refreshList()
        }
    }

    private func syncActivityListeners() {
        let objectIDs = registry.objectIDs
        for objectID in activityListeners.keys where !objectIDs.contains(objectID) {
            activityListeners.removeValue(forKey: objectID)
        }
        for objectID in objectIDs where activityListeners[objectID] == nil {
            activityListeners[objectID] = Self.activitySelectors.compactMap { selector in
                PropertyListener(objectID, propertyAddress(selector)) { [weak self] in
                    Task { @MainActor in self?.handleActivityChange() }
                }
            }
        }
    }

    private func handleProcessListChange() {
        coverNewObjects()
        scheduleReconcile()
    }

    private func coverNewObjects() {
        let live = registry.objectIDList()
        let fresh = live.filter { objectOwners[$0] == nil }
        guard !fresh.isEmpty else { return }
        var waking = false
        for objectID in fresh {
            guard let key = registry.owner(of: objectID), isManaged(key) else { continue }
            objectOwners[objectID] = key
            waking = true
            guard engine.isControlled(key) else { continue }
            engine.syncObjectIDs(live.filter { objectOwners[$0] == key }.sorted(), for: key)
        }
        guard waking else { return }
        idleSince = nil
        engine.resume()
    }

    private func handleActivityChange() {
        pulsePlayback()
        updateSuspension()
        scheduleReconcile()
    }

    private func pulsePlayback() {
        let controlled = Set(engine.controlledKeys)
        guard !controlled.isEmpty else { return }
        var running: Set<SourceID> = []
        for (objectID, key) in objectOwners where controlled.contains(key) {
            guard objectID.value(
                propertyAddress(kAudioProcessPropertyIsRunningOutput), default: UInt32(0)
            ) != 0 else { continue }
            running.insert(key)
        }
        playingKeys.subtract(controlled)
        playingKeys.formUnion(running)
        let now = Date()
        for key in running { lastPlaying[key] = now }
    }

    private func isManaged(_ key: SourceID) -> Bool {
        engine.isControlled(key) || (percents[key].map { $0 != 100 } ?? false)
    }

    private func onTick() {
        tick += 1
        engine.retryIfDue()
        if tick % 10 == 0 {
            refreshList()
            registry.forgetTerminated()
        }
        refreshMeters()
        pulsePlayback()
        updateSuspension()
        if outputDeviceName != engine.outputDeviceName {
            outputDeviceName = engine.outputDeviceName
        }
        if engineError != engine.lastError {
            engineError = engine.lastError
        }
    }

    private func refreshList() {
        let groups = registry.snapshot()
        syncActivityListeners()
        let now = Date()
        liveKeys = Set(groups.filter { !$0.objectIDs.isEmpty }.map(\.id))
        playingKeys = Set(groups.filter(\.isPlaying).map(\.id))

        let owners = groups.reduce(into: [AudioObjectID: SourceID]()) { map, group in
            for objectID in group.objectIDs { map[objectID] = group.id }
        }
        let appeared = objectBaseline ? Set(owners.keys).subtracting(objectOwners.keys) : []
        objectBaseline = true
        objectOwners = owners
        if appeared.contains(where: { owners[$0].map(isManaged) ?? false }) {
            idleSince = nil
            engine.resume()
        }

        for group in groups {
            presentation[group.id] = Presentation(name: group.name, icon: group.icon)
            if group.isPlaying { lastPlaying[group.id] = now }
            if engine.isControlled(group.id) {
                engine.syncObjectIDs(group.objectIDs, for: group.id)
                lastLive[group.id] = now
                continue
            }
            guard let saved = percents[group.id], saved != 100, !group.objectIDs.isEmpty,
                  claimSlot(for: group.id)
            else { continue }
            applyGain(saved, for: group.id, objectIDs: group.objectIDs)
        }

        var next: [Row] = []
        next.reserveCapacity(groups.count)
        for group in groups {
            let saved = percents[group.id] ?? 100
            let recent = lastPlaying[group.id].map { now.timeIntervalSince($0) < lingerInterval } ?? false
            guard group.isPlaying || recent || engine.isControlled(group.id) || saved != 100
            else { continue }
            next.append(
                Row(
                    id: group.id,
                    name: group.name,
                    icon: group.icon,
                    objectIDs: group.objectIDs,
                    isPlaying: group.isPlaying,
                    percent: saved,
                    level: rows.first { $0.id == group.id }?.level ?? 0,
                    isControlled: engine.isControlled(group.id),
                    isActive: engine.isActive(group.id)
                )
            )
        }

        let known = Set(next.map(\.id))
        let absent = Set(engine.controlledKeys).union(
            lastPlaying.filter { now.timeIntervalSince($0.value) < lingerInterval }.keys
        ).subtracting(known)
        for key in absent {
            next.append(
                Row(
                    id: key,
                    name: presentation[key]?.name ?? key.fallbackName,
                    icon: presentation[key]?.icon,
                    objectIDs: [],
                    isPlaying: false,
                    percent: percents[key] ?? 100,
                    level: 0,
                    isControlled: engine.isControlled(key),
                    isActive: false
                )
            )
        }

        next.sort {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        lastPlaying = lastPlaying.filter { now.timeIntervalSince($0.value) < lingerInterval }
        presentation = presentation.filter {
            liveKeys.contains($0.key) || lastPlaying[$0.key] != nil
                || percents[$0.key] != nil || engine.isControlled($0.key)
        }
        rows = next
        sweepRetention(now)
        engineError = engine.lastError
        outputDeviceName = engine.outputDeviceName
        updateSuspension()
    }

    private func sweepRetention(_ now: Date) {
        let controlled = engine.controlledKeys
        guard !controlled.isEmpty else { return }
        for key in controlled where liveKeys.contains(key) { lastLive[key] = now }
        let expired = controlled.filter { now.timeIntervalSince(lastLive[$0] ?? now) > tapRetention }
        guard !expired.isEmpty else { return }
        let busy = controlled.contains { playingKeys.contains($0) }
        guard engine.isSuspended || !busy else { return }
        log.debug("retention released \(expired.map(\.raw).joined(separator: ","), privacy: .public)")
        engine.release(expired)
        for key in expired { lastLive.removeValue(forKey: key) }
        for index in rows.indices where expired.contains(rows[index].id) {
            rows[index].isControlled = false
            rows[index].isActive = false
            rows[index].level = 0
        }
    }

    private func refreshMeters() {
        let keys = engine.controlledKeys
        guard !keys.isEmpty else {
            if clipping { clipping = false }
            return
        }
        for (slot, key) in keys.enumerated() {
            let peak = engine.renderer.takePeak(slot: slot)
            guard let index = rows.firstIndex(where: { $0.id == key }) else { continue }
            var next = max(peak, rows[index].level * 0.7)
            if next < meterFloor { next = 0 }
            guard next != rows[index].level else { continue }
            rows[index].level = next
        }
        let isClipping = engine.renderer.takeClipCount() > 0
        if isClipping != clipping { clipping = isClipping }
    }
}
