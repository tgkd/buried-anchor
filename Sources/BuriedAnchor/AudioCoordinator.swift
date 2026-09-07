import CoreAudio
import Foundation

enum SourceControlState: Equatable, Sendable {
    case bypassed, waiting, rendering, muted, held
    case unsupported(String), failed(String)

    var notice: String? {
        switch self {
        case .waiting: "Waiting for a supported audio route"
        case .held: "Ready; playback is idle"
        case .unsupported(let reason), .failed(let reason): reason
        default: nil
        }
    }
    var needsAttention: Bool {
        switch self { case .unsupported, .failed, .waiting: true; default: false }
    }
}

struct EngineSnapshot: Sendable {
    var order: [SourceID] = []
    var gains: [SourceID: Float] = [:]
    var controls: [SourceID: SourceControlState] = [:]
    var peaks: [SourceID: Float] = [:]
    var clipping = false
    var active = false
    var outputName = "-"
    var error: String?
    var generation = 0
}

final class AudioCoordinator: @unchecked Sendable {
    struct Request: Equatable {
        var gain: Float
        var members: [AudioObjectID]
    }
    let hardware: AudioHardwareBackend
    let renderer = MixRenderer()
    private(set) var requests: [SourceID: Request] = [:]
    private(set) var taps: [SourceID: ManagedTap] = [:]
    private(set) var aggregate: AudioObjectID?
    private(set) var io: AudioDeviceIOProcID?
    private(set) var running = false
    private(set) var generation = 0
    private(set) var route: OutputRoute?
    private(set) var order: [SourceID] = []
    private(set) var controls: [SourceID: SourceControlState] = [:]
    private(set) var lastError: String?
    private(set) var dirty = false
    private(set) var revision = 0
    private var playing: Set<SourceID> = []
    private var idleDeadline: TimeInterval?
    private var prerollUntil: TimeInterval = 0
    private var retryAt: TimeInterval?
    private var retryIndex = 0
    private var layoutSummary = "-"
    private let now: () -> TimeInterval

    init(hardware: AudioHardwareBackend, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.hardware = hardware
        self.now = now
    }

    func setGain(_ gain: Float, key: SourceID, members: [AudioObjectID]) {
        guard gain.isFinite, gain >= 0, gain <= 1.5 else { return }
        let request = Request(gain: gain, members: Array(Set(members)).sorted())
        let old = requests[key]
        guard old != request else { return }
        requests[key] = request
        if old?.members != request.members, gain == 0, !members.isEmpty { prerollUntil = now() + 1.5 }
        if old?.members == request.members, gain != 1, var tap = taps[key], lastError == nil {
            do {
                let behavior: CATapMuteBehavior = gain == 0 || !running ? .muted : .mutedWhenTapped
                if tap.behavior != behavior {
                    tap.behavior = behavior
                    try hardware.updateTap(tap)
                    taps[key] = tap
                }
                if let slot = order.firstIndex(of: key) { renderer.setGain(gain, slot: slot) }
                controls[key] = gain == 0 ? .muted : (running ? .rendering : .held)
                updateActivity(playing)
                return
            } catch { recordFailure(error) }
        }
        dirty = true
    }

    func syncMembers(_ members: [AudioObjectID], key: SourceID) {
        guard let request = requests[key] else { return }
        setGain(request.gain, key: key, members: members)
    }

    func release(_ keys: [SourceID]) {
        for key in keys {
            requests.removeValue(forKey: key)
            controls.removeValue(forKey: key)
        }
        dirty = true
    }

    func updateActivity(_ keys: Set<SourceID>) {
        playing = keys
        let needed = requests.contains { key, request in request.gain > 0 && request.gain != 1 && keys.contains(key) }
        if needed {
            idleDeadline = nil
            if !running, lastError == nil { dirty = true }
        } else if idleDeadline == nil {
            idleDeadline = now() + 1.5
        }
    }

    func preRoll() {
        prerollUntil = now() + 1.5
        if !running, lastError == nil { dirty = true }
    }

    private var wantsIO: Bool {
        if prerollUntil > now() { return true }
        if requests.contains(where: { key, value in value.gain > 0 && value.gain != 1 && playing.contains(key) }) { return true }
        return running && (idleDeadline.map { now() < $0 } ?? false)
    }

    func invalidate() { dirty = true }

    func graphChanged() {
        if lastError == nil { dirty = true }
    }

    func memberRoutesChanged() {
        guard let route, lastError == nil else { return }
        for (key, request) in requests where request.gain != 1 && !request.members.isEmpty {
            let supported = routeRestriction(request, output: route) == nil
            if supported != (taps[key] != nil) { dirty = true; return }
        }
    }

    private func routeRestriction(_ request: Request, output: OutputRoute) -> SourceControlState? {
        do {
            let routes = try request.members.map { try hardware.outputDevices($0) }
            guard routes.allSatisfy({ $0.isEmpty || Set($0) == [output.id] }) else {
                return .unsupported("This app is not exclusively using the default output; volume is unchanged")
            }
            return nil
        } catch {
            return .unsupported("Could not verify this app's output; volume is unchanged")
        }
    }

    func tick() {
        if renderer.takeLayoutFault() { dirty = true }
        if let retryAt, now() >= retryAt { self.retryAt = nil; dirty = true }
        if running && !wantsIO { dirty = true }
        reconcile()
    }

    func reconcile() {
        guard dirty else { return }
        dirty = false
        var guarded = false
        do {
            for key in sortedTapKeys {
                try setBehavior(.muted, key: key)
            }
            guarded = true
            try stopGraph()
            let output = try hardware.defaultOutput()
            route = output
            var eligible: [SourceID: Request] = [:]
            controls = [:]
            for (key, request) in requests {
                guard request.gain != 1 else { controls[key] = .bypassed; continue }
                guard !request.members.isEmpty else { controls[key] = .waiting; continue }
                if let unsupported = routeRestriction(request, output: output) {
                    controls[key] = unsupported
                    continue
                }
                eligible[key] = request
            }

            for key in sortedTapKeys where eligible[key] == nil {
                try setBehavior(.unmuted, key: key)
                try hardware.destroyTap(taps[key]!.id)
                taps.removeValue(forKey: key)
            }
            for key in eligible.keys.sorted(by: { $0.raw < $1.raw }) {
                let request = eligible[key]!
                do {
                    if var tap = taps[key] {
                        tap.members = request.members
                        tap.route = output.uid
                        tap.stream = output.stream
                        tap.behavior = .muted
                        try hardware.updateTap(tap)
                        taps[key] = tap
                    } else {
                        guard taps.count < MixRenderer.maxSlots else {
                            controls[key] = .failed("The 32-app limit is reached; reset another app to free a slot")
                            continue
                        }
                        var tap = ManagedTap(id: 0, uuid: UUID(), key: key, members: request.members,
                                             route: output.uid, behavior: .muted, stream: output.stream)
                        let id = try hardware.createTap(tap)
                        tap = ManagedTap(id: id, uuid: tap.uuid, key: key, members: tap.members,
                                         route: tap.route, behavior: tap.behavior, stream: tap.stream)
                        taps[key] = tap
                        try hardware.updateTap(tap)
                    }
                } catch let failure as AudioFailure where failure.staleMembership {
                    if let tap = taps[key] {
                        try hardware.destroyTap(tap.id)
                        taps.removeValue(forKey: key)
                    }
                    controls[key] = .failed("Volume could not be applied; direct playback restored (\(failure.message))")
                    log.error("tap for \(key.raw, privacy: .public) rejected: \(failure.message, privacy: .public)")
                }
            }
            order = sortedTapKeys
            if !order.isEmpty, wantsIO {
                let created = try hardware.createAggregate(output, taps: order.compactMap { taps[$0] })
                aggregate = created
                let layout = try hardware.layout(created, route: output, taps: order.compactMap { taps[$0] })
                order = layout.slots.map(\.key)
                renderer.apply(layout, gains: order.map { requests[$0]?.gain ?? 1 })
                renderer.configure(sampleRate: layout.sampleRate, framesPerBuffer: hardware.bufferFrames(created))
                layoutSummary = layout.summary
                let createdIO = try hardware.createIO(created, renderer: renderer)
                io = createdIO
                try hardware.startIO(created, createdIO)
                running = true
                for key in order where requests[key]?.gain != 0 { try setBehavior(.mutedWhenTapped, key: key) }
            }
            for key in order {
                controls[key] = requests[key]?.gain == 0 ? .muted : (running ? .rendering : .held)
            }
            lastError = nil
            retryAt = nil
            retryIndex = 0
            revision += 1
        } catch {
            if guarded {
                do { try stopGraph() } catch { }
            }
            recordFailure(error)
        }
    }

    private var sortedTapKeys: [SourceID] { taps.keys.sorted { $0.raw < $1.raw } }

    private func setBehavior(_ behavior: CATapMuteBehavior, key: SourceID) throws {
        guard var tap = taps[key] else { return }
        tap.behavior = behavior
        try hardware.updateTap(tap)
        taps[key] = tap
    }

    private func recordFailure(_ error: Error) {
        let reason = (error as? LayoutFault)?.message ?? error.localizedDescription
        var recoveryErrors: [String] = []
        if io == nil {
            order = sortedTapKeys
            for key in sortedTapKeys {
                do {
                    let explicitlyMuted = requests[key]?.gain == 0
                    try setBehavior(explicitlyMuted ? .muted : .unmuted, key: key)
                    controls[key] = explicitlyMuted ? .muted : .failed("Volume could not be applied; direct playback restored")
                } catch {
                    controls[key] = .failed("Could not verify playback or mute state")
                    recoveryErrors.append(key.fallbackName)
                }
            }
        } else {
            for key in sortedTapKeys { controls[key] = .failed("Audio cleanup is pending; the previous graph may still be running") }
        }
        for key in requests.keys where controls[key] == nil { controls[key] = .failed(reason) }
        lastError = reason + (recoveryErrors.isEmpty ? "" : "; recovery unverified for " + recoveryErrors.joined(separator: ", "))
        let delays: [TimeInterval] = [1, 2, 5, 15, 30]
        retryAt = now() + delays[min(retryIndex, delays.count - 1)]
        retryIndex += 1
        revision += 1
        log.error("audio recovery: \(self.lastError ?? reason, privacy: .public)")
    }

    private func stopGraph() throws {
        if let aggregate, let io {
            try? hardware.stopIO(aggregate, io)
            try hardware.destroyIO(aggregate, io)
            self.io = nil
            running = false
        }
        if let aggregate {
            try hardware.destroyAggregate(aggregate)
            self.aggregate = nil
        }
        renderer.clearSlots()
        layoutSummary = "-"
    }

    func serviceRestarted() {
        generation += 1
        revision += 1
        aggregate = nil
        io = nil
        running = false
        taps.removeAll()
        order.removeAll()
        renderer.clearSlots()
        requests.removeAll()
        controls.removeAll()
        playing.removeAll()
        route = nil
        lastError = nil
        retryAt = nil
        retryIndex = 0
        dirty = true
    }

    func shutdown() {
        requests.removeAll()
        playing.removeAll()
        do {
            for key in sortedTapKeys { try setBehavior(.muted, key: key) }
            try stopGraph()
            for key in sortedTapKeys {
                try setBehavior(.unmuted, key: key)
                try hardware.destroyTap(taps[key]!.id)
                taps.removeValue(forKey: key)
            }
        } catch { recordFailure(error) }
        order = sortedTapKeys
    }

    func snapshot() -> EngineSnapshot {
        EngineSnapshot(order: order, gains: requests.mapValues(\.gain), controls: controls,
                       peaks: Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, renderer.takePeak(slot: $0.offset)) }),
                       clipping: renderer.takeClipCount() > 0, active: running,
                       outputName: route?.name ?? "-", error: lastError, generation: generation)
    }

    func diagnostics() -> [String] {
        ["generation=\(generation) running=\(running) aggregate=\(String(describing: aggregate)) io=\(io != nil)",
         "output=\(route?.name ?? "-") layout=\(layoutSummary)", "error=\(lastError ?? "none")"]
        + sortedTapKeys.map { key in
            let tap = taps[key]!
            return "tap \(key.raw) id=\(tap.id) members=\(tap.members) route=\(tap.route) mute=\(behaviorName(tap.behavior)) state=\(String(describing: controls[key]))"
        }
    }
}
