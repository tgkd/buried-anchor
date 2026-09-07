import Darwin
import Foundation

enum SourceID: Hashable, Sendable {
    case bundle(String)
    case executable(String)
    case ephemeral(pid_t)

    init(raw: String) {
        if raw.hasPrefix("exec:") {
            self = .executable(String(raw.dropFirst("exec:".count)))
        } else if raw.hasPrefix("pid:"), let pid = pid_t(raw.dropFirst("pid:".count)) {
            self = .ephemeral(pid)
        } else {
            self = .bundle(raw)
        }
    }

    var raw: String {
        switch self {
        case .bundle(let identifier): identifier
        case .executable(let name): "exec:\(name)"
        case .ephemeral(let pid): "pid:\(pid)"
        }
    }

    var isDurable: Bool {
        switch self {
        case .bundle, .executable: true
        case .ephemeral: false
        }
    }

    var fallbackName: String {
        switch self {
        case .bundle(let identifier):
            identifier.split(separator: ".").last.map(String.init) ?? identifier
        case .executable(let name): URL(fileURLWithPath: name).lastPathComponent
        case .ephemeral(let pid): "PID \(pid)"
        }
    }

    func matches(_ needle: String) -> Bool {
        needle.isEmpty || raw.localizedCaseInsensitiveContains(needle)
    }
}

extension SourceID: CustomStringConvertible {
    var description: String { raw }
}
