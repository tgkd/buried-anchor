import AppKit
import CoreAudio
import Foundation

enum CapturePermission: Equatable {
    case granted
    case denied
    case unknown(OSStatus)

    var isGranted: Bool { self == .granted }
}

enum AudioCapturePermission {
    static func probe() -> CapturePermission {
        let description = CATapDescription(stereoMixdownOfProcesses: [])
        description.uuid = UUID()
        description.name = "buried-anchor-permission-probe"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let createStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard createStatus == noErr else { return .unknown(createStatus) }
        defer { AudioHardwareDestroyProcessTap(tapID) }

        var address = propertyAddress(kAudioTapPropertyDescription)
        var object: CATapDescription? = description
        let size = UInt32(MemoryLayout<CATapDescription?>.size)
        let status = withUnsafePointer(to: &object) { pointer in
            AudioObjectSetPropertyData(tapID, &address, 0, nil, size, pointer)
        }

        switch status {
        case noErr:
            return .granted
        case OSStatus(kAudioDevicePermissionsError):
            return .denied
        default:
            return .unknown(status)
        }
    }

    static func openSystemSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        )
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
