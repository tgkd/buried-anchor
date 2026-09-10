import CoreAudio
import Foundation

struct AudioFailure: Error, LocalizedError {
    let message: String
    var staleMembership = false
    var errorDescription: String? { message }
}

struct OutputRoute: Equatable, Sendable {
    let id: AudioObjectID
    let uid: String
    let name: String
    var stream: UInt = 0
}

struct ManagedTap {
    let id: AudioObjectID
    let uuid: UUID
    let key: SourceID
    var members: [AudioObjectID]
    var route: String
    var behavior: CATapMuteBehavior
    var stream: UInt = 0
}

protocol AudioHardwareBackend: AnyObject {
    func defaultOutput() throws -> OutputRoute
    func outputIsUnavailable(_ uid: String) throws -> Bool
    func outputDevices(_ process: AudioObjectID) throws -> [AudioObjectID]
    func createTap(_ tap: ManagedTap) throws -> AudioObjectID
    func updateTap(_ tap: ManagedTap) throws -> [AudioObjectID]
    func destroyTap(_ id: AudioObjectID) throws
    func createAggregate(_ route: OutputRoute, taps: [ManagedTap]) throws -> AudioObjectID
    func destroyAggregate(_ id: AudioObjectID) throws
    func layout(_ aggregate: AudioObjectID, route: OutputRoute, taps: [ManagedTap]) throws -> GraphLayout
    func createIO(_ aggregate: AudioObjectID, renderer: MixRenderer) throws -> AudioDeviceIOProcID
    func startIO(_ aggregate: AudioObjectID, _ io: AudioDeviceIOProcID) throws
    func stopIO(_ aggregate: AudioObjectID, _ io: AudioDeviceIOProcID) throws
    func destroyIO(_ aggregate: AudioObjectID, _ io: AudioDeviceIOProcID) throws
    func bufferFrames(_ aggregate: AudioObjectID) -> Int
}

final class CoreAudioBackend: AudioHardwareBackend {
    static let aggregatePrefix = "com.buriedanchor.aggregate."

    private func check(_ status: OSStatus, _ operation: String, destroying: Bool = false) throws {
        DiagnosticLog.record("hal.operation", "operation=\(operation) status=\(statusName(status))")
        guard status != noErr, !(destroying && status == kAudioHardwareBadObjectError) else { return }
        throw AudioFailure(message: "\(operation): \(statusName(status))")
    }

    func defaultOutput() throws -> OutputRoute {
        let id = systemObject.value(propertyAddress(kAudioHardwarePropertyDefaultOutputDevice),
                                    default: AudioObjectID(kAudioObjectUnknown))
        guard id != kAudioObjectUnknown,
              id.value(propertyAddress(kAudioDevicePropertyDeviceIsAlive), default: UInt32(0)) != 0,
              let uid = id.string(propertyAddress(kAudioDevicePropertyDeviceUID)),
              !uid.hasPrefix(Self.aggregatePrefix) else {
            throw AudioFailure(message: "No usable default output device")
        }
        let channels = id.streamChannelCounts(kAudioObjectPropertyScopeOutput).reduce(0, +)
        let preferred = id.array(propertyAddress(kAudioDevicePropertyPreferredChannelsForStereo,
                                                kAudioObjectPropertyScopeOutput), of: UInt32.self)
        let pair = preferred.count == 2 ? preferred.map(Int.init) : (channels <= 2 ? [1, 2] : [])
        let streams = id.streams(kAudioObjectPropertyScopeOutput)
        guard channels >= 1, channels <= 2, streams.count == 1 else {
            throw AudioFailure(message: "This output is not supported: choose a device with one mono or stereo output stream")
        }
        let selected = streams.enumerated().first { _, stream in
            guard let format = stream.virtualFormat else { return false }
            let start = Int(stream.value(propertyAddress(kAudioStreamPropertyStartingChannel), default: UInt32(0)))
            if channels == 1 { return format.mChannelsPerFrame == 1 && start == 1 }
            return format.mChannelsPerFrame == 2 && pair.count == 2 && Set(pair) == [start, start + 1]
        }
        guard let selected else {
            throw AudioFailure(message: "The default output must expose a mono or stereo stream for its preferred speaker pair")
        }
        return OutputRoute(id: id, uid: uid, name: id.string(propertyAddress(kAudioObjectPropertyName)) ?? uid,
                           stream: UInt(selected.offset))
    }

    func outputIsUnavailable(_ uid: String) throws -> Bool {
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size), "Read device list size")
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        if !devices.isEmpty {
            try check(AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &devices), "Read device list")
            devices = Array(devices.prefix(Int(size) / MemoryLayout<AudioObjectID>.stride))
        }
        guard let device = devices.first(where: { $0.string(propertyAddress(kAudioDevicePropertyDeviceUID)) == uid }) else {
            DiagnosticLog.record("hal.outputMissing", "device=\(uid) devices=\(devices)")
            return true
        }
        let alive = device.value(propertyAddress(kAudioDevicePropertyDeviceIsAlive), default: UInt32(1)) != 0
        DiagnosticLog.record("hal.outputPresent", "device=\(uid) id=\(device) alive=\(alive)")
        return !alive
    }

    func outputDevices(_ process: AudioObjectID) throws -> [AudioObjectID] {
        let address = propertyAddress(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput)
        guard process.dataSize(address) != nil else {
            throw AudioFailure(message: "Could not verify the app's output device")
        }
        return process.array(address, of: AudioObjectID.self)
    }

    private func description(_ tap: ManagedTap) -> CATapDescription {
        let result = CATapDescription(processes: tap.members, deviceUID: tap.route, stream: tap.stream)
        result.uuid = tap.uuid
        result.name = "buried-anchor \(tap.key.raw)"
        result.isPrivate = true
        result.muteBehavior = tap.behavior
        result.isProcessRestoreEnabled = false
        return result
    }

    func createTap(_ tap: ManagedTap) throws -> AudioObjectID {
        var id = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description(tap), &id), "Create capture tap")
        guard id != kAudioObjectUnknown else { throw AudioFailure(message: "HAL returned an invalid tap") }
        DiagnosticLog.record("tap.created", "source=\(tap.key.raw) id=\(id) members=\(tap.members) device=\(tap.route) mute=\(behaviorName(tap.behavior))")
        return id
    }

    func updateTap(_ tap: ManagedTap) throws -> [AudioObjectID] {
        DiagnosticLog.record("tap.update", "source=\(tap.key.raw) id=\(tap.id) members=\(tap.members) device=\(tap.route) stream=\(tap.stream) mute=\(behaviorName(tap.behavior))")
        var address = propertyAddress(kAudioTapPropertyDescription)
        var value: CATapDescription? = description(tap)
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(tap.id, &address, 0, nil,
                                       UInt32(MemoryLayout<CATapDescription?>.size), $0)
        }
        try check(status, "Update capture tap")
        let live = try readTap(tap.id)
        DiagnosticLog.record("tap.readback", tapSummary(tap.id, live))
        guard live.muteBehavior == tap.behavior else { throw AudioFailure(message: "HAL did not confirm capture mute state") }
        guard live.deviceUID == tap.route else {
            throw AudioFailure(message: "HAL did not confirm the capture device (returned \(live.deviceUID ?? "none"))")
        }
        guard live.stream == tap.stream else { throw AudioFailure(message: "HAL did not confirm the capture stream") }
        return live.processes
    }

    private func readTap(_ id: AudioObjectID) throws -> CATapDescription {
        var address = propertyAddress(kAudioTapPropertyDescription)
        var raw: Unmanaged<CATapDescription>?
        var size = UInt32(MemoryLayout<CATapDescription?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &raw)
        if status != noErr { try check(status, "Read capture tap \(id)") }
        guard let live = raw?.takeRetainedValue() else { throw AudioFailure(message: "HAL did not return the capture description") }
        return live
    }

    private func tapSummary(_ id: AudioObjectID, _ live: CATapDescription) -> String {
        "id=\(id) name=\(live.name) members=\(live.processes) device=\(live.deviceUID ?? "none") stream=\(String(describing: live.stream)) mute=\(behaviorName(live.muteBehavior))"
    }

    /// Read-only snapshots; no permission probes, tap writes or IO starts.
    func diagnostics(_ taps: [ManagedTap]) -> [String] {
        var lines: [String] = []
        let output = systemObject.value(propertyAddress(kAudioHardwarePropertyDefaultOutputDevice), default: UInt32(0))
        let effects = systemObject.value(propertyAddress(kAudioHardwarePropertyDefaultSystemOutputDevice), default: UInt32(0))
        lines.append("defaultOutput=\(output) systemOutput=\(effects) deviceRunning=\(output.value(propertyAddress(kAudioDevicePropertyDeviceIsRunningSomewhere), default: UInt32(0)))")
        for tap in taps.sorted(by: { $0.key.raw < $1.key.raw }) {
            do { lines.append(tapSummary(tap.id, try readTap(tap.id))) }
            catch { lines.append("source=\(tap.key.raw) id=\(tap.id) readError=\(error.localizedDescription)") }
            for member in tap.members {
                let devices = try? outputDevices(member)
                let playing = member.optionalValue(propertyAddress(kAudioProcessPropertyIsRunningOutput), of: UInt32.self)
                lines.append("source=\(tap.key.raw) member=\(member) devices=\(String(describing: devices)) playing=\(String(describing: playing))")
            }
        }
        return lines
    }

    func destroyTap(_ id: AudioObjectID) throws {
        DiagnosticLog.record("tap.destroy", "id=\(id)")
        try check(AudioHardwareDestroyProcessTap(id), "Destroy capture tap", destroying: true)
    }

    func createAggregate(_ route: OutputRoute, taps: [ManagedTap]) throws -> AudioObjectID {
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Buried Anchor Mix",
            kAudioAggregateDeviceUIDKey: Self.aggregatePrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: route.uid,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: route.uid]],
            kAudioAggregateDeviceTapListKey: taps.map {
                [kAudioSubTapUIDKey: $0.uuid.uuidString, kAudioSubTapDriftCompensationKey: true] as [String: Any]
            }
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &id), "Create mix device")
        guard id != kAudioObjectUnknown else { throw AudioFailure(message: "HAL returned an invalid aggregate") }
        DiagnosticLog.record("graph.created", "aggregate=\(id) output=\(route.uid) taps=\(taps.map(\.id))")
        return id
    }

    func destroyAggregate(_ id: AudioObjectID) throws {
        try check(AudioHardwareDestroyAggregateDevice(id), "Destroy mix device", destroying: true)
    }

    private func buffers(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) throws -> BufferLayout {
        let ids = device.streams(scope)
        let formats = ids.compactMap(\.virtualFormat)
        guard !ids.isEmpty, formats.count == ids.count, formats.allSatisfy(\.isFloat32),
              let rate = formats.first?.mSampleRate, formats.allSatisfy({ $0.mSampleRate == rate }) else {
            throw AudioFailure(message: "Could not verify all aggregate streams as packed native Float32 at one sample rate")
        }
        return BufferLayout(bufferChannels: device.streamChannelCounts(scope), isFloat32: true, sampleRate: rate)
    }

    func layout(_ aggregate: AudioObjectID, route: OutputRoute, taps: [ManagedTap]) throws -> GraphLayout {
        let uuids = aggregate.stringArray(propertyAddress(kAudioAggregateDevicePropertyTapList)).map { $0.uppercased() }
        let lookup = Dictionary(uniqueKeysWithValues: taps.map { ($0.uuid.uuidString.uppercased(), $0) })
        guard uuids.count == taps.count, Set(uuids) == Set(lookup.keys),
              aggregate.array(propertyAddress(kAudioAggregateDevicePropertySubTapList), of: AudioObjectID.self).count == taps.count else {
            throw AudioFailure(message: "Could not verify aggregate tap order and membership")
        }
        let ordered = uuids.compactMap { lookup[$0] }
        let formats = try ordered.map { tap -> TapFormat in
            guard let format = tap.id.optionalValue(propertyAddress(kAudioTapPropertyFormat), of: AudioStreamBasicDescription.self),
                  format.isFloat32, format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 else {
                throw AudioFailure(message: "Capture tap is not supported interleaved Float32")
            }
            return TapFormat(key: tap.key, channels: Int(format.mChannelsPerFrame),
                             sampleRate: format.mSampleRate, isFloat32: true)
        }
        let output = try buffers(aggregate, kAudioObjectPropertyScopeOutput)
        let stereo = [0, 1]
        return try GraphLayout.resolve(
            taps: formats, input: buffers(aggregate, kAudioObjectPropertyScopeInput), output: output,
            inputPrefix: route.id.streamChannelCounts(kAudioObjectPropertyScopeInput), stereoChannels: stereo
        ).get()
    }

    func createIO(_ aggregate: AudioObjectID, renderer: MixRenderer) throws -> AudioDeviceIOProcID {
        var io: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, nil) { _, input, _, output, _ in
            renderer.render(input: input, output: output)
        }, "Create audio callback")
        guard let io else { throw AudioFailure(message: "HAL returned an invalid audio callback") }
        return io
    }

    func startIO(_ aggregate: AudioObjectID, _ io: AudioDeviceIOProcID) throws {
        try check(AudioDeviceStart(aggregate, io), "Start audio callback")
    }
    func stopIO(_ aggregate: AudioObjectID, _ io: AudioDeviceIOProcID) throws {
        try check(AudioDeviceStop(aggregate, io), "Stop audio callback", destroying: true)
    }
    func destroyIO(_ aggregate: AudioObjectID, _ io: AudioDeviceIOProcID) throws {
        try check(AudioDeviceDestroyIOProcID(aggregate, io), "Destroy audio callback", destroying: true)
    }
    func bufferFrames(_ aggregate: AudioObjectID) -> Int {
        Int(aggregate.value(propertyAddress(kAudioDevicePropertyBufferFrameSize), default: UInt32(512)))
    }
}
