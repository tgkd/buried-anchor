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
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MixerModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--watch") {
            SelfTest.runWatch(model: model)
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
    }
}

struct MixerPanel: View {
    @Bindable var model: MixerModel
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
                    VStack(spacing: 6) {
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
        HStack {
            Toggle("Soft clip", isOn: $model.softClip)
                .toggleStyle(.checkbox)
                .font(.caption)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .font(.caption)
        }
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

    var body: some View {
        HStack(spacing: 8) {
            icon
            HStack(spacing: 6) {
                Text(row.name)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(row.isPlaying ? .primary : .secondary)
                WaveformIndicator(
                    isPlaying: row.isPlaying,
                    level: row.level,
                    isMeasured: row.isControlled
                )
                Spacer(minLength: 0)
            }
            .frame(width: 130, alignment: .leading)

            Slider(value: percentBinding, in: 0...150)

            Text("\(Int(row.percent))%")
                .font(.caption.monospacedDigit())
                .frame(width: 38, alignment: .trailing)
                .foregroundStyle(row.percent > 100 ? .orange : .primary)

            Button {
                model.reset(row.id)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .opacity(row.isControlled ? 1 : 0.25)
            .disabled(!row.isControlled)
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
        .frame(width: 20, height: 20)
    }
}

struct WaveformIndicator: View {
    let isPlaying: Bool
    let level: Float
    let isMeasured: Bool

    private let barCount = 5
    private let barWidth: CGFloat = 2
    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !isPlaying)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(isPlaying ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: barWidth, height: height(index: index, time: time))
                }
            }
        }
        .frame(width: CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * 2, height: maxHeight)
        .animation(.easeOut(duration: 0.12), value: isPlaying)
    }

    private func height(index: Int, time: TimeInterval) -> CGFloat {
        guard isPlaying else { return minHeight }
        let amplitude = isMeasured
            ? CGFloat(min(max(level * 1.6, 0.12), 1))
            : 0.6
        let phase = time * 7 + Double(index) * 0.85
        let wave = (sin(phase) + 1) / 2
        let shaped = 0.3 + 0.7 * wave
        return minHeight + (maxHeight - minHeight) * amplitude * shaped
    }
}
