import AudioToolbox
import CoreAudio
import Foundation

@MainActor
final class TapEngine {
    enum State: Equatable {
        case idle
        case active
        case suspended
        case failed(String)

        var isFailed: Bool { if case .failed = self { true } else { false } }
    }

    private struct Tap {
        let tapID: AudioObjectID
        let uuid: UUID
        var objectIDs: [AudioObjectID]
        var behavior: CATapMuteBehavior
    }

    private struct DeviceSignature: Equatable, CustomStringConvertible {
        let uid: String
        let channels: [Int]
        let sampleRate: Double

        static let none = DeviceSignature(uid: "", channels: [], sampleRate: 0)

        var description: String { "\(uid) ch=\(channels) rate=\(Int(sampleRate))" }
    }

    private static let aggregateUIDPrefix = "com.buriedanchor.aggregate."
    private static let retryDelays: [TimeInterval] = [1, 2, 5, 15, 30]

    let renderer = MixRenderer()

    private var taps: [SourceID: Tap] = [:]
    private var order: [SourceID] = []
    private var gains: [SourceID: Float] = [:]
    private var doomed: [Tap] = []
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var outputDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var signature = DeviceSignature.none
    private var sampleRate: Double = 48000
    private let ioQueue = DispatchQueue(label: "com.buriedanchor.ioproc", qos: .userInteractive)
    private var defaultDeviceListener: PropertyListener?
    private var deviceListeners: [PropertyListener] = []
    private var retryIndex = 0
    private var retryAt: Date?
    private var wantsIO = false

    private(set) var state: State = .idle
    private(set) var lastError: String?
    private(set) var outputDeviceName: String = "-"
    private(set) var layoutSummary: String = "-"

    var controlledKeys: [SourceID] { order }
    var controlledCount: Int { order.count }
    var isSuspended: Bool { state == .suspended }

    func start() {
        defaultDeviceListener = PropertyListener(
            systemObject,
            propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        ) { [weak self] in
            Task { @MainActor in self?.handleRouteChange("default output device") }
        }
        refreshOutputDeviceName()
    }

    func shutdown() {
        wantsIO = false
        stopGraph()
        defaultDeviceListener = nil
        for (key, tap) in taps { destroy(tap, key: key) }
        taps.removeAll()
        order.removeAll()
        destroyDoomedTaps()
        state = .idle
    }

    func isControlled(_ key: SourceID) -> Bool { taps[key] != nil }

    func isActive(_ key: SourceID) -> Bool { state == .active && taps[key] != nil }

    func gain(for key: SourceID) -> Float { gains[key] ?? 1 }

    func setGain(_ gain: Float, for key: SourceID, objectIDs: [AudioObjectID]) {
        gains[key] = gain
        if taps[key] == nil {
            guard gain != 1, !objectIDs.isEmpty else { return }
            guard taps.count < MixRenderer.maxSlots else {
                lastError = "at the \(MixRenderer.maxSlots)-app limit; right-click an app and reset it to free a slot"
                log.error("tap limit reached, refusing \(key.raw, privacy: .public)")
                return
            }
            guard createTap(key: key, objectIDs: objectIDs) else { return }
            rebuild(reason: "new source \(key.raw)")
            return
        }
        if let slot = order.firstIndex(of: key) {
            renderer.setGain(gain, slot: slot)
        }
        reconcile(reason: "gain \(key.raw)")
    }

    func release(_ key: SourceID) { release([key]) }

    func release(_ keys: [SourceID]) {
        var removed = false
        for key in keys {
            guard let tap = taps.removeValue(forKey: key) else { continue }
            doomed.append(tap)
            order.removeAll { $0 == key }
            gains[key] = 1
            removed = true
        }
        guard removed else { return }
        log.debug("releasing \(keys.map(\.raw).joined(separator: ","), privacy: .public)")
        rebuild(reason: "release")
    }

    func suspend() {
        guard wantsIO else { return }
        wantsIO = false
        reconcile(reason: "suspend")
    }

    func resume() {
        guard !wantsIO else { return }
        wantsIO = true
        reconcile(reason: "resume")
    }

    private var needsGraph: Bool {
        order.contains { (gains[$0] ?? 1) != 1 }
    }

    private func reconcile(reason: String) {
        guard !order.isEmpty else {
            dropGraph()
            state = .idle
            lastError = nil
            retryIndex = 0
            return
        }
        guard needsGraph else {
            dropGraph()
            state = .suspended
            lastError = nil
            retryIndex = 0
            applyMuteBehaviors()
            return
        }
        guard aggregateID != AudioObjectID(kAudioObjectUnknown), !state.isFailed else {
            rebuild(reason: reason)
            return
        }
        if wantsIO, ioProcID == nil {
            guard startIO() else {
                renderer.clearSlots()
                stopGraph()
                return
            }
            state = .active
            log.debug("resumed (\(reason, privacy: .public)): IOProc started")
        } else if !wantsIO, ioProcID != nil {
            teardownIO()
            state = .suspended
            log.debug("suspended (\(reason, privacy: .public)): IOProc torn down, \(self.order.count) taps kept")
        }
        applyMuteBehaviors()
    }

    private func dropGraph() {
        guard aggregateID != AudioObjectID(kAudioObjectUnknown) || ioProcID != nil else { return }
        stopGraph()
        renderer.clearSlots()
        layoutSummary = "-"
        log.debug("graph released, \(self.order.count) taps kept")
    }

    func retryIfDue() {
        guard state.isFailed, let at = retryAt, Date() >= at else { return }
        retryAt = nil
        rebuild(reason: "retry \(retryIndex)")
    }

    func syncObjectIDs(_ objectIDs: [AudioObjectID], for key: SourceID) {
        guard var tap = taps[key], !objectIDs.isEmpty, tap.objectIDs != objectIDs else { return }
        let behavior = muteBehavior(for: key)
        guard writeDescription(tap, key: key, objectIDs: objectIDs, behavior: behavior) else {
            return
        }
        tap.objectIDs = objectIDs
        tap.behavior = behavior
        taps[key] = tap
        log.debug("tap \(key.raw, privacy: .public) now covers \(objectIDs.count) process objects")
    }

    private func muteBehavior(for key: SourceID) -> CATapMuteBehavior {
        guard ioProcID == nil else { return .mutedWhenTapped }
        return (gains[key] ?? 1) == 1 ? .mutedWhenTapped : .muted
    }

    private func applyMuteBehaviors() {
        for key in order {
            guard var tap = taps[key] else { continue }
            let wanted = muteBehavior(for: key)
            guard tap.behavior != wanted else { continue }
            guard writeDescription(tap, key: key, objectIDs: tap.objectIDs, behavior: wanted)
            else { continue }
            tap.behavior = wanted
            taps[key] = tap
            log.debug(
                "tap \(key.raw, privacy: .public) mute behavior -> \(behaviorName(wanted), privacy: .public)"
            )
        }
    }

    private func writeDescription(
        _ tap: Tap, key: SourceID, objectIDs: [AudioObjectID], behavior: CATapMuteBehavior
    ) -> Bool {
        let description = makeDescription(
            uuid: tap.uuid, objectIDs: objectIDs, key: key, behavior: behavior
        )
        var address = propertyAddress(kAudioTapPropertyDescription)
        var object: CATapDescription? = description
        let size = UInt32(MemoryLayout<CATapDescription?>.size)
        let status = withUnsafePointer(to: &object) { pointer in
            AudioObjectSetPropertyData(tap.tapID, &address, 0, nil, size, pointer)
        }
        guard status == noErr else {
            log.error("tap description update failed for \(key.raw, privacy: .public): \(statusName(status), privacy: .public)")
            return false
        }
        return true
    }

    private func liveBehavior(_ tapID: AudioObjectID) -> String {
        var address = propertyAddress(kAudioTapPropertyDescription)
        var size = UInt32(MemoryLayout<CATapDescription?>.size)
        var raw: Unmanaged<CATapDescription>?
        let status = withUnsafeMutablePointer(to: &raw) { pointer in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let raw else { return "?" }
        return behaviorName(raw.takeRetainedValue().muteBehavior)
    }

    private func createTap(key: SourceID, objectIDs: [AudioObjectID]) -> Bool {
        let uuid = UUID()
        let behavior = muteBehavior(for: key)
        let description = makeDescription(
            uuid: uuid, objectIDs: objectIDs, key: key, behavior: behavior
        )
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            lastError = "tap creation failed: \(statusName(status))"
            log.error("tap creation failed for \(key.raw, privacy: .public): \(statusName(status), privacy: .public)")
            return false
        }
        taps[key] = Tap(tapID: tapID, uuid: uuid, objectIDs: objectIDs, behavior: behavior)
        order.append(key)
        return true
    }

    private func makeDescription(
        uuid: UUID, objectIDs: [AudioObjectID], key: SourceID, behavior: CATapMuteBehavior
    ) -> CATapDescription {
        let description = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        description.uuid = uuid
        description.name = "buried-anchor \(key.raw)"
        description.isPrivate = true
        description.muteBehavior = behavior
        description.isProcessRestoreEnabled = true
        return description
    }

    private func rebuild(reason: String) {
        stopGraph()
        destroyDoomedTaps()
        retryAt = nil

        guard !order.isEmpty else {
            renderer.clearSlots()
            state = .idle
            lastError = nil
            retryIndex = 0
            layoutSummary = "-"
            return
        }
        guard needsGraph else {
            renderer.clearSlots()
            state = .suspended
            lastError = nil
            retryIndex = 0
            layoutSummary = "-"
            applyMuteBehaviors()
            log.debug("graph not needed (\(reason, privacy: .public)): no controlled gain renders")
            return
        }
        guard let device = usableDefaultOutput() else {
            renderer.clearSlots()
            fail("no usable output device; audio is passing through untouched")
            return
        }
        guard let aggregate = createAggregate(outputUID: device.uid) else {
            renderer.clearSlots()
            return
        }

        switch discoverLayout(aggregate: aggregate) {
        case .failure(let fault):
            renderer.clearSlots()
            destroyAggregate(aggregate)
            fail(fault.message)
            log.error("layout rejected: \(String(describing: fault), privacy: .public)")
        case .success(let layout):
            aggregateID = aggregate
            order = layout.slots.map(\.key)
            sampleRate = layout.sampleRate
            renderer.apply(layout, gains: order.map { gains[$0] ?? 1 })
            renderer.configure(sampleRate: layout.sampleRate, framesPerBuffer: bufferFrames())
            if wantsIO {
                guard startIO() else {
                    renderer.clearSlots()
                    stopGraph()
                    return
                }
                state = .active
            } else {
                state = .suspended
            }
            outputDeviceID = device.id
            signature = deviceSignature(device.id)
            layoutSummary = layout.summary
            installDeviceListeners()
            applyMuteBehaviors()
            lastError = nil
            retryIndex = 0
            log.debug("graph up (\(reason, privacy: .public)) io=\(self.wantsIO): \(layout.summary, privacy: .public)")
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        lastError = message
        signature = .none
        layoutSummary = "-"
        let delay = Self.retryDelays[min(retryIndex, Self.retryDelays.count - 1)]
        retryIndex += 1
        retryAt = Date().addingTimeInterval(delay)
        log.error("graph failed: \(message, privacy: .public); retry in \(delay)s")
    }

    private func createAggregate(outputUID: String) -> AudioObjectID? {
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
            fail("aggregate creation failed: \(statusName(status))")
            return nil
        }
        return deviceID
    }

    private func discoverLayout(aggregate: AudioObjectID) -> Result<GraphLayout, LayoutFault> {
        let slotOrder = tapOrder(of: aggregate)
        var formats: [TapFormat] = []
        for key in slotOrder {
            guard let tap = taps[key],
                  let asbd = tap.tapID.optionalValue(
                      propertyAddress(kAudioTapPropertyFormat), of: AudioStreamBasicDescription.self
                  )
            else { return .failure(.tapNotFloat32) }
            formats.append(
                TapFormat(
                    key: key,
                    channels: Int(asbd.mChannelsPerFrame),
                    sampleRate: asbd.mSampleRate,
                    isFloat32: asbd.isFloat32
                )
            )
        }
        return GraphLayout.resolve(
            taps: formats,
            input: bufferLayout(aggregate, scope: kAudioObjectPropertyScopeInput),
            output: bufferLayout(aggregate, scope: kAudioObjectPropertyScopeOutput)
        )
    }

    private func tapOrder(of aggregate: AudioObjectID) -> [SourceID] {
        let uuids = aggregate.stringArray(propertyAddress(kAudioAggregateDevicePropertyTapList))
        var byUUID: [String: SourceID] = [:]
        for (key, tap) in taps { byUUID[tap.uuid.uuidString.uppercased()] = key }
        let resolved = uuids.compactMap { byUUID[$0.uppercased()] }
        guard resolved.count == order.count, Set(resolved) == Set(order) else {
            log.error("aggregate tap list \(uuids.count) does not cover our \(self.order.count) taps; using composition order")
            return order
        }
        if resolved != order {
            log.debug("aggregate reordered taps; adopting its order")
        }
        return resolved
    }

    private func bufferLayout(
        _ device: AudioObjectID, scope: AudioObjectPropertyScope
    ) -> BufferLayout {
        let channels = device.streamChannelCounts(scope)
        let formats = device.streams(scope).compactMap(\.virtualFormat)
        return BufferLayout(
            bufferChannels: channels,
            isFloat32: !formats.isEmpty && formats.allSatisfy(\.isFloat32),
            sampleRate: formats.first?.mSampleRate ?? 0
        )
    }

    private func bufferFrames() -> Int {
        Int(
            aggregateID.value(
                propertyAddress(kAudioDevicePropertyBufferFrameSize), default: UInt32(512)
            )
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

    private func startIO() -> Bool {
        let (procID, status) = Self.installIOProc(
            aggregate: aggregateID, queue: ioQueue, renderer: renderer
        )
        guard status == noErr, let procID else {
            fail("IOProc creation failed: \(statusName(status))")
            return false
        }
        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            check(AudioDeviceDestroyIOProcID(aggregateID, procID), "destroy IOProc after failed start")
            fail("device start failed: \(statusName(startStatus))")
            return false
        }
        ioProcID = procID
        return true
    }

    private func stopGraph() {
        deviceListeners.removeAll()
        teardownIO()
        destroyAggregate(aggregateID)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        outputDeviceID = AudioObjectID(kAudioObjectUnknown)
        signature = .none
    }

    private func teardownIO() {
        guard let procID = ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) else {
            ioProcID = nil
            return
        }
        check(AudioDeviceStop(aggregateID, procID), "stop IOProc")
        check(AudioDeviceDestroyIOProcID(aggregateID, procID), "destroy IOProc")
        ioProcID = nil
    }

    private func destroyAggregate(_ device: AudioObjectID) {
        guard device != AudioObjectID(kAudioObjectUnknown) else { return }
        check(AudioHardwareDestroyAggregateDevice(device), "destroy aggregate")
    }

    private func destroyDoomedTaps() {
        guard !doomed.isEmpty else { return }
        var survivors: [Tap] = []
        for tap in doomed {
            let status = AudioHardwareDestroyProcessTap(tap.tapID)
            if status != noErr {
                log.error("destroy tap \(tap.tapID) failed: \(statusName(status), privacy: .public)")
                survivors.append(tap)
            }
        }
        doomed = survivors
    }

    private func destroy(_ tap: Tap, key: SourceID) {
        let status = AudioHardwareDestroyProcessTap(tap.tapID)
        guard status != noErr else { return }
        log.error("destroy tap for \(key.raw, privacy: .public) failed: \(statusName(status), privacy: .public)")
    }

    private func check(_ status: OSStatus, _ what: String) {
        guard status != noErr else { return }
        log.error("\(what, privacy: .public) failed: \(statusName(status), privacy: .public)")
    }

    private func installDeviceListeners() {
        var listeners: [PropertyListener?] = []
        for (selector, scope) in [
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal)
        ] {
            listeners.append(
                PropertyListener(outputDeviceID, propertyAddress(selector, scope)) {
                    [weak self] in
                    Task { @MainActor in self?.handleRouteChange(fourCC(selector)) }
                }
            )
        }
        listeners.append(
            PropertyListener(
                aggregateID,
                propertyAddress(kAudioDevicePropertyIOStoppedAbnormally)
            ) { [weak self] in
                Task { @MainActor in self?.handleAbnormalStop() }
            }
        )
        listeners.append(
            PropertyListener(
                aggregateID, propertyAddress(kAudioDevicePropertyBufferFrameSize)
            ) { [weak self] in
                Task { @MainActor in self?.handleBufferSizeChange() }
            }
        )
        deviceListeners = listeners.compactMap { $0 }
    }

    private func handleRouteChange(_ reason: String) {
        refreshOutputDeviceName()
        guard !order.isEmpty else { return }
        if state.isFailed {
            rebuild(reason: reason)
            return
        }
        let device = defaultOutputDevice()
        let next = deviceSignature(device)
        guard device != outputDeviceID || next != signature else { return }
        log.debug(
            "route change (\(reason, privacy: .public)): device \(self.outputDeviceID)->\(device), \(self.signature, privacy: .public) -> \(next, privacy: .public)"
        )
        rebuild(reason: reason)
    }

    private func handleAbnormalStop() {
        guard !order.isEmpty, state == .active else { return }
        log.error("IO stopped abnormally, rebuilding")
        rebuild(reason: "abnormal stop")
    }

    private func handleBufferSizeChange() {
        guard aggregateID != AudioObjectID(kAudioObjectUnknown) else { return }
        renderer.configure(sampleRate: sampleRate, framesPerBuffer: bufferFrames())
    }

    private func deviceSignature(_ device: AudioObjectID) -> DeviceSignature {
        guard device != AudioObjectID(kAudioObjectUnknown) else { return .none }
        return DeviceSignature(
            uid: device.string(propertyAddress(kAudioDevicePropertyDeviceUID)) ?? "",
            channels: device.streamChannelCounts(kAudioObjectPropertyScopeOutput),
            sampleRate: device.value(
                propertyAddress(kAudioDevicePropertyNominalSampleRate), default: Double(0)
            )
        )
    }

    private func defaultOutputDevice() -> AudioObjectID {
        systemObject.value(
            propertyAddress(kAudioHardwarePropertyDefaultOutputDevice),
            default: AudioObjectID(kAudioObjectUnknown)
        )
    }

    private func usableDefaultOutput() -> (id: AudioObjectID, uid: String)? {
        let device = defaultOutputDevice()
        guard device != AudioObjectID(kAudioObjectUnknown), device != aggregateID else { return nil }
        guard let uid = device.string(propertyAddress(kAudioDevicePropertyDeviceUID)),
              !uid.hasPrefix(Self.aggregateUIDPrefix)
        else { return nil }
        return (device, uid)
    }

    private func refreshOutputDeviceName() {
        guard let device = usableDefaultOutput() else {
            outputDeviceName = "-"
            return
        }
        outputDeviceName = device.id.string(propertyAddress(kAudioObjectPropertyName)) ?? "-"
    }

    func diagnostics() -> [String] {
        var lines: [String] = [
            "state=\(state) wantsIO=\(wantsIO) needsGraph=\(needsGraph)",
            "output=\(outputDeviceName) id=\(outputDeviceID)",
            "layout=\(layoutSummary)",
            "taps=\(order.map(\.raw).joined(separator: ","))"
        ]
        for key in order {
            guard let tap = taps[key] else { continue }
            let format = tap.tapID.optionalValue(
                propertyAddress(kAudioTapPropertyFormat), of: AudioStreamBasicDescription.self
            )
            let channels: Int = format.map { Int($0.mChannelsPerFrame) } ?? -1
            let rate: Int = format.map { Int($0.mSampleRate) } ?? -1
            let flags: String = format.map { String($0.mFormatFlags, radix: 2) } ?? "-"
            var line = "tap \(key.raw) id=\(tap.tapID) objects=\(tap.objectIDs.count)"
            line += " mute=\(behaviorName(tap.behavior))/\(liveBehavior(tap.tapID))"
            line += " ch=\(channels) rate=\(rate)"
            line += " float32=\(format?.isFloat32 ?? false) flags=\(flags)"
            lines.append(line)
        }
        guard aggregateID != AudioObjectID(kAudioObjectUnknown) else {
            lines.append("no aggregate")
            return lines
        }
        lines.append("aggregate=\(aggregateID) bufferFrames=\(bufferFrames())")
        lines.append(
            "tapList=\(aggregateID.stringArray(propertyAddress(kAudioAggregateDevicePropertyTapList)))"
        )
        lines.append(
            "subTaps=\(aggregateID.array(propertyAddress(kAudioAggregateDevicePropertySubTapList), of: AudioObjectID.self))"
        )
        lines.append(
            "subDevices=\(aggregateID.array(propertyAddress(kAudioAggregateDevicePropertyActiveSubDeviceList), of: AudioObjectID.self))"
        )
        for (label, scope) in [
            ("input", kAudioObjectPropertyScopeInput), ("output", kAudioObjectPropertyScopeOutput)
        ] {
            lines.append("\(label)Buffers=\(aggregateID.streamChannelCounts(scope))")
            for (index, stream) in aggregateID.streams(scope).enumerated() {
                let format = stream.virtualFormat
                let terminal = stream.value(
                    propertyAddress(kAudioStreamPropertyTerminalType), default: UInt32(0)
                )
                let starting = stream.value(
                    propertyAddress(kAudioStreamPropertyStartingChannel), default: UInt32(0)
                )
                lines.append(
                    "\(label)Stream[\(index)] id=\(stream)"
                        + " ch=\(format.map { Int($0.mChannelsPerFrame) } ?? -1)"
                        + " rate=\(format.map { Int($0.mSampleRate) } ?? -1)"
                        + " float32=\(format?.isFloat32 ?? false)"
                        + " terminal=\(fourCC(terminal)) startingChannel=\(starting)"
                )
            }
        }
        return lines
    }
}
