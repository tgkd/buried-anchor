import ServiceManagement
import SwiftUI

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static var statusName: String {
        switch SMAppService.mainApp.status {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown"
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

struct SettingsView: View {
    let model: MixerModel

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        )
    }

    private var softClipBinding: Binding<Bool> {
        Binding(
            get: { model.softClip },
            set: { model.softClip = $0 }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: launchBinding)
                if let notice = model.loginItemNotice {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Open") { LoginItem.openSystemSettings() }
                            .font(.caption)
                    }
                }
            } header: {
                Text("Startup")
            }

            Section {
                Toggle("Soft clip", isOn: softClipBinding)
                Text(
                    "Above 100% the mix can exceed full scale. Off, peaks are clipped flat at ±1.0; "
                        + "on, they are rounded off with tanh saturation."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Output")
            }

            Section {
                LabeledContent("Version", value: Self.version)
                LabeledContent("System audio", value: model.permission.isGranted ? "Allowed" : "Not allowed")
                if !model.permission.isGranted {
                    HStack {
                        Spacer(minLength: 0)
                        Button("Open Privacy Settings") { AudioCapturePermission.openSystemSettings() }
                            .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refreshSettingsState() }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
