import CoreAudio
import Foundation

enum CoordinatorChecks {
    static func run(_ check: (Bool, String) -> Void) {
        let a = SourceID.bundle("test.a")
        let b = SourceID.bundle("test.b")

        do {
            let hardware = FakeAudioHardware()
            var time: TimeInterval = 0
            let core = AudioCoordinator(hardware: hardware, now: { time })
            core.setGain(0.5, key: a, members: [11])
            core.updateActivity([a])
            core.reconcile()
            check(core.running && core.controls[a] == .rendering, "coordinator starts a verified render graph")
            let builds = hardware.builds
            core.setGain(0.7, key: a, members: [11])
            core.reconcile()
            check(hardware.builds == builds && core.running, "slider changes do not rebuild audio")
            core.setGain(0, key: a, members: [11])
            core.reconcile()
            time = 2
            core.tick()
            check(!core.running && core.aggregate == nil && core.taps[a]?.behavior == .muted,
                  "explicit mute releases the output device while keeping a verified mute")
            core.setGain(0.5, key: a, members: [11])
            core.reconcile()
            check(core.running, "unmute restarts playback")
            core.setGain(1, key: a, members: [11])
            core.reconcile()
            check(core.taps[a] == nil && core.controls[a] == .bypassed && !core.running,
                  "unity releases the tap and becomes true bypass")
            core.shutdown()
            check(hardware.taps.isEmpty && !hardware.hasIO && hardware.aggregate == nil,
                  "normal shutdown releases every HAL resource")
        }

        do {
            let hardware = FakeAudioHardware()
            let core = AudioCoordinator(hardware: hardware)
            core.setGain(0, key: a, members: [11])
            core.updateActivity([a])
            core.reconcile()
            let start = hardware.events.count
            core.setGain(0.5, key: b, members: [12])
            core.updateActivity([a, b])
            core.reconcile()
            let events = Array(hardware.events.dropFirst(start))
            let guardIndex = events.firstIndex(of: "mute:test.a:muted")
            let stopIndex = events.firstIndex(of: "stopIO")
            check(guardIndex != nil && stopIndex != nil && guardIndex! < stopIndex!,
                  "muting is verified before graph teardown")
            check(!events.contains("mute:test.a:mutedWhenTapped") && !events.contains("mute:test.a:unmuted"),
                  "adding another source never releases an explicit mute")
            core.shutdown()
        }

        for operation in ["createTap", "updateTap", "createAggregate", "layout", "createIO", "startIO"] {
            let hardware = FakeAudioHardware()
            let core = AudioCoordinator(hardware: hardware)
            hardware.failure = operation
            core.setGain(0.5, key: a, members: [11])
            core.updateActivity([a])
            core.reconcile()
            check(core.lastError != nil && !hardware.hasIO && hardware.aggregate == nil,
                  "\(operation) failure cleans up partial graph construction")
            check(hardware.taps.values.allSatisfy { $0.behavior == .unmuted },
                  "\(operation) failure restores nonzero sources to direct playback")
            core.invalidate()
            core.reconcile()
            check(core.running && core.lastError == nil, "\(operation) failure can recover")
            core.shutdown()
        }

        do {
            let hardware = FakeAudioHardware()
            var time: TimeInterval = 0
            let core = AudioCoordinator(hardware: hardware, now: { time })
            core.setGain(0.5, key: a, members: [11])
            core.reconcile()
            hardware.failure = "defaultOutput"
            hardware.failuresLeft = 2
            core.invalidate()
            core.reconcile()
            check(core.taps[a]?.behavior == .unmuted, "failed dormant graph restores direct playback")
            let before = hardware.events.count
            time = 0.9
            core.tick()
            check(hardware.events.count == before, "retry waits for its monotonic deadline")
            time = 1
            core.tick()
            check(core.lastError != nil, "first retry failure stays recoverable")
            time = 3
            core.tick()
            check(core.lastError == nil, "exponential retry recovers without a new UI action")
            core.shutdown()
        }

        for operation in ["destroyIO", "destroyAggregate", "destroyTap"] {
            let hardware = FakeAudioHardware()
            let core = AudioCoordinator(hardware: hardware)
            core.setGain(0.5, key: a, members: [11])
            core.updateActivity([a])
            core.reconcile()
            hardware.failure = operation
            hardware.failuresLeft = 100
            core.release([a])
            core.reconcile()
            check(core.lastError != nil && !core.taps.isEmpty, "\(operation) failure retains ownership for retry")
            if operation == "destroyIO" {
                check(core.io != nil && hardware.builds == 1, "failed callback destruction prevents graph/layout replacement")
            }
            hardware.failure = nil
            core.invalidate()
            core.reconcile()
            check(core.lastError == nil && hardware.taps.isEmpty && !hardware.hasIO && hardware.aggregate == nil,
                  "\(operation) retry eventually releases the owned resources")
            core.shutdown()
        }

        do {
            let hardware = FakeAudioHardware()
            let core = AudioCoordinator(hardware: hardware)
            core.setGain(0.5, key: a, members: [11])
            core.updateActivity([a])
            core.reconcile()
            hardware.failure = "updateTap"
            hardware.failuresLeft = 100
            let before = hardware.events.count
            core.setGain(0.5, key: b, members: [12])
            core.reconcile()
            check(!hardware.events.dropFirst(before).contains("stopIO") && hardware.hasIO,
                  "failed mute guard preserves the previous graph")
            check(core.controls[a]?.needsAttention == true, "failed mute verification is visible per source")
            hardware.failure = nil
            core.shutdown()
        }

        do {
            let hardware = FakeAudioHardware()
            let core = AudioCoordinator(hardware: hardware)
            hardware.routes[11] = [2]
            core.setGain(0.5, key: a, members: [11])
            core.updateActivity([a])
            core.reconcile()
            check(core.taps.isEmpty && core.controls[a]?.needsAttention == true,
                  "non-default output is left untouched")
            hardware.routes[11] = [1, 2]
            core.invalidate()
            core.reconcile()
            check(core.taps.isEmpty, "multi-device process is left untouched")
            hardware.routes[11] = [1]
            core.invalidate()
            core.reconcile()
            check(core.running && core.taps[a]?.route == "output.one", "supported route becomes controlled")
            hardware.routes[11] = [2]
            core.invalidate()
            core.reconcile()
            check(hardware.taps.isEmpty && !hardware.hasIO, "changing an app's route releases its control")
            core.shutdown()
        }

        do {
            let hardware = FakeAudioHardware()
            let core = AudioCoordinator(hardware: hardware)
            hardware.routes[11] = []
            core.setGain(0, key: a, members: [11])
            core.reconcile()
            check(core.taps[a]?.route == "output.one" && core.controls[a] == .muted,
                  "idle process without a device is held by a muted tap")
            hardware.routes[11] = [1]
            let builds = hardware.builds
            let events = hardware.events.count
            core.memberRoutesChanged()
            core.reconcile()
            check(hardware.builds == builds && hardware.events.count == events,
                  "playback on the default output does not rebuild the graph")
            hardware.routes[11] = [2]
            core.memberRoutesChanged()
            core.reconcile()
            check(hardware.taps.isEmpty && core.controls[a]?.needsAttention == true,
                  "playback on another device releases the idle tap")
            hardware.routes[11] = []
            core.memberRoutesChanged()
            core.reconcile()
            check(core.taps[a] != nil, "returning to idle restores the muted tap")
            core.syncMembers([], key: a)
            core.reconcile()
            check(core.taps[a] == nil && hardware.taps.isEmpty && core.controls[a] == .waiting,
                  "an app that quit releases its tap and waits")
            core.shutdown()
        }

        do {
            let hardware = FakeAudioHardware()
            let core = AudioCoordinator(hardware: hardware)
            hardware.deadMembers = [99]
            core.setGain(0.5, key: a, members: [11])
            core.setGain(0, key: b, members: [99])
            core.updateActivity([a])
            core.reconcile()
            check(core.running && core.taps[a] != nil && hardware.hasIO,
                  "a stale member in one app does not fail the others")
            check(core.taps[b] == nil && hardware.taps.count == 1 && core.controls[b]?.needsAttention == true
                  && core.lastError == nil, "the rejected app is released and reported alone")
            core.syncMembers([12], key: b)
            core.reconcile()
            check(core.taps[b] != nil && core.controls[b] == .muted, "fresh members recover the rejected app")
            core.shutdown()
        }

        do {
            let hardware = FakeAudioHardware()
            let core = AudioCoordinator(hardware: hardware)
            core.setGain(0.5, key: a, members: [11])
            core.updateActivity([a])
            core.reconcile()
            hardware.failure = "updateTap"
            hardware.skipFailures = 1
            core.syncMembers([11, 12], key: a)
            core.reconcile()
            check(core.lastError != nil && core.controls[a]?.needsAttention == true && !core.running,
                  "partial membership is never reported as active control")
            check(core.taps[a]?.behavior == .unmuted, "membership failure restores direct playback")
            core.invalidate()
            core.reconcile()
            check(core.running && core.taps[a]?.members == [11, 12], "membership update recovers with complete coverage")
            hardware.failure = "stopIO"
            hardware.failuresLeft = 1
            core.release([a])
            core.reconcile()
            check(core.lastError == nil && !hardware.hasIO && hardware.taps.isEmpty,
                  "successful callback destruction completes cleanup even when Stop fails")
            core.shutdown()
        }

        do {
            let hardware = FakeAudioHardware()
            let core = AudioCoordinator(hardware: hardware)
            core.setGain(0, key: a, members: [11])
            core.setGain(0.5, key: b, members: [12])
            core.updateActivity([a, b])
            hardware.failure = "createAggregate"
            core.reconcile()
            check(core.taps[a]?.behavior == .muted && core.controls[a] == .muted,
                  "graph failure preserves a verified explicit user mute")
            check(core.taps[b]?.behavior == .unmuted, "graph failure independently restores nonzero sources")
            core.shutdown()
        }

        do {
            let hardware = FakeAudioHardware()
            let core = AudioCoordinator(hardware: hardware)
            core.setGain(0.5, key: a, members: [11])
            core.updateActivity([a])
            core.reconcile()
            let oldTap = core.taps[a]?.id
            hardware.resetService()
            let before = hardware.events.count
            core.serviceRestarted()
            core.reconcile()
            check(core.generation == 1 && core.taps.isEmpty && core.requests.isEmpty,
                  "HAL reset discards stale taps and process membership")
            check(!hardware.events.dropFirst(before).contains("destroyIO"), "HAL reset never destroys a recycled old callback")
            core.setGain(0.5, key: a, members: [101])
            core.updateActivity([a])
            core.reconcile()
            check(core.running && core.taps[a]?.id != oldTap && core.taps[a]?.members == [101],
                  "fresh discovery recreates taps after HAL reset")
            core.shutdown()
        }
    }
}

private final class FakeAudioHardware: AudioHardwareBackend {
    var failure: String?
    var failuresLeft = 1
    var skipFailures = 0
    var events: [String] = []
    var taps: [AudioObjectID: ManagedTap] = [:]
    var routes: [AudioObjectID: [AudioObjectID]] = [:]
    var deadMembers: Set<AudioObjectID> = []
    var aggregate: AudioObjectID?
    var hasIO = false
    var builds = 0
    private var nextID: AudioObjectID = 1000

    private func hit(_ operation: String) throws {
        events.append(operation)
        if failure == operation && failuresLeft > 0 {
            if skipFailures > 0 { skipFailures -= 1; return }
            failuresLeft -= 1
            throw AudioFailure(message: "Injected \(operation) failure")
        }
    }
    func defaultOutput() throws -> OutputRoute {
        try hit("defaultOutput")
        return OutputRoute(id: 1, uid: "output.one", name: "Test output")
    }
    func outputDevices(_ process: AudioObjectID) throws -> [AudioObjectID] { routes[process] ?? [1] }
    func createTap(_ tap: ManagedTap) throws -> AudioObjectID {
        try hit("createTap")
        nextID += 1
        taps[nextID] = tap
        return nextID
    }
    func updateTap(_ tap: ManagedTap) throws {
        try hit("updateTap")
        guard taps[tap.id] != nil else { throw AudioFailure(message: "Stale tap") }
        guard deadMembers.isDisjoint(with: tap.members) else {
            throw AudioFailure(message: "HAL did not confirm process membership", staleMembership: true)
        }
        taps[tap.id] = tap
        events.append("mute:\(tap.key.raw):\(behaviorName(tap.behavior))")
    }
    func destroyTap(_ id: AudioObjectID) throws {
        try hit("destroyTap")
        guard aggregate == nil else { throw AudioFailure(message: "Destroyed a tap still in an aggregate") }
        taps.removeValue(forKey: id)
    }
    func createAggregate(_ route: OutputRoute, taps: [ManagedTap]) throws -> AudioObjectID {
        try hit("createAggregate")
        nextID += 1
        aggregate = nextID
        builds += 1
        return nextID
    }
    func destroyAggregate(_ id: AudioObjectID) throws {
        try hit("destroyAggregate")
        guard !hasIO else { throw AudioFailure(message: "Destroyed aggregate with live callback") }
        aggregate = nil
    }
    func layout(_ aggregate: AudioObjectID, route: OutputRoute, taps: [ManagedTap]) throws -> GraphLayout {
        try hit("layout")
        return try GraphLayout.resolve(
            taps: taps.map { TapFormat(key: $0.key, channels: 2, sampleRate: 48000, isFloat32: true) },
            input: BufferLayout(bufferChannels: taps.map { _ in 2 }, isFloat32: true, sampleRate: 48000),
            output: BufferLayout(bufferChannels: [2], isFloat32: true, sampleRate: 48000)
        ).get()
    }
    func createIO(_ aggregate: AudioObjectID, renderer: MixRenderer) throws -> AudioDeviceIOProcID {
        try hit("createIO")
        hasIO = true
        return unsafeBitCast(UInt(1), to: AudioDeviceIOProcID.self)
    }
    func startIO(_ aggregate: AudioObjectID, _ io: AudioDeviceIOProcID) throws { try hit("startIO") }
    func stopIO(_ aggregate: AudioObjectID, _ io: AudioDeviceIOProcID) throws { try hit("stopIO") }
    func destroyIO(_ aggregate: AudioObjectID, _ io: AudioDeviceIOProcID) throws {
        try hit("destroyIO")
        hasIO = false
    }
    func bufferFrames(_ aggregate: AudioObjectID) -> Int { 512 }
    func resetService() { taps.removeAll(); aggregate = nil; hasIO = false }
}
