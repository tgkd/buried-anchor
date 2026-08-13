import AppKit
import CoreAudio
import Foundation
import Observation

@MainActor
@Observable
final class MixerModel {
    struct Row: Identifiable {
        let id: String
        var name: String
        var icon: NSImage?
        var objectIDs: [AudioObjectID]
        var isPlaying: Bool
        var percent: Double
        var level: Float
        var isControlled: Bool
    }

    private(set) var rows: [Row] = []
    private(set) var permission: CapturePermission = .unknown(noErr)
    private(set) var clipping = false
    private(set) var engineError: String?
    private(set) var launchAtLogin = false
    private(set) var loginItemNotice: String?

    var softClip: Bool {
        didSet {
            UserDefaults.standard.set(softClip, forKey: softClipKey)
            engine.renderer.setSoftClip(softClip)
        }
    }

    var outputDeviceName: String { engine.outputDeviceName }

    private let registry = ProcessRegistry()
    private let engine = TapEngine()
    private var percents: [String: Double] = [:]
    private var premute: [String: Double] = [:]
    private var timer: Timer?
    private var processListListener: PropertyListener?
    private var tick = 0
    private var unityTicks = 0
    private let suspendAfterTicks = 15
    private var started = false
    private struct LingerEntry {
        let name: String
        let icon: NSImage?
        let at: Date
    }

    private var lastPlaying: [String: LingerEntry] = [:]
    private let lingerInterval: TimeInterval = 300
    private let defaultsKey = "appVolumePercents"
    private let premuteKey = "appVolumePremute"
    private let softClipKey = "softClip"

    init() {
        percents = ((UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double]) ?? [:])
            .mapValues { $0.rounded() }
        premute = ((UserDefaults.standard.dictionary(forKey: premuteKey) as? [String: Double]) ?? [:])
            .mapValues { $0.rounded() }
        softClip = UserDefaults.standard.bool(forKey: softClipKey)
        launchAtLogin = LoginItem.isEnabled
    }

    func start() {
        guard !started else { return }
        started = true
        permission = AudioCapturePermission.probe()
        engine.renderer.setSoftClip(softClip)
        engine.start()
        processListListener = PropertyListener(
            systemObject,
            propertyAddress(kAudioHardwarePropertyProcessObjectList),
            queue: .main
        ) { [weak self] in
            Task { @MainActor in self?.refreshList() }
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
        engine.shutdown()
    }

    func setPercent(_ value: Double, for id: String) {
        let clamped = min(max(value, 0), 150).rounded()
        percents[id] = clamped
        UserDefaults.standard.set(percents, forKey: defaultsKey)
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].percent = clamped
        if !permission.isGranted {
            permission = AudioCapturePermission.probe()
        }
        applyGain(clamped, for: id, objectIDs: rows[index].objectIDs)
        rows[index].isControlled = engine.isControlled(id)
        engineError = engine.lastError
        unityTicks = 0
        updateSuspension()
    }

    private func updateSuspension() {
        let keys = engine.controlledKeys
        guard !keys.isEmpty else {
            unityTicks = 0
            return
        }
        guard keys.allSatisfy({ engine.gain(for: $0) == 1 }) else {
            unityTicks = 0
            engine.resume()
            return
        }
        guard unityTicks < suspendAfterTicks else { return }
        unityTicks += 1
        if unityTicks == suspendAfterTicks { engine.suspend() }
    }

    private func applyGain(_ percent: Double, for id: String, objectIDs: [AudioObjectID]) {
        guard permission.isGranted || engine.isControlled(id) else { return }
        engine.setGain(Float(percent / 100), for: id, objectIDs: objectIDs)
    }

    func toggleMute(_ id: String) {
        let current = rows.first { $0.id == id }?.percent ?? percents[id] ?? 100
        if current > 0 {
            premute[id] = current
            persistPremute()
            setPercent(0, for: id)
        } else {
            let restored = premute[id].flatMap { $0 > 0 ? $0 : nil } ?? 100
            premute.removeValue(forKey: id)
            persistPremute()
            setPercent(restored, for: id)
        }
    }

    func reset(_ id: String) {
        percents.removeValue(forKey: id)
        UserDefaults.standard.set(percents, forKey: defaultsKey)
        premute.removeValue(forKey: id)
        persistPremute()
        engine.release(id)
        engineError = engine.lastError
        if let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].percent = 100
            rows[index].isControlled = false
            rows[index].level = 0
        }
    }

    private func persistPremute() {
        UserDefaults.standard.set(premute, forKey: premuteKey)
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

    private func onTick() {
        tick += 1
        if tick % 10 == 0 {
            refreshList()
            registry.forgetTerminated()
        }
        refreshMeters()
        updateSuspension()
    }

    private func refreshList() {
        let groups = registry.snapshot()
        let controlled = Set(engine.controlledKeys)
        let now = Date()
        var next: [Row] = []
        next.reserveCapacity(groups.count)

        for group in groups {
            if controlled.contains(group.id) {
                engine.syncObjectIDs(group.objectIDs, for: group.id)
            } else if let saved = percents[group.id], saved != 100, group.isPlaying {
                applyGain(saved, for: group.id, objectIDs: group.objectIDs)
            }
            if group.isPlaying {
                lastPlaying[group.id] = LingerEntry(name: group.name, icon: group.icon, at: now)
            }
            let saved = percents[group.id] ?? 100
            let recentlyPlayed = lastPlaying[group.id]
                .map { now.timeIntervalSince($0.at) < lingerInterval } ?? false
            guard group.isPlaying || recentlyPlayed || controlled.contains(group.id) || saved != 100
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
                    isControlled: false
                )
            )
        }

        let live = Set(engine.controlledKeys)
        for index in next.indices {
            next[index].isControlled = live.contains(next[index].id)
        }

        for key in live where !next.contains(where: { $0.id == key }) {
            next.append(
                Row(
                    id: key,
                    name: key,
                    icon: nil,
                    objectIDs: [],
                    isPlaying: false,
                    percent: percents[key] ?? 100,
                    level: 0,
                    isControlled: true
                )
            )
        }

        for (key, entry) in lastPlaying
        where now.timeIntervalSince(entry.at) < lingerInterval
            && !next.contains(where: { $0.id == key }) {
            next.append(
                Row(
                    id: key,
                    name: entry.name,
                    icon: entry.icon,
                    objectIDs: [],
                    isPlaying: false,
                    percent: percents[key] ?? 100,
                    level: 0,
                    isControlled: false
                )
            )
        }

        next.sort {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        lastPlaying = lastPlaying.filter { now.timeIntervalSince($0.value.at) < lingerInterval }
        rows = next
        engineError = engine.lastError
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
            let next = max(peak, rows[index].level * 0.7)
            if abs(next - rows[index].level) > 0.002 {
                rows[index].level = next
            } else if next == 0 && rows[index].level != 0 {
                rows[index].level = 0
            }
        }
        let isClipping = engine.renderer.takeClipCount() > 0
        if isClipping != clipping { clipping = isClipping }
    }
}
