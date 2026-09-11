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
            check(!core.running && core.aggregate == nil,
                  "muting the last audible source releases output immediately")
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
            core.setGain(0.5, key: b, members: [12])
            core.updateActivity([a, b])
            core.reconcile()
            let start = hardware.events.count
            core.syncMembers([12, 13], key: b)
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

        do {
            let hardware = FakeAudioHardware()
            var time: TimeInterval = 0
            let core = AudioCoordinator(hardware: hardware, now: { time })
            core.setGain(0, key: a, members: [11])
            core.updateActivity([a])
            core.preRoll([a])
            core.tick()
            check(core.priming && !core.running && core.controls[a] == .muted && core.taps[a]?.behavior == .muted
                  && hardware.events.contains("startIO") && hardware.primingBuilds == 1 && hardware.builds == 0
                  && !hardware.events.contains("mute:test.a:mutedWhenTapped"),
                  "new zero-percent source primes its muted tap without starting the output device")
            time = 1.6
            core.tick()
            check(!core.priming && !core.running && core.aggregate == nil && !hardware.hasIO
                  && core.taps[a]?.behavior == .muted && core.controls[a] == .muted,
                  "muted priming releases its callback after the deadline and keeps the tap")

            core.setGain(0.1, key: b, members: [12])
            core.tick()
            check(!core.running && core.controls[b] == .held, "a dormant nonzero source does not start output")
            var events = hardware.events.count
            core.syncMembers([11, 13], key: a)
            core.tick()
            check(core.priming && !core.running && core.taps[a]?.members == [11, 13] && core.taps[a]?.behavior == .muted
                  && hardware.events.dropFirst(events).contains("startIO") && hardware.builds == 0,
                  "a fresh member of a muted source primes its tap so its onset is muted")
            time = 3.2
            core.tick()
            check(!core.priming && !core.running && core.aggregate == nil, "member priming on a muted source also expires")

            core.preRoll([b])
            core.tick()
            check(core.running && core.controls[b] == .rendering, "nonzero source discovery pre-rolls its output")
            core.setGain(0, key: b, members: [12])
            core.tick()
            check(!core.running && core.aggregate == nil && core.controls[b] == .muted,
                  "muting during pre-roll cancels output without waiting for its deadline")
            events = hardware.events.count
            time = 5
            core.preRoll([a])
            core.tick()
            check(hardware.events.dropFirst(events).contains("startIO") && core.controls[a] == .muted,
                  "a late discovery event on a muted source still primes its tap")
            time = 6.6
            core.tick()
            core.setGain(0.5, key: a, members: [11, 13])
            core.updateActivity([a])
            core.tick()
            core.setGain(0.1, key: b, members: [12])
            core.setGain(0, key: a, members: [11, 13])
            core.tick()
            check(!core.running && core.aggregate == nil && core.controls[b] == .held,
                  "muting the last playing source skips idle delay even with another saved nonzero gain")
            core.updateActivity([b])
            core.tick()
            check(core.running && core.controls[b] == .rendering && core.controls[a] == .muted,
                  "unmuting resumes audible playback while the other source stays muted")
            core.shutdown()
        }

        do {
            let hardware = FakeAudioHardware()
            let core = AudioCoordinator(hardware: hardware)
            core.setGain(0, key: a, members: [11])
            hardware.routes[12] = [2]
            core.setGain(0.5, key: b, members: [12])
            core.updateActivity([b])
            core.preRoll([b])
            core.tick()
            check(core.controls[b]?.needsAttention == true && core.controls[a] == .muted
                  && core.order == [a] && core.taps[a]?.behavior == .muted,
                  "an unsupported source stays out of the graph while a muted source pre-rolls")
            core.shutdown()
        }

        do {
            let hardware = FakeAudioHardware()
            var time: TimeInterval = 0
            let core = AudioCoordinator(hardware: hardware, now: { time })
            core.setGain(0, key: a, members: [11])
            core.tick()
            time = 2
            core.tick()
            let oldTap = core.taps[a]?.id
            hardware.unavailableOutputs = ["output.one"]
            hardware.output = OutputRoute(id: 2, uid: "output.two", name: "Replacement")
            hardware.routes[11] = []
            core.invalidate(reason: "wake after output disappeared")
            core.tick()
            check(core.lastError == nil && core.route?.uid == "output.two"
                  && core.taps[a]?.route == "output.two" && core.taps[a]?.id != oldTap,
                  "disconnected output does not trap recovery in its old mute guard")
            check(core.requests[a]?.gain == 0 && core.controls[a] == .muted && core.priming && !core.running,
                  "replacement mute preserves intent and primes capture with unchanged idle members")
            time = 4
            core.tick()
            check(!core.priming && !core.running && core.taps[a]?.behavior == .muted && core.lastError == nil,
                  "replacement priming expires without reopening direct playback")
            core.shutdown()
        }

        do {
            let hardware = FakeAudioHardware()
            var time: TimeInterval = 0
            let core = AudioCoordinator(hardware: hardware, now: { time })
            core.setGain(0, key: a, members: [11])
            core.tick()
            time = 2
            core.tick()
            let oldTap = core.taps[a]?.id
            hardware.output = OutputRoute(id: 2, uid: "output.two", name: "Headphones")
            core.invalidate(reason: "default output changed")
            core.tick()
            let movedTap = core.taps[a]?.id
            check(core.lastError == nil && core.priming && !core.running && core.controls[a] == .muted
                  && core.taps[a]?.route == "output.two" && movedTap != oldTap && !hardware.taps.keys.contains(oldTap ?? 0)
                  && hardware.builds == 0,
                  "a live default output change recreates and primes muted taps without starting the new output")
            time = 4
            core.tick()
            check(!core.priming && !core.running && core.taps[a]?.behavior == .muted && core.lastError == nil,
                  "the moved tap's priming expires without reopening direct playback")
            core.invalidate(reason: "wake")
            core.tick()
            check(!core.priming && !core.running && core.taps[a]?.id == movedTap,
                  "an unchanged default output neither recreates nor primes the tap")
            core.shutdown()
        }

        for operation in ["createPrimingAggregate", "createSilentIO"] {
            let hardware = FakeAudioHardware()
            var time: TimeInterval = 0
            let core = AudioCoordinator(hardware: hardware, now: { time })
            hardware.failure = operation
            hardware.failuresLeft = 100
            core.setGain(0, key: a, members: [11])
            core.tick()
            check(core.lastError == nil && core.running && !core.priming && core.controls[a] == .muted
                  && core.taps[a]?.behavior == .muted && hardware.builds == 1 && hardware.hasIO,
                  "\(operation) failure falls back to an output pre-roll with the tap still muted")
            time = 2
            core.tick()
            check(!core.running && !core.priming && core.aggregate == nil && !hardware.hasIO && core.lastError == nil,
                  "\(operation) fallback pre-roll expires normally")
            core.shutdown()
        }

        do {
            let hardware = FakeAudioHardware()
            var time: TimeInterval = 0
            let core = AudioCoordinator(hardware: hardware, now: { time })
            hardware.failure = "startIO"
            hardware.failuresLeft = 2
            core.setGain(0, key: a, members: [11])
            core.tick()
            check(core.lastError != nil && !core.priming && !core.running && core.aggregate == nil && !hardware.hasIO
                  && core.taps[a]?.behavior == .muted && core.controls[a] == .muted,
                  "a priming start failure cleans up and keeps the verified mute")
            time = 1
            core.tick()
            check(core.lastError == nil && core.priming && !core.running,
                  "priming resumes on retry and still avoids the output device")
            core.setGain(0.5, key: b, members: [12])
            core.updateActivity([b])
            core.tick()
            check(core.running && !core.priming && core.controls[b] == .rendering && core.controls[a] == .muted,
                  "audible demand replaces the priming graph with the output graph")
            core.shutdown()
        }

        for operation in ["destroyIO", "destroyAggregate", "destroyTap", "defaultOutput", "startIO"] {
            let hardware = FakeAudioHardware()
            var time: TimeInterval = 0
            let core = AudioCoordinator(hardware: hardware, now: { time })
            core.setGain(0, key: a, members: [11])
            core.setGain(0.5, key: b, members: [12])
            core.updateActivity([b])
            core.tick()
            let oldTapIDs = Set(hardware.taps.keys)
            let builds = hardware.builds
            hardware.unavailableOutputs = ["output.one"]
            hardware.output = OutputRoute(id: 2, uid: "output.two", name: "Replacement")
            hardware.failure = operation
            hardware.failuresLeft = 100
            core.invalidate()
            core.tick()
            check(core.lastError != nil && core.requests[a]?.gain == 0 && core.requests[b]?.gain == 0.5,
                  "\(operation) during disconnected-output recovery preserves requested gains")
            if operation == "destroyIO" {
                check(core.io != nil && hardware.hasIO && Set(hardware.taps.keys) == oldTapIDs && hardware.builds == builds,
                      "disconnected-output recovery never forgets a callback that cannot be destroyed")
            }
            if operation == "destroyAggregate" || operation == "destroyTap" {
                check(Set(hardware.taps.keys) == oldTapIDs,
                      "\(operation) during route recovery retains tap ownership")
            }
            hardware.failure = nil
            core.updateActivity([])
            time = 40
            core.tick()
            check(core.lastError == nil && core.route?.uid == "output.two" && core.running
                  && core.taps.values.allSatisfy { $0.route == "output.two" }
                  && Set(hardware.taps.keys).isDisjoint(with: oldTapIDs) && core.controls[a] == .muted,
                  "\(operation) retry rebuilds and primes replacement taps even after the old deadline")
            core.shutdown()
        }

        for uncertain in [false, true] {
            let hardware = FakeAudioHardware()
            let core = AudioCoordinator(hardware: hardware)
            core.setGain(0.5, key: a, members: [11])
            core.updateActivity([a])
            core.tick()
            let oldTapIDs = Set(hardware.taps.keys)
            hardware.output = OutputRoute(id: 2, uid: "output.two", name: "Replacement")
            hardware.unknownOutputAvailability = uncertain
            hardware.failure = "updateTap"
            hardware.failuresLeft = 100
            let before = hardware.events.count
            core.invalidate()
            core.tick()
            check(core.io != nil && hardware.hasIO && Set(hardware.taps.keys) == oldTapIDs
                  && !hardware.events.dropFirst(before).contains("stopIO"),
                  "a \(uncertain ? "unverifiable" : "still available") old output keeps mute-guard protection")
            hardware.failure = nil
            hardware.unknownOutputAvailability = false
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
                  "a dead member in one app does not fail the others")
            check(core.taps[b] == nil && hardware.taps.count == 1 && core.controls[b] == .waiting
                  && core.lastError == nil, "an app whose only member died waits without a tap")
            core.syncMembers([12], key: b)
            core.reconcile()
            check(core.taps[b] != nil && core.controls[b] == .muted, "fresh members recover the waiting app")
            hardware.deadMembers = [12]
            core.setGain(0.5, key: a, members: [11, 13])
            core.reconcile()
            check(core.running && core.taps[a]?.members == [11, 13] && core.taps[b] == nil
                  && core.controls[b] == .waiting && core.lastError == nil,
                  "a member dying after capture is pruned by the mute guard")
            hardware.deadMembers = []
            hardware.rejectedMembers = [13]
            core.invalidate()
            core.reconcile()
            check(core.taps[a] == nil && core.controls[a]?.needsAttention == true && core.lastError == nil,
                  "a live process HAL refuses to capture is reported on its row")
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
    var rejectedMembers: Set<AudioObjectID> = []
    var output = OutputRoute(id: 1, uid: "output.one", name: "Test output")
    var unavailableOutputs: Set<String> = []
    var unknownOutputAvailability = false
    var aggregate: AudioObjectID?
    var hasIO = false
    var builds = 0
    var primingBuilds = 0
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
        return output
    }
    func outputIsUnavailable(_ uid: String) throws -> Bool {
        try hit("outputIsUnavailable")
        if unknownOutputAvailability { throw AudioFailure(message: "Could not read output availability") }
        return unavailableOutputs.contains(uid)
    }
    func outputDevices(_ process: AudioObjectID) throws -> [AudioObjectID] {
        guard !deadMembers.contains(process) else { throw AudioFailure(message: "No such process") }
        return routes[process] ?? [output.id]
    }
    func createTap(_ tap: ManagedTap) throws -> AudioObjectID {
        try hit("createTap")
        nextID += 1
        taps[nextID] = tap
        return nextID
    }
    func updateTap(_ tap: ManagedTap) throws -> [AudioObjectID] {
        try hit("updateTap")
        if unavailableOutputs.contains(tap.route) {
            throw AudioFailure(message: "HAL did not confirm the capture device (returned none)")
        }
        guard taps[tap.id] != nil else { throw AudioFailure(message: "Stale tap") }
        taps[tap.id] = tap
        events.append("mute:\(tap.key.raw):\(behaviorName(tap.behavior))")
        return tap.members.filter { !deadMembers.contains($0) && !rejectedMembers.contains($0) }
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
    func createPrimingAggregate(taps: [ManagedTap]) throws -> AudioObjectID {
        try hit("createPrimingAggregate")
        nextID += 1
        aggregate = nextID
        primingBuilds += 1
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
    func createSilentIO(_ aggregate: AudioObjectID) throws -> AudioDeviceIOProcID {
        try hit("createSilentIO")
        hasIO = true
        return unsafeBitCast(UInt(2), to: AudioDeviceIOProcID.self)
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
