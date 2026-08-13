import AppKit
import CoreAudio
import Foundation

@MainActor
enum SelfTest {
    static let path = "/tmp/buriedanchor-selftest.log"

    static var isRequested: Bool {
        CommandLine.arguments.contains("--selftest")
            || CommandLine.arguments.contains("--multi")
            || CommandLine.arguments.contains("--watch")
            || CommandLine.arguments.contains("--suspend")
            || CommandLine.arguments.contains("--loginitem")
    }

    static func runSuspend(model: MixerModel) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--suspend") else { return }
        let match = index + 1 < arguments.count ? arguments[index + 1] : ""

        note("=== suspend match=\(match) ===")
        model.start()
        note("permission=\(model.permission) output=\(model.outputDeviceName)")

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard let target = model.rows.filter(\.isPlaying).first(where: {
                match.isEmpty
                    || $0.id.localizedCaseInsensitiveContains(match)
                    || $0.name.localizedCaseInsensitiveContains(match)
            }) else {
                note("FAIL no playing row matching '\(match)'")
                model.shutdown()
                NSApp.terminate(nil)
                return
            }
            note("target=\(target.id)")

            model.setPercent(50, for: target.id)
            let a = await measure(model, id: target.id, seconds: 3, settle: 1.2)
            note("A 50%: peak=\(fmt(a)) controlled=\(isControlled(model, target.id))")

            model.setPercent(100, for: target.id)
            let b = await measure(model, id: target.id, seconds: 3, settle: 2.5)
            note("B 100%: peak=\(fmt(b)) controlled=\(isControlled(model, target.id))")

            model.setPercent(50, for: target.id)
            let c = await measure(model, id: target.id, seconds: 3, settle: 1.2)
            note("C 50% again: peak=\(fmt(c)) controlled=\(isControlled(model, target.id))")

            note(b < a * 0.2 ? "PASS suspended at 100%" : "FAIL still rendering at 100%: \(fmt(b))")
            note(c > a * 0.7 ? "PASS resumed at 50%" : "FAIL did not resume: A=\(fmt(a)) C=\(fmt(c))")
            note(isControlled(model, target.id) ? "PASS tap kept across the cycle" : "FAIL tap was released")
            note("done")
            model.shutdown()
            NSApp.terminate(nil)
        }
    }

    private static func isControlled(_ model: MixerModel, _ id: String) -> Bool {
        model.rows.first { $0.id == id }?.isControlled ?? false
    }

    static func runLoginItem() {
        note("=== login item ===")
        note("bundle=\(Bundle.main.bundlePath)")
        note("status=\(LoginItem.statusName)")

        let wasEnabled = LoginItem.isEnabled
        do {
            try LoginItem.setEnabled(true)
            note("after register: status=\(LoginItem.statusName) isEnabled=\(LoginItem.isEnabled)")
        } catch {
            note("FAIL register: \(error.localizedDescription)")
        }
        if !wasEnabled {
            do {
                try LoginItem.setEnabled(false)
                note("after unregister: status=\(LoginItem.statusName)")
            } catch {
                note("FAIL unregister: \(error.localizedDescription)")
            }
        } else {
            note("left registered, it was already enabled before this run")
        }
        note("done")
        NSApp.terminate(nil)
    }

    static func runWatch(model: MixerModel) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--watch") else { return }
        let seconds = index + 1 < arguments.count ? Double(arguments[index + 1]) ?? 30 : 30

        note("=== watch \(seconds)s ===")
        model.start()

        Task { @MainActor in
            let started = Date()
            while Date().timeIntervalSince(started) < seconds {
                let elapsed = Int(Date().timeIntervalSince(started))
                let listing = model.rows
                    .map { "\($0.name)\($0.isPlaying ? "*" : "")@\(Int($0.percent))\($0.isControlled ? "!" : "")" }
                    .joined(separator: ", ")
                note("t=\(elapsed)s rows=[\(listing)]")
                try? await Task.sleep(for: .seconds(3))
            }
            note("done")
            model.shutdown()
            NSApp.terminate(nil)
        }
    }

    static func runMulti(model: MixerModel) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--multi"), index + 4 < arguments.count else {
            note("FAIL usage: --multi <matchA> <pctA> <matchB> <pctB>")
            NSApp.terminate(nil)
            return
        }
        let matchA = arguments[index + 1]
        let pctA = Double(arguments[index + 2]) ?? 50
        let matchB = arguments[index + 3]
        let pctB = Double(arguments[index + 4]) ?? 150

        note("=== multi A=\(matchA)@\(pctA)% B=\(matchB)@\(pctB)% ===")
        model.start()
        note("permission=\(model.permission) output=\(model.outputDeviceName)")

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            let playing = model.rows.filter(\.isPlaying)
            for row in playing { note("playing: \(row.name) [\(row.id)]") }

            guard let a = playing.first(where: {
                $0.id.localizedCaseInsensitiveContains(matchA)
                    || $0.name.localizedCaseInsensitiveContains(matchA)
            }) else {
                note("FAIL no playing row matching '\(matchA)'")
                model.shutdown()
                NSApp.terminate(nil)
                return
            }
            guard let b = playing.first(where: {
                $0.id != a.id
                    && ($0.id.localizedCaseInsensitiveContains(matchB)
                        || $0.name.localizedCaseInsensitiveContains(matchB))
            }) else {
                note("FAIL no second playing row matching '\(matchB)' distinct from \(a.id)")
                model.shutdown()
                NSApp.terminate(nil)
                return
            }
            note("A=\(a.id) B=\(b.id)")

            model.setPercent(pctA, for: a.id)
            try? await Task.sleep(for: .milliseconds(500))
            note("after A: controlled=\(controlledCount(model)) error=\(model.engineError ?? "none")")

            model.setPercent(pctB, for: b.id)
            try? await Task.sleep(for: .milliseconds(500))
            note("after B: controlled=\(controlledCount(model)) error=\(model.engineError ?? "none")")

            let first = await measurePair(model, a.id, b.id, seconds: 3, settle: 1.2)
            note("PASS1 A(\(Int(pctA))%)=\(fmt(first.0))  B(\(Int(pctB))%)=\(fmt(first.1))")

            model.setPercent(pctB, for: a.id)
            model.setPercent(pctA, for: b.id)
            let second = await measurePair(model, a.id, b.id, seconds: 3, settle: 1.2)
            note("PASS2 A(\(Int(pctB))%)=\(fmt(second.0))  B(\(Int(pctA))%)=\(fmt(second.1))")

            model.setPercent(0, for: a.id)
            let third = await measurePair(model, a.id, b.id, seconds: 2, settle: 2.5)
            note("PASS3 A(0%)=\(fmt(third.0))  B(\(Int(pctA))%)=\(fmt(third.1))")

            note("clipping=\(model.clipping)")
            note("done")
            model.shutdown()
            NSApp.terminate(nil)
        }
    }

    private static func controlledCount(_ model: MixerModel) -> Int {
        model.rows.filter(\.isControlled).count
    }

    private static func measurePair(
        _ model: MixerModel, _ idA: String, _ idB: String, seconds: Double, settle: Double
    ) async -> (Float, Float) {
        try? await Task.sleep(for: .milliseconds(Int(settle * 1000)))
        var peakA: Float = 0
        var peakB: Float = 0
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            if let row = model.rows.first(where: { $0.id == idA }) { peakA = max(peakA, row.level) }
            if let row = model.rows.first(where: { $0.id == idB }) { peakB = max(peakB, row.level) }
        }
        return (peakA, peakB)
    }

    static func note(_ message: String) {
        log.info("\(message, privacy: .public)")
        let line = message + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    static func run(model: MixerModel) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--selftest") else { return }
        let match = index + 1 < arguments.count ? arguments[index + 1] : ""
        let percent = index + 2 < arguments.count ? Double(arguments[index + 2]) ?? 150 : 150
        let switchDevice = arguments.contains("--switch")

        note("=== selftest match=\(match) percent=\(percent) switch=\(switchDevice) ===")
        model.start()
        note("permission=\(model.permission)")
        note("output=\(model.outputDeviceName)")

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            for row in model.rows {
                note("playing: \(row.name) [\(row.id)] objects=\(row.objectIDs.count)")
            }
            guard let target = model.rows.first(where: {
                $0.id.localizedCaseInsensitiveContains(match)
                    || $0.name.localizedCaseInsensitiveContains(match)
            }) else {
                note("FAIL no row matching '\(match)'")
                NSApp.terminate(nil)
                return
            }

            model.setPercent(percent, for: target.id)
            try? await Task.sleep(for: .milliseconds(400))
            note("controlled=\(model.rows.first { $0.id == target.id }?.isControlled ?? false) error=\(model.engineError ?? "none")")
            let boosted = await measure(model, id: target.id, seconds: 3)
            note("A boost \(Int(percent))%: peak=\(fmt(boosted))")

            model.setPercent(0, for: target.id)
            let muted = await measure(model, id: target.id, seconds: 2, settle: 2.5)
            note("B mute 0%: peak=\(fmt(muted))")

            model.setPercent(percent, for: target.id)
            try? await Task.sleep(for: .milliseconds(500))

            if switchDevice {
                let original = defaultOutput()
                let originalName = original.string(propertyAddress(kAudioObjectPropertyName)) ?? "?"
                if let other = outputDevices().first(where: { $0.0 != original }) {
                    note("C switching \(originalName) -> \(other.1)")
                    let status = setDefaultOutput(other.0)
                    note("C set status=\(statusName(status))")
                    try? await Task.sleep(for: .milliseconds(1500))
                    let after = await measure(model, id: target.id, seconds: 3)
                    note("C after switch: output=\(model.outputDeviceName) peak=\(fmt(after)) error=\(model.engineError ?? "none")")
                    let restore = setDefaultOutput(original)
                    note("C restored \(originalName) status=\(statusName(restore))")
                    try? await Task.sleep(for: .milliseconds(1500))
                    let back = await measure(model, id: target.id, seconds: 2)
                    note("D after restore: output=\(model.outputDeviceName) peak=\(fmt(back))")
                } else {
                    note("C skipped, only one output device")
                }
            }

            note("clipping=\(model.clipping)")
            note("done")
            model.shutdown()
            NSApp.terminate(nil)
        }
    }

    private static func fmt(_ value: Float) -> String {
        String(format: "%.4f", value)
    }

    private static func measure(
        _ model: MixerModel, id: String, seconds: Double, settle: Double = 0.8
    ) async -> Float {
        try? await Task.sleep(for: .milliseconds(Int(settle * 1000)))
        var peak: Float = 0
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            if let row = model.rows.first(where: { $0.id == id }) {
                peak = max(peak, row.level)
            }
        }
        return peak
    }

    private static func defaultOutput() -> AudioObjectID {
        systemObject.value(
            propertyAddress(kAudioHardwarePropertyDefaultOutputDevice),
            default: AudioObjectID(kAudioObjectUnknown)
        )
    }

    private static func outputDevices() -> [(AudioObjectID, String)] {
        systemObject
            .array(propertyAddress(kAudioHardwarePropertyDevices), of: AudioObjectID.self)
            .filter { !$0.streamChannelCounts(kAudioObjectPropertyScopeOutput).isEmpty }
            .filter {
                let uid = $0.string(propertyAddress(kAudioDevicePropertyDeviceUID)) ?? ""
                return !uid.hasPrefix("com.buriedanchor.aggregate.")
            }
            .map { ($0, $0.string(propertyAddress(kAudioObjectPropertyName)) ?? "?") }
    }

    private static func setDefaultOutput(_ deviceID: AudioObjectID) -> OSStatus {
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var value = deviceID
        return AudioObjectSetPropertyData(
            systemObject, &address, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &value
        )
    }
}
