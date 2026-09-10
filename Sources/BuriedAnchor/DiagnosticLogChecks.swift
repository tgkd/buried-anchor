import Foundation

enum DiagnosticLogChecks {
    static func run(_ check: (Bool, String) -> Void) {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("buriedanchor-log-test-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        func records(_ url: URL) throws -> [[String: Any]] {
            try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            }
        }
        do {
            let directory = root.appendingPathComponent("append")
            let file = directory.appendingPathComponent("events.jsonl")
            let detail = "line one\nline two: \"звук\""
            do {
                let writer = DiagnosticFileLog(directory: directory)
                writer.record("test.escaped", detail)
                DispatchQueue.concurrentPerform(iterations: 160) { index in
                    writer.record("test.concurrent", "\(index)")
                }
                writer.flush()
            }
            let before = try records(file)
            check(before.count == 161 && before.first?["detail"] as? String == detail,
                  "file journal preserves concurrent events and escaped Unicode on single lines")
            let entries = before.filter { $0["event"] as? String == "test.concurrent" }
            check(Set(entries.compactMap { $0["detail"] as? String }).count == 160,
                  "concurrent journal events are neither lost nor duplicated")
            check(before.allSatisfy { $0["time"] is String && $0["uptime"] is Double && $0["pid"] is Int && $0["session"] is String },
                  "every journal record identifies its time, process and session")
            do {
                let writer = DiagnosticFileLog(directory: directory)
                writer.record("test.restart")
                writer.flush()
            }
            let after = try records(file)
            check(after.count == 162 && after.last?["event"] as? String == "test.restart"
                  && after.first?["session"] as? String != after.last?["session"] as? String,
                  "reopening the journal appends and distinguishes process sessions")

            let rotation = root.appendingPathComponent("rotation")
            do {
                let writer = DiagnosticFileLog(directory: rotation, maxBytes: 900, archives: 2)
                for index in 0..<40 { writer.record("test.rotate", "entry=\(index) " + String(repeating: "x", count: 80)) }
                writer.flush()
            }
            let files = try manager.contentsOfDirectory(at: rotation, includingPropertiesForKeys: [.fileSizeKey])
            let sizes = try files.map { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
            check(Set(files.map(\.lastPathComponent)) == ["events.jsonl", "events.1.jsonl", "events.2.jsonl"]
                  && sizes.allSatisfy { $0 > 0 && $0 <= 900 },
                  "journal rotation bounds archive count and file sizes")
            let latest = try records(rotation.appendingPathComponent("events.jsonl"))
            check(latest.last?["detail"] as? String == "entry=39 " + String(repeating: "x", count: 80),
                  "journal rotation retains the latest complete event")
            for file in files { _ = try records(file) }
            check(true, "all rotated journals contain complete JSON lines")
        } catch {
            check(false, "file journal checks: \(error.localizedDescription)")
        }
    }
}
