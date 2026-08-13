import AppKit
import CoreAudio
import Darwin
import Foundation

struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningOutput: Bool
}

struct AudioAppGroup: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: NSImage?
    let objectIDs: [AudioObjectID]
    let isPlaying: Bool

    static func == (lhs: AudioAppGroup, rhs: AudioAppGroup) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.objectIDs == rhs.objectIDs
            && lhs.isPlaying == rhs.isPlaying
    }
}

@MainActor
final class ProcessRegistry {
    private struct CachedOwner {
        let key: String
        let started: UInt64
    }

    private var ownerCache: [pid_t: CachedOwner] = [:]
    private var appCache: [String: NSRunningApplication] = [:]
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func snapshot() -> [AudioAppGroup] {
        let processes = currentProcesses()
        var members: [String: [AudioProcess]] = [:]
        var display: [String: (name: String, app: NSRunningApplication?)] = [:]

        for process in processes where process.pid != ownPID {
            guard let identity = identify(process) else { continue }
            members[identity.key, default: []].append(process)
            if display[identity.key] == nil {
                display[identity.key] = (identity.name, identity.app)
            }
        }

        let groups = members.map { key, procs in
            AudioAppGroup(
                id: key,
                name: display[key]?.name ?? key,
                icon: display[key]?.app?.icon,
                objectIDs: procs.map(\.objectID).sorted(),
                isPlaying: procs.contains(where: \.isRunningOutput)
            )
        }

        return groups.sorted {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func currentProcesses() -> [AudioProcess] {
        systemObject
            .array(propertyAddress(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)
            .map { objectID in
                AudioProcess(
                    objectID: objectID,
                    pid: objectID.value(propertyAddress(kAudioProcessPropertyPID), default: pid_t(-1)),
                    bundleID: objectID.string(propertyAddress(kAudioProcessPropertyBundleID))
                        .flatMap { $0.isEmpty ? nil : $0 },
                    isRunningOutput: objectID.value(
                        propertyAddress(kAudioProcessPropertyIsRunningOutput), default: UInt32(0)
                    ) != 0
                )
            }
    }

    private func identify(
        _ process: AudioProcess
    ) -> (key: String, name: String, app: NSRunningApplication?)? {
        let started = processInfo(of: process.pid)?.started

        if let cached = ownerCache[process.pid], cached.started == started,
           let app = appCache[cached.key] {
            return (cached.key, app.localizedName ?? cached.key, app)
        }
        ownerCache.removeValue(forKey: process.pid)

        if let app = owningApplication(of: process.pid) {
            let key = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
            if let started {
                ownerCache[process.pid] = CachedOwner(key: key, started: started)
            }
            appCache[key] = app
            return (key, app.localizedName ?? key, app)
        }

        guard process.isRunningOutput else { return nil }

        if let executable = executableName(of: process.pid) {
            return ("exec:\(executable)", executable, nil)
        }
        if let bundleID = process.bundleID {
            return (bundleID, shortName(fromBundleID: bundleID), nil)
        }
        return ("pid:\(process.pid)", "PID \(process.pid)", nil)
    }

    private func owningApplication(of pid: pid_t) -> NSRunningApplication? {
        var candidate: pid_t? = pid
        var depth = 0
        var accessoryFallback: NSRunningApplication?
        while let current = candidate, current > 1, depth < 8 {
            if let app = NSRunningApplication(processIdentifier: current) {
                if app.activationPolicy == .regular { return app }
                if app.activationPolicy == .accessory, accessoryFallback == nil {
                    accessoryFallback = app
                }
            }
            candidate = processInfo(of: current)?.parent
            depth += 1
        }
        return accessoryFallback
    }

    private func processInfo(of pid: pid_t) -> (parent: pid_t?, name: String?, started: UInt64)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        let name = withUnsafePointer(to: &info.kp_proc.p_comm) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                String(validatingCString: $0)
            }
        }
        let birth = info.kp_proc.p_starttime
        let started = UInt64(bitPattern: Int64(birth.tv_sec) &* 1_000_000 &+ Int64(birth.tv_usec))
        return (parent > 0 ? parent : nil, (name?.isEmpty ?? true) ? nil : name, started)
    }

    private func executableName(of pid: pid_t) -> String? {
        processInfo(of: pid)?.name
    }

    private func shortName(fromBundleID bundleID: String) -> String {
        bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    func forgetTerminated() {
        let live = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        appCache = appCache.filter { key, app in live.contains(key) && !app.isTerminated }
        ownerCache = ownerCache.filter { appCache[$0.value.key] != nil }
    }
}
