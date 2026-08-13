import AudioToolbox
import CoreAudio
import Foundation

@MainActor
final class TapEngine {
    private struct Tap {
        let tapID: AudioObjectID
        let uuid: UUID
        var objectIDs: [AudioObjectID]
    }

    private static let aggregateUIDPrefix = "com.buriedanchor.aggregate."

    let renderer = MixRenderer()

    private var taps: [String: Tap] = [:]
    private var order: [String] = []
    private var gains: [String: Float] = [:]
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.buriedanchor.ioproc", qos: .userInteractive)
    private var defaultDeviceListener: PropertyListener?

    private(set) var lastError: String?
    private(set) var outputDeviceName: String = "-"

    var controlledKeys: [String] { order }

    func start() {
        defaultDeviceListener = PropertyListener(
            systemObject,
            propertyAddress(kAudioHardwarePropertyDefaultOutputDevice),
            queue: .main
        ) { [weak self] in
            Task { @MainActor in self?.handleDefaultDeviceChange() }
        }
        refreshOutputDeviceName()
    }

    func shutdown() {
        teardownIO()
        destroyAggregate()
        for tap in taps.values { AudioHardwareDestroyProcessTap(tap.tapID) }
        taps.removeAll()
        order.removeAll()
    }

    func isControlled(_ key: String) -> Bool { taps[key] != nil }

    func gain(for key: String) -> Float { gains[key] ?? 1 }

    func setGain(_ gain: Float, for key: String, objectIDs: [AudioObjectID]) {
        gains[key] = gain
        if taps[key] == nil {
            guard gain != 1 else { return }
            guard !objectIDs.isEmpty else { return }
            guard taps.count < MixRenderer.maxSlots else {
                lastError = "at the \(MixRenderer.maxSlots)-app limit; right-click an app and reset it to free a slot"
                log.error("tap limit reached, refusing \(key, privacy: .public)")
                return
            }
            guard createTap(key: key, objectIDs: objectIDs) else { return }
            rebuild()
            return
        }
        if let slot = order.firstIndex(of: key) {
            renderer.setGain(gain, slot: slot)
        }
    }

    func release(_ key: String) {
        guard let tap = taps.removeValue(forKey: key) else { return }
        order.removeAll { $0 == key }
        gains[key] = 1
        AudioHardwareDestroyProcessTap(tap.tapID)
        rebuild()
    }

    func syncObjectIDs(_ objectIDs: [AudioObjectID], for key: String) {
        guard var tap = taps[key], !objectIDs.isEmpty, tap.objectIDs != objectIDs else { return }
        let description = makeDescription(uuid: tap.uuid, objectIDs: objectIDs, key: key)
        var address = propertyAddress(kAudioTapPropertyDescription)
        var object: CATapDescription? = description
        let size = UInt32(MemoryLayout<CATapDescription?>.size)
        let status = withUnsafePointer(to: &object) { pointer in
            AudioObjectSetPropertyData(tap.tapID, &address, 0, nil, size, pointer)
        }
        guard status == noErr else {
            log.error("tap description update failed for \(key, privacy: .public): \(statusName(status), privacy: .public)")
            return
        }
        tap.objectIDs = objectIDs
        taps[key] = tap
        log.debug("tap \(key, privacy: .public) now covers \(objectIDs.count) process objects")
    }

    private func createTap(key: String, objectIDs: [AudioObjectID]) -> Bool {
        let uuid = UUID()
        let description = makeDescription(uuid: uuid, objectIDs: objectIDs, key: key)
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            lastError = "tap creation failed: \(statusName(status))"
            log.error("tap creation failed for \(key, privacy: .public): \(statusName(status), privacy: .public)")
            return false
        }
        taps[key] = Tap(tapID: tapID, uuid: uuid, objectIDs: objectIDs)
        order.append(key)
        return true
    }

    private func makeDescription(
        uuid: UUID, objectIDs: [AudioObjectID], key: String
    ) -> CATapDescription {
        let description = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        description.uuid = uuid
        description.name = "buried-anchor \(key)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        description.isProcessRestoreEnabled = true
        return description
    }

    private func rebuild() {
        teardownIO()
        destroyAggregate()
        guard !order.isEmpty else {
            renderer.setSlotCount(0)
            lastError = nil
            return
        }
        guard let uid = defaultOutputUID() else {
            lastError = "no usable output device; passing audio through untouched"
            renderer.setSlotCount(0)
            log.error("default output is unusable or is our own aggregate; not rebuilding")
            return
        }
        guard createAggregate(outputUID: uid) else { return }
        renderer.setSlotCount(order.count)
        for (slot, key) in order.enumerated() {
            renderer.primeGain(gains[key] ?? 1, slot: slot)
        }
        configureRenderer()
        startIO()
    }

    private func createAggregate(outputUID: String) -> Bool {
        let tag = UUID().uuidString
        let tapList = order.compactMap { key -> [String: Any]? in
            guard let tap = taps[key] else { return nil }
            return [
                kAudioSubTapUIDKey: tap.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]
        }
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Buried Anchor Mix",
            kAudioAggregateDeviceUIDKey: "\(Self.aggregateUIDPrefix)\(tag)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: tapList
        ]
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &deviceID)
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            lastError = "aggregate creation failed: \(statusName(status))"
            log.error("aggregate creation failed: \(statusName(status), privacy: .public)")
            return false
        }
        aggregateID = deviceID
        lastError = nil
        log.debug("aggregate \(deviceID) built with \(tapList.count) taps on \(outputUID, privacy: .public)")
        return true
    }

    private func configureRenderer() {
        guard aggregateID != AudioObjectID(kAudioObjectUnknown) else { return }
        var asbd = AudioStreamBasicDescription()
        if let first = order.first, let tap = taps[first] {
            var address = propertyAddress(kAudioTapPropertyFormat)
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            AudioObjectGetPropertyData(tap.tapID, &address, 0, nil, &size, &asbd)
        }
        let frames = aggregateID.value(
            propertyAddress(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeOutput),
            default: UInt32(512)
        )
        renderer.configure(
            sampleRate: asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000,
            framesPerBuffer: Int(frames)
        )
    }

    private nonisolated static func installIOProc(
        aggregate: AudioObjectID,
        queue: DispatchQueue,
        renderer: MixRenderer
    ) -> (AudioDeviceIOProcID?, OSStatus) {
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue) {
            _, inputData, _, outputData, _ in
            renderer.render(input: inputData, output: outputData)
        }
        return (procID, status)
    }

    private func startIO() {
        let (procID, status) = Self.installIOProc(
            aggregate: aggregateID, queue: ioQueue, renderer: renderer
        )
        guard status == noErr, let procID else {
            lastError = "IOProc creation failed: \(statusName(status))"
            log.error("IOProc creation failed: \(statusName(status), privacy: .public)")
            return
        }
        ioProcID = procID
        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            lastError = "device start failed: \(statusName(startStatus))"
            log.error("device start failed: \(statusName(startStatus), privacy: .public)")
            return
        }
        log.debug("IOProc started on aggregate \(self.aggregateID)")
    }

    private func teardownIO() {
        guard let procID = ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) else {
            ioProcID = nil
            return
        }
        AudioDeviceStop(aggregateID, procID)
        AudioDeviceDestroyIOProcID(aggregateID, procID)
        ioProcID = nil
    }

    private func destroyAggregate() {
        guard aggregateID != AudioObjectID(kAudioObjectUnknown) else { return }
        AudioHardwareDestroyAggregateDevice(aggregateID)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
    }

    private func handleDefaultDeviceChange() {
        refreshOutputDeviceName()
        guard !order.isEmpty else { return }
        log.debug("default output changed, rebuilding")
        rebuild()
    }

    private func defaultOutputDevice() -> AudioObjectID {
        systemObject.value(
            propertyAddress(kAudioHardwarePropertyDefaultOutputDevice),
            default: AudioObjectID(kAudioObjectUnknown)
        )
    }

    private func defaultOutputUID() -> String? {
        let device = defaultOutputDevice()
        guard device != AudioObjectID(kAudioObjectUnknown), device != aggregateID else { return nil }
        guard let uid = device.string(propertyAddress(kAudioDevicePropertyDeviceUID)),
              !uid.hasPrefix(Self.aggregateUIDPrefix)
        else { return nil }
        return uid
    }

    private func refreshOutputDeviceName() {
        let device = defaultOutputDevice()
        guard defaultOutputUID() != nil else {
            outputDeviceName = "-"
            return
        }
        outputDeviceName = device.string(propertyAddress(kAudioObjectPropertyName)) ?? "-"
    }
}
