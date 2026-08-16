import CoreAudio
import Foundation
import os

let log = Logger(subsystem: "com.buriedanchor.mixer", category: "engine")

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

extension AudioObjectID {
    func dataSize(_ address: AudioObjectPropertyAddress) -> UInt32? {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr else { return nil }
        return size
    }

    func array<T>(_ address: AudioObjectPropertyAddress, of type: T.Type) -> [T] {
        guard let size = dataSize(address), size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        var address = address
        var size2 = size
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size2, buffer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size2) / MemoryLayout<T>.stride))
    }

    func optionalValue<T>(_ address: AudioObjectPropertyAddress, of type: T.Type) -> T? {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer) == noErr else { return nil }
        return buffer.pointee
    }

    func value<T>(_ address: AudioObjectPropertyAddress, default fallback: T) -> T {
        optionalValue(address, of: T.self) ?? fallback
    }

    func string(_ address: AudioObjectPropertyAddress) -> String? {
        var address = address
        var size = UInt32(MemoryLayout<CFString?>.size)
        var raw: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &raw) { pointer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let raw else { return nil }
        return raw.takeRetainedValue() as String
    }

    func stringArray(_ address: AudioObjectPropertyAddress) -> [String] {
        var address = address
        var size = UInt32(MemoryLayout<CFArray?>.size)
        var raw: Unmanaged<CFArray>?
        let status = withUnsafeMutablePointer(to: &raw) { pointer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let raw else { return [] }
        return (raw.takeRetainedValue() as NSArray).compactMap { $0 as? String }
    }

    func streamChannelCounts(_ scope: AudioObjectPropertyScope) -> [Int] {
        let address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope)
        guard let size = dataSize(address), size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        var address2 = address
        var size2 = size
        guard AudioObjectGetPropertyData(self, &address2, 0, nil, &size2, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    func streams(_ scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        array(propertyAddress(kAudioDevicePropertyStreams, scope), of: AudioObjectID.self)
    }

    var virtualFormat: AudioStreamBasicDescription? {
        optionalValue(
            propertyAddress(kAudioStreamPropertyVirtualFormat), of: AudioStreamBasicDescription.self
        )
    }
}

extension AudioStreamBasicDescription {
    var isFloat32: Bool {
        mFormatID == kAudioFormatLinearPCM
            && mFormatFlags & kAudioFormatFlagIsFloat != 0
            && mBitsPerChannel == 32
    }
}

let halNotifyQueue = DispatchQueue(label: "com.buriedanchor.halnotify")

final class PropertyListener {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private var installed = false

    init?(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        queue: DispatchQueue = halNotifyQueue,
        handler: @escaping @Sendable () -> Void
    ) {
        self.objectID = objectID
        self.address = address
        self.queue = queue
        self.block = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(objectID, &self.address, queue, block)
        guard status == noErr else {
            log.error("listener install failed for \(fourCC(address.mSelector), privacy: .public): \(status)")
            return nil
        }
        installed = true
    }

    deinit {
        guard installed else { return }
        AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
    }
}

func fourCC(_ value: UInt32) -> String {
    let bytes = [
        UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)
    ]
    return String(bytes: bytes, encoding: .ascii) ?? String(value)
}

func statusName(_ status: OSStatus) -> String {
    status == noErr ? "noErr" : "\(fourCC(UInt32(bitPattern: status)))(\(status))"
}
