import AppKit
import Foundation

enum DiagnosticLog {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/BuriedAnchor", isDirectory: true)
    // Synthetic tests use their own temporary writer, never the live journal.
    private static let writer = CommandLine.arguments.contains("--render")
        ? nil : DiagnosticFileLog(directory: directory)

    static func record(_ event: String, _ detail: String = "") {
        writer?.record(event, detail)
    }

    static func flush() { writer?.flush() }

    static var journalURL: URL { directory.appendingPathComponent("events.jsonl") }

    static func bytesOnDisk() -> UInt64 {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return 0 }
        return names.filter { $0.hasPrefix("events") && $0.hasSuffix(".jsonl") }.reduce(0) { total, name in
            let size = (try? manager.attributesOfItem(atPath: directory.appendingPathComponent(name).path))?[.size] as? UInt64
            return total + (size ?? 0)
        }
    }

    static func revealInFinder() {
        flush()
        let manager = FileManager.default
        if manager.fileExists(atPath: journalURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([journalURL])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        }
    }
}

/// File I/O is confined to a separate queue. Never call from the audio callback.
final class DiagnosticFileLog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.buriedanchor.diagnostics", qos: .utility)
    private let gate = NSLock()
    private var pending = 0
    private var dropped = 0
    private let directory: URL
    private let maxBytes: UInt64
    private let archives: Int
    private let session = UUID().uuidString
    private let pid = ProcessInfo.processInfo.processIdentifier
    private let formatter = ISO8601DateFormatter()
    private var handle: FileHandle?
    private var bytes: UInt64 = 0
    private var reportedFailure = false

    init(directory: URL, maxBytes: UInt64 = 2 * 1024 * 1024, archives: Int = 4) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.archives = max(0, archives)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    deinit { try? handle?.close() }

    func record(_ event: String, _ detail: String = "") {
        gate.lock()
        guard pending < 512 else {
            dropped += 1
            gate.unlock()
            return
        }
        pending += 1
        let skipped = dropped
        dropped = 0
        let date = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let event = String(event.prefix(128))
        let detail = String(detail.prefix(16_384))
        queue.async { [self] in
            if skipped > 0 { write("log.dropped", "events=\(skipped)", date: date, uptime: uptime) }
            write(event, detail, date: date, uptime: uptime)
            gate.lock()
            pending -= 1
            gate.unlock()
        }
        gate.unlock()
    }

    func flush() {
        queue.sync {
            gate.lock()
            let skipped = dropped
            dropped = 0
            gate.unlock()
            if skipped > 0 {
                write("log.dropped", "events=\(skipped)", date: Date(), uptime: ProcessInfo.processInfo.systemUptime)
            }
            do { try handle?.synchronize() }
            catch { report(error) }
        }
    }

    private func file(_ archive: Int = 0) -> URL {
        directory.appendingPathComponent(archive == 0 ? "events.jsonl" : "events.\(archive).jsonl")
    }

    private func open() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        if !manager.fileExists(atPath: file().path) {
            guard manager.createFile(atPath: file().path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let opened = try FileHandle(forWritingTo: file())
        do { bytes = try opened.seekToEnd() }
        catch { try? opened.close(); throw error }
        handle = opened
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        let manager = FileManager.default
        if manager.fileExists(atPath: file(archives).path) { try manager.removeItem(at: file(archives)) }
        if archives > 0 {
            for index in stride(from: archives - 1, through: 0, by: -1) where manager.fileExists(atPath: file(index).path) {
                try manager.moveItem(at: file(index), to: file(index + 1))
            }
        }
        try open()
    }

    private func write(_ event: String, _ detail: String, date: Date, uptime: TimeInterval) {
        do {
            var data = try JSONSerialization.data(withJSONObject: [
                "time": formatter.string(from: date), "uptime": uptime,
                "pid": pid, "session": session, "event": event, "detail": detail
            ], options: [.sortedKeys, .withoutEscapingSlashes])
            data.append(0x0A)
            if handle == nil { try open() }
            if bytes > 0, bytes + UInt64(data.count) > maxBytes { try rotate() }
            try handle?.write(contentsOf: data)
            bytes += UInt64(data.count)
            reportedFailure = false
        } catch {
            try? handle?.close()
            handle = nil
            report(error)
        }
    }

    private func report(_ error: Error) {
        if !reportedFailure {
            log.error("diagnostic file log failed: \(error.localizedDescription, privacy: .public)")
            reportedFailure = true
        }
    }
}
