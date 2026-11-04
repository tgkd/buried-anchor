import AppKit
import SwiftUI

@main
struct BuriedAnchorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Buried Anchor", systemImage: "slider.horizontal.below.square.filled.and.square") {
            MixerPanel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MixerModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let info = Bundle.main.infoDictionary ?? [:]
        DiagnosticLog.record("app.start", "path=\(Bundle.main.bundlePath) version=\(info["CFBundleShortVersionString"] ?? "?") build=\(info["CFBundleVersion"] ?? "?") revision=\(info["BuriedAnchorRevision"] ?? "unknown") built=\(info["BuriedAnchorBuildDate"] ?? "unknown") os=\(ProcessInfo.processInfo.operatingSystemVersionString) loginItem=\(LoginItem.statusName) selfTest=\(SelfTest.isRequested)")
        if CommandLine.arguments.contains("--render") {
            SelfTest.runRender()
            return
        }
        if CommandLine.arguments.contains("--layout") {
            SelfTest.runLayout(model: model)
            return
        }
        if CommandLine.arguments.contains("--loginitem") {
            SelfTest.runLoginItem()
            return
        }
        if CommandLine.arguments.contains("--watch") {
            SelfTest.runWatch(model: model)
            return
        }
        if CommandLine.arguments.contains("--suspend") {
            SelfTest.runSuspend(model: model)
            return
        }
        if CommandLine.arguments.contains("--capture") {
            SelfTest.runCapture(model: model)
            return
        }
        if CommandLine.arguments.contains("--multi") {
            SelfTest.runMulti(model: model)
            return
        }
        if SelfTest.isRequested {
            SelfTest.run(model: model)
            return
        }
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
        DiagnosticLog.record("app.stop")
        DiagnosticLog.flush()
    }
}

struct MixerPanel: View {
    let model: MixerModel
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if !model.permission.isGranted {
                permissionNotice
            }

            if let error = model.engineError {
                engineNotice(error)
            }

            if model.rows.isEmpty {
                Text("No apps are playing audio.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.rows) { row in
                            AppRow(row: row, model: model)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        rowsHeight = height
                    }
                }
                .frame(height: min(max(rowsHeight, 32), 320))
                .scrollBounceBehavior(.basedOnSize)
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 380)
        .background(WindowVisibilityReader { model.setPanelVisible($0) })
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Output")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(model.outputDeviceName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Spacer()
            if model.clipping {
                Label("clipping", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var permissionNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text("System audio recording is off").font(.callout.weight(.medium))
                Text("Volume changes will do nothing until it is allowed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") { AudioCapturePermission.openSystemSettings() }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func engineNotice(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Volume changes are not taking effect").font(.callout.weight(.medium))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            SettingsLink {
                FooterIcon(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .simultaneousGesture(TapGesture().onEnded { NSApp.activate() })

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                FooterIcon(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit Buried Anchor")
        }
    }
}

struct FooterIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
    }
}

struct AppRow: View {
    let row: MixerModel.Row
    let model: MixerModel

    private var percentBinding: Binding<Double> {
        Binding(
            get: { row.percent },
            set: { model.setPercent($0, for: row.id) }
        )
    }

    private var isMuted: Bool { row.percent == 0 }

    private let iconSize: CGFloat = 20
    private let rowHeight: CGFloat = 28

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            icon
            HStack(alignment: .center, spacing: 6) {
                Text(row.name)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(row.isPlaying ? .primary : .secondary)
                if row.controlState.needsAttention {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .help(row.controlState.notice ?? "Volume has not been applied")
                        .accessibilityLabel(row.controlState.notice ?? "Volume has not been applied")
                }
                PlayingIndicator(isPlaying: row.isPlaying)
                Spacer(minLength: 0)
            }
            .frame(width: 130, height: rowHeight, alignment: .leading)

            Button {
                model.toggleMute(row.id)
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 16, height: rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(isMuted ? Color.orange : Color.secondary)
            .help(isMuted ? "Unmute" : "Mute")
            .accessibilityLabel("\(isMuted ? "Unmute" : "Mute") \(row.name)")

            Slider(value: percentBinding, in: 0...150)
                .accessibilityLabel("\(row.name) volume")
                .accessibilityValue("\(Int(row.percent)) percent requested")
                .frame(height: rowHeight)
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded { model.setPercent(100, for: row.id) }
                )
                .help("Double-click to snap back to 100%")

            Text("\(Int(row.percent))%")
                .font(.caption.monospacedDigit())
                .frame(width: 38, height: rowHeight, alignment: .trailing)
                .foregroundStyle(row.percent > 100 ? .orange : .primary)

            Button {
                model.reset(row.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 14, height: rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Reset to 100% and remove from the list")
            .accessibilityLabel("Remove \(row.name)")
            .opacity(row.isPlaying ? 0 : 1)
            .disabled(row.isPlaying)
            .accessibilityHidden(row.isPlaying)
        }
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .contextMenu {
            Button(isMuted ? "Unmute" : "Mute") { model.toggleMute(row.id) }
            Divider()
            Button("Reset to 100% and stop controlling") { model.reset(row.id) }
                .disabled(!row.isControlled && model.savedPercent(for: row.id) == nil)
        }
    }

    private var icon: some View {
        Group {
            if let image = row.icon {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: iconSize, height: iconSize)
        .frame(height: rowHeight)
    }
}

struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> WindowVisibilityView {
        let view = WindowVisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: WindowVisibilityView, context: Context) {
        nsView.onChange = onChange
    }
}

final class WindowVisibilityView: NSView {
    var onChange: (@MainActor (Bool) -> Void)?
    private var observer: NSObjectProtocol?
    private var lastReported: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        if let window {
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
        }
        report()
    }

    private func report() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        guard visible != lastReported else {
            return
        }
        lastReported = visible
        onChange?(visible)
    }
}

struct PlayingIndicator: View {
    let isPlaying: Bool

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary.opacity(0.35))
            .frame(width: 18, height: 14)
            .help(isPlaying ? "Playing now" : "Not playing")
            .accessibilityLabel(isPlaying ? "Playing now" : "Not playing")
    }
}
