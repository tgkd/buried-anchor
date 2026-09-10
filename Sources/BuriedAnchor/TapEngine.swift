import CoreAudio
import Foundation

@MainActor
final class TapEngine {
    private var loop: AudioControlLoop!
    private var snapshot = EngineSnapshot()
    private var pendingPeaks: [SourceID: Float] = [:]
    private var pendingClip = false
    private var stopped = false
    var onUpdate: (() -> Void)?

    init() {
        loop = AudioControlLoop { [weak self] snapshot in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.snapshot = snapshot
                self.pendingPeaks = self.pendingPeaks.filter { snapshot.controls[$0.key] == .rendering }
                for (key, peak) in snapshot.peaks where snapshot.controls[key] == .rendering {
                    self.pendingPeaks[key] = max(self.pendingPeaks[key] ?? 0, peak)
                }
                self.pendingClip = self.pendingClip || snapshot.clipping
                self.onUpdate?()
            }
        }
    }

    var controlledKeys: [SourceID] { snapshot.order }
    var controlledCount: Int { snapshot.order.count }
    var isSuspended: Bool { !snapshot.active }
    var lastError: String? { snapshot.error }
    var outputDeviceName: String { snapshot.outputName }
    var generation: Int { snapshot.generation }

    func start() { stopped = false; loop.start() }
    func shutdown() { stopped = true; loop.stop() }
    func isControlled(_ key: SourceID) -> Bool { snapshot.order.contains(key) }
    func isActive(_ key: SourceID) -> Bool { controlState(key) == .rendering }
    func controlState(_ key: SourceID) -> SourceControlState { snapshot.controls[key] ?? .bypassed }
    func gain(for key: SourceID) -> Float { snapshot.gains[key] ?? 1 }
    func setGain(_ gain: Float, for key: SourceID, objectIDs: [AudioObjectID]) {
        command { $0.setGain(gain, key: key, members: objectIDs) }
    }
    func syncObjectIDs(_ ids: [AudioObjectID], for key: SourceID) {
        command { $0.syncMembers(ids, key: key) }
    }
    func release(_ key: SourceID) { release([key]) }
    func release(_ keys: [SourceID]) { command { $0.release(keys) } }
    func preRoll(_ keys: Set<SourceID>) { command { $0.preRoll(keys) } }
    func updateActivity(_ keys: Set<SourceID>) { command { $0.updateActivity(keys) } }
    func wake() { command { $0.invalidate(reason: "wake") } }
    func setSoftClip(_ enabled: Bool) { command { $0.renderer.setSoftClip(enabled) } }
    func takePeak(for key: SourceID) -> Float { pendingPeaks.removeValue(forKey: key) ?? 0 }
    func takeClip() -> Bool { defer { pendingClip = false }; return pendingClip }
    private func command(_ action: @escaping @Sendable (AudioCoordinator) -> Void) {
        loop.submit(generation: snapshot.generation, action)
    }
    func diagnostics() -> [String] { loop.diagnostics() }
}

private final class AudioControlLoop: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.buriedanchor.control", qos: .userInitiated)
    private let hardware = CoreAudioBackend()
    private let coordinator: AudioCoordinator
    private let publish: @Sendable (EngineSnapshot) -> Void
    private var timer: DispatchSourceTimer?
    private var systemListeners: [PropertyListener] = []
    private var graphListeners: [PropertyListener] = []
    private var listenerEpoch = 0
    private var observedRevision = -1
    private var flushPending = false
    private var started = false
    private var lastDiagnosticState: [String] = []
    private var nextHeartbeat: TimeInterval = 0

    init(publish: @escaping @Sendable (EngineSnapshot) -> Void) {
        self.publish = publish
        coordinator = AudioCoordinator(hardware: hardware)
    }

    func start() {
        queue.async { [self] in
            guard !self.started else { return }
            self.started = true
            self.installSystemListeners()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.flush() }
            self.timer = timer
            self.coordinator.invalidate(reason: "startup")
            timer.resume()
        }
    }

    func submit(generation: Int, _ action: @escaping @Sendable (AudioCoordinator) -> Void) {
        queue.async {
            guard self.started, self.coordinator.generation == generation else {
                DiagnosticLog.record("control.commandDiscarded", "submitted=\(generation) current=\(self.coordinator.generation) started=\(self.started)")
                return
            }
            action(self.coordinator)
            self.scheduleFlush()
        }
    }

    private func scheduleFlush() {
        guard !flushPending else { return }
        flushPending = true
        queue.asyncAfter(deadline: .now() + .milliseconds(10)) {
            self.flushPending = false
            guard self.started else { return }
            self.flush()
        }
    }

    private func flush() {
        guard started else { return }
        coordinator.tick()
        if observedRevision != coordinator.revision {
            observedRevision = coordinator.revision
            installGraphListeners()
        }
        publish(coordinator.snapshot())
        let state = coordinator.diagnostics()
        if state != lastDiagnosticState {
            DiagnosticLog.record("engine.state", state.joined(separator: " | "))
            lastDiagnosticState = state
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now >= nextHeartbeat {
            nextHeartbeat = now + 30
            DiagnosticLog.record("engine.heartbeat", "callbacks=\(coordinator.renderer.callbackCount) | " + state.joined(separator: " | "))
            for line in hardware.diagnostics(Array(coordinator.taps.values)) {
                DiagnosticLog.record("hal.readback", line)
            }
        }
    }

    private func installSystemListeners() {
        systemListeners.removeAll()
        let generation = coordinator.generation
        let route = PropertyListener(systemObject, propertyAddress(kAudioHardwarePropertyDefaultOutputDevice), queue: queue) { [weak self] in
            guard let self, self.started, self.coordinator.generation == generation else { return }
            self.coordinator.invalidate(reason: "default output changed")
            self.scheduleFlush()
        }
        let restart = PropertyListener(systemObject, propertyAddress(kAudioHardwarePropertyServiceRestarted), queue: queue) { [weak self] in
            guard let self, self.started, self.coordinator.generation == generation else { return }
            self.graphListeners.removeAll()
            self.coordinator.serviceRestarted()
            self.installSystemListeners()
            self.scheduleFlush()
        }
        systemListeners = [route, restart].compactMap { $0 }
    }

    private func installGraphListeners() {
        listenerEpoch += 1
        let epoch = listenerEpoch
        graphListeners.removeAll()
        func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    _ react: @escaping @Sendable (AudioCoordinator) -> Void = { $0.graphChanged() }) {
            if let listener = PropertyListener(object, propertyAddress(selector, scope), queue: queue, handler: { [weak self] in
                guard let self, self.started, self.listenerEpoch == epoch else { return }
                DiagnosticLog.record("hal.propertyChanged", "object=\(object) selector=\(fourCC(selector)) scope=\(fourCC(scope))")
                react(self.coordinator)
                self.scheduleFlush()
            }) { graphListeners.append(listener) }
        }
        for process in Set(coordinator.requests.values.flatMap(\.members)) {
            listen(process, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput) { $0.memberRoutesChanged() }
        }
        if let route = coordinator.route {
            listen(route.id, kAudioDevicePropertyDeviceIsAlive)
            listen(route.id, kAudioDevicePropertyNominalSampleRate)
            listen(route.id, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
            listen(route.id, kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput)
        }
        if let aggregate = coordinator.aggregate {
            listen(aggregate, kAudioDevicePropertyIOStoppedAbnormally)
            listen(aggregate, kAudioDevicePropertyBufferFrameSize)
            for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
                listen(aggregate, kAudioDevicePropertyStreamConfiguration, scope)
                for stream in aggregate.streams(scope) { listen(stream, kAudioStreamPropertyVirtualFormat) }
            }
        }
        for tap in coordinator.taps.values { listen(tap.id, kAudioTapPropertyFormat) }
    }

    func stop() {
        queue.sync {
            started = false
            timer?.cancel()
            timer = nil
            systemListeners.removeAll()
            graphListeners.removeAll()
            coordinator.shutdown()
            DiagnosticLog.record("engine.stopped", coordinator.diagnostics().joined(separator: " | "))
        }
    }

    func diagnostics() -> [String] { queue.sync { coordinator.diagnostics() } }
}
