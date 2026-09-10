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
    private var prerollUntil: [SourceID: TimeInterval] = [:]
    private var pendingPriming: Set<SourceID> = []
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
        DiagnosticLog.record("control.request", "source=\(key.raw) old=\(String(describing: old)) gain=\(gain) members=\(request.members)")
        requests[key] = request
        if gain == 1 || request.members.isEmpty {
            prerollUntil.removeValue(forKey: key)
        } else if gain == 0 {
            if old?.members != request.members {
                prerollUntil[key] = now() + 1.5
            } else {
                prerollUntil.removeValue(forKey: key)
            }
        }
        if old?.members == request.members, gain != 1, var tap = taps[key], lastError == nil {
            do {
                let behavior: CATapMuteBehavior = gain == 0 || !running ? .muted : .mutedWhenTapped
                if tap.behavior != behavior {
                    tap.behavior = behavior
                    try applyTap(&tap)
                }
                if let slot = order.firstIndex(of: key) { renderer.setGain(gain, slot: slot) }
                controls[key] = gain == 0 ? .muted : (running ? .rendering : .held)
                updateActivity(playing)
                if gain == 0, !hasAudiblePlayback { idleDeadline = now() }
                if running && !wantsIO { dirty = true }
                return
            } catch let failure as AudioFailure where failure.staleMembership {
            } catch { recordFailure(error) }
        }
        dirty = true
    }

    func syncMembers(_ members: [AudioObjectID], key: SourceID) {
        guard let request = requests[key] else { return }
        setGain(request.gain, key: key, members: members)
    }

    func release(_ keys: [SourceID]) {
        DiagnosticLog.record("control.release", keys.map(\.raw).sorted().joined(separator: ","))
        for key in keys {
            requests.removeValue(forKey: key)
            controls.removeValue(forKey: key)
            prerollUntil.removeValue(forKey: key)
            pendingPriming.remove(key)
        }
        dirty = true
    }

    func updateActivity(_ keys: Set<SourceID>) {
        if playing != keys {
            DiagnosticLog.record("control.activity", "playing=\(keys.map(\.raw).sorted()) running=\(running)")
        }
        playing = keys
        let needed = requests.contains { key, request in request.gain > 0 && request.gain != 1 && keys.contains(key) }
        if needed {
            idleDeadline = nil
            if !running, lastError == nil { dirty = true }
        } else if idleDeadline == nil {
            idleDeadline = now() + 1.5
        }
    }

    func preRoll(_ keys: Set<SourceID>) {
        DiagnosticLog.record("control.preroll", "sources=\(keys.map(\.raw).sorted()) until=\(now() + 1.5)")
        for key in keys {
            if let request = requests[key], request.gain == 1 || request.members.isEmpty { continue }
            prerollUntil[key] = now() + 1.5
        }
        if !running, lastError == nil { dirty = true }
    }

    private var hasAudiblePlayback: Bool {
        requests.contains { key, value in
            value.gain > 0 && value.gain != 1 && taps[key] != nil && playing.contains(key)
        }
    }

    private var wantsIO: Bool {
        let controlled = requests.filter { key, value in value.gain != 1 && taps[key] != nil }
        guard !controlled.isEmpty else { return false }
        if controlled.contains(where: { key, _ in (prerollUntil[key] ?? 0) > now() }) { return true }
        if controlled.contains(where: { key, value in value.gain > 0 && playing.contains(key) }) { return true }
        return running && (idleDeadline.map { now() < $0 } ?? false)
    }

    func invalidate(reason: String = "external") {
        DiagnosticLog.record("control.invalidate", reason)
        dirty = true
    }

    func graphChanged() {
        if lastError == nil { dirty = true }
    }

    func memberRoutesChanged() {
        guard let route, lastError == nil else { return }
        for (key, request) in requests where request.gain != 1 && !request.members.isEmpty {
            let routes = inspectRoutes(request, output: route)
            let supported = routes.supported && !routes.members.isEmpty
            if supported != (taps[key] != nil) { dirty = true; return }
        }
    }

    private struct RouteInspection {
        var members: [AudioObjectID]
        var supported: Bool
    }

    private func inspectRoutes(_ request: Request, output: OutputRoute) -> RouteInspection {
        var result = RouteInspection(members: [], supported: true)
        for member in request.members {
            guard let devices = try? hardware.outputDevices(member) else { continue }
            result.members.append(member)
            if !(devices.isEmpty || Set(devices) == [output.id]) { result.supported = false }
        }
        return result
    }

    func tick() {
        let expired = prerollUntil.filter { $0.value <= now() }.keys.map(\.raw).sorted()
        if !expired.isEmpty { DiagnosticLog.record("control.prerollExpired", "sources=\(expired)") }
        prerollUntil = prerollUntil.filter { $0.value > now() }
        if renderer.takeLayoutFault() {
            DiagnosticLog.record("render.layoutFault")
            dirty = true
        }
        if let retryAt, now() >= retryAt {
            DiagnosticLog.record("control.retry", "attempt=\(retryIndex)")
            self.retryAt = nil; dirty = true
        }
        if running && !wantsIO {
            DiagnosticLog.record("control.suspend", "no IO demand; playing=\(playing.map(\.raw).sorted())")
            dirty = true
        }
        reconcile()
    }

    func reconcile() {
        guard dirty else { return }
        DiagnosticLog.record("graph.reconcile", "generation=\(generation) revision=\(revision) running=\(running) wantsIO=\(wantsIO)")
        dirty = false
        var guarded = false
        var refused: [SourceID: String] = [:]
        var disconnected: Set<SourceID> = []
        do {
            for key in sortedTapKeys {
                do {
                    try setBehavior(.muted, key: key)
                } catch let failure as AudioFailure where failure.staleMembership {
                    refused[key] = failure.message
                } catch {
                    guard oldOutputDisappeared(taps[key]!.route, guardError: error) else { throw error }
                    disconnected.insert(key)
                }
            }
            guarded = true
            try stopGraph()
            let output = try hardware.defaultOutput()
            route = output
            for key in disconnected.sorted(by: { $0.raw < $1.raw }) {
                try hardware.destroyTap(taps[key]!.id)
                taps.removeValue(forKey: key)
                pendingPriming.insert(key)
                DiagnosticLog.record("graph.tapReplaced", "source=\(key.raw) newOutput=\(output.uid)")
            }
            var eligible: [SourceID: Request] = [:]
            controls = [:]
            for (key, request) in requests {
                guard request.gain != 1 else { controls[key] = .bypassed; continue }
                let routes = inspectRoutes(request, output: output)
                if routes.members != request.members { requests[key]?.members = routes.members }
                guard !routes.members.isEmpty else { controls[key] = .waiting; continue }
                if let reason = refused[key] {
                    controls[key] = .failed("Volume could not be applied; direct playback restored (\(reason))")
                    continue
                }
                guard routes.supported else {
                    controls[key] = .unsupported("This app is not exclusively using the default output; volume is unchanged")
                    continue
                }
                eligible[key] = requests[key]
            }

            for key in sortedTapKeys where eligible[key] == nil {
                if refused[key] == nil { try setBehavior(.unmuted, key: key) }
                try hardware.destroyTap(taps[key]!.id)
                taps.removeValue(forKey: key)
            }
            for key in eligible.keys.sorted(by: { $0.raw < $1.raw }) {
                guard let tap = taps[key], tap.route != output.uid || tap.stream != output.stream else { continue }
                try hardware.destroyTap(tap.id)
                taps.removeValue(forKey: key)
                pendingPriming.insert(key)
                DiagnosticLog.record("graph.tapMoved", "source=\(key.raw) from=\(tap.route) to=\(output.uid)")
            }
            for key in eligible.keys.sorted(by: { $0.raw < $1.raw }) {
                let request = eligible[key]!
                do {
                    if var tap = taps[key] {
                        tap.members = request.members
                        tap.route = output.uid
                        tap.stream = output.stream
                        tap.behavior = .muted
                        try applyTap(&tap)
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
                        try applyTap(&tap)
                    }
                    if let tap = taps[key], tap.members.isEmpty {
                        try hardware.destroyTap(tap.id)
                        taps.removeValue(forKey: key)
                        controls[key] = .waiting
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
            for key in pendingPriming where taps[key] != nil { prerollUntil[key] = now() + 1.5 }
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
            pendingPriming.removeAll()
            lastError = nil
            retryAt = nil
            retryIndex = 0
            revision += 1
            DiagnosticLog.record("graph.ready", "revision=\(revision) running=\(running) order=\(order.map(\.raw))")
        } catch {
            if guarded {
                do { try stopGraph() } catch { }
            }
            recordFailure(error)
        }
    }

    private var sortedTapKeys: [SourceID] { taps.keys.sorted { $0.raw < $1.raw } }

    private func oldOutputDisappeared(_ uid: String, guardError: Error) -> Bool {
        do {
            let gone = try hardware.outputIsUnavailable(uid)
            DiagnosticLog.record("graph.muteGuardFailed", "device=\(uid) unavailable=\(gone) error=\(guardError.localizedDescription)")
            return gone
        } catch {
            DiagnosticLog.record("graph.muteGuardFailed", "device=\(uid) unavailable=unknown error=\(guardError.localizedDescription) probe=\(error.localizedDescription)")
            return false
        }
    }

    private func setBehavior(_ behavior: CATapMuteBehavior, key: SourceID) throws {
        guard var tap = taps[key] else { return }
        tap.behavior = behavior
        try applyTap(&tap)
    }

    private func applyTap(_ tap: inout ManagedTap) throws {
        let confirmed = try hardware.updateTap(tap)
        let requested = Set(tap.members)
        guard Set(confirmed).isSubset(of: requested) else {
            throw AudioFailure(message: "HAL did not confirm process membership (requested \(tap.members), returned \(confirmed))", staleMembership: true)
        }
        let dropped = requested.subtracting(confirmed)
        let rejected = dropped.filter { (try? hardware.outputDevices($0)) != nil }
        guard rejected.isEmpty else {
            throw AudioFailure(message: "HAL refused to capture process \(rejected.sorted())", staleMembership: true)
        }
        if !dropped.isEmpty {
            tap.members = confirmed.sorted()
            if var request = requests[tap.key] {
                request.members = request.members.filter { !dropped.contains($0) }
                requests[tap.key] = request
            }
        }
        taps[tap.key] = tap
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
        DiagnosticLog.record("control.failure", "reason=\(lastError ?? reason) retryAt=\(String(describing: retryAt)) attempt=\(retryIndex)")
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
        DiagnosticLog.record("hal.restart", "oldGeneration=\(generation)")
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
        prerollUntil.removeAll()
        pendingPriming.removeAll()
        idleDeadline = nil
        route = nil
        lastError = nil
        retryAt = nil
        retryIndex = 0
        dirty = true
    }

    func shutdown() {
        requests.removeAll()
        playing.removeAll()
        prerollUntil.removeAll()
        pendingPriming.removeAll()
        idleDeadline = nil
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
         "output=\(route?.name ?? "-") device=\(route?.uid ?? "-") layout=\(layoutSummary)", "error=\(lastError ?? "none")",
         "playing=\(playing.map(\.raw).sorted()) wantsIO=\(wantsIO) idleDeadline=\(String(describing: idleDeadline)) retryAt=\(String(describing: retryAt))"]
        + requests.keys.sorted { $0.raw < $1.raw }.map { key in
            let request = requests[key]!
            return "request \(key.raw) gain=\(request.gain) members=\(request.members) prerollUntil=\(String(describing: prerollUntil[key])) state=\(String(describing: controls[key]))"
        }
        + sortedTapKeys.map { key in
            let tap = taps[key]!
            return "tap \(key.raw) id=\(tap.id) members=\(tap.members) route=\(tap.route) mute=\(behaviorName(tap.behavior)) state=\(String(describing: controls[key]))"
        }
    }
}
