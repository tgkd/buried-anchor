import AppKit
import CoreAudio
import Foundation

@MainActor
enum SelfTest {
    static let path = "/tmp/buriedanchor-selftest.log"

    private static let modes = [
        "--selftest", "--multi", "--watch", "--suspend", "--loginitem", "--layout", "--render",
        "--capture"
    ]

    private static var failures = 0

    static var isRequested: Bool {
        CommandLine.arguments.contains { modes.contains($0) }
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
            guard let target = playing(model, matching: match) else {
                fail("no playing row matching '\(match)'")
                finish(model)
                return
            }
            note("target=\(target.id.raw)")
            let saved = model.savedPercent(for: target.id)

            model.setPercent(50, for: target.id)
            let a = await measure(model, id: target.id, seconds: 3, settle: 1.2)
            note("A 50%: peak=\(fmt(a)) controlled=\(isControlled(model, target.id))")

            model.setPercent(100, for: target.id)
            let b = await measure(model, id: target.id, seconds: 3, settle: 2.5)
            note("B 100%: peak=\(fmt(b)) controlled=\(isControlled(model, target.id))")
            expect(!isControlled(model, target.id), "unity releases capture", "unity still captured")

            model.setPercent(50, for: target.id)
            let c = await measure(model, id: target.id, seconds: 3, settle: 1.2)
            note("C 50% again: peak=\(fmt(c)) controlled=\(isControlled(model, target.id))")

            expect(b < a * 0.2, "suspended at 100%", "still rendering at 100%: \(fmt(b))")
            expect(c > a * 0.7, "resumed at 50%", "did not resume: A=\(fmt(a)) C=\(fmt(c))")
            expect(isControlled(model, target.id), "capture restored after unity bypass", "capture was not restored")

            restore(model, target.id, saved)
            finish(model)
        }
    }

    static func runCapture(model: MixerModel) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--capture") else { return }
        let match = index + 1 < arguments.count ? arguments[index + 1] : ""

        note("=== capture match=\(match) ===")
        model.start()
        note("permission=\(model.permission) output=\(model.outputDeviceName)")

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard let target = playing(model, matching: match) else {
                fail("no playing row matching '\(match)'")
                finish(model)
                return
            }
            note("target=\(target.id.raw)")
            let saved = model.savedPercent(for: target.id)

            model.setPercent(150, for: target.id)
            try? await Task.sleep(for: .milliseconds(1500))
            let level = await measure(model, id: target.id, seconds: 2, settle: 0.3)
            note("A 150%: holdsOutput=\(holdsOutput()) deviceRunning=\(deviceRunning()) peak=\(fmt(level))")
            expect(holdsOutput(), "the graph holds the output device while rendering", "not rendering at 150%")
            expect(level > 0, "the target renders at 150%", "no level at 150%")

            model.setPercent(0, for: target.id)
            try? await Task.sleep(for: .milliseconds(3500))
            note("B 0%: holdsOutput=\(holdsOutput()) deviceRunning=\(deviceRunning()) controlled=\(isControlled(model, target.id))")
            expect(!holdsOutput(), "a muted row lets go of the output device", "still holding the device at 0%")
            expect(isControlled(model, target.id), "the tap is kept while muted", "the tap was released at 0%")

            model.setPercent(150, for: target.id)
            try? await Task.sleep(for: .milliseconds(1500))
            let resumed = await measure(model, id: target.id, seconds: 2, settle: 0.3)
            note("C 150% again: holdsOutput=\(holdsOutput()) peak=\(fmt(resumed))")
            expect(holdsOutput(), "the device is taken back when rendering resumes", "did not take the device back")
            expect(resumed > 0, "rendering again after the muted gap", "no level after the muted gap")

            model.setPercent(100, for: target.id)
            try? await Task.sleep(for: .milliseconds(3500))
            note("D 100%: holdsOutput=\(holdsOutput()) deviceRunning=\(deviceRunning())")
            expect(!holdsOutput(), "a unity row lets go of the output device", "still holding the device at 100%")

            for line in model.engineDiagnostics() { note(line) }
            restore(model, target.id, saved)
            finish(model)
        }
    }

    static func runLayout(model: MixerModel) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--layout") else { return }
        let match = index + 1 < arguments.count ? arguments[index + 1] : ""

        note("=== layout match=\(match) ===")
        model.start()
        note("permission=\(model.permission) output=\(model.outputDeviceName)")

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard let target = playing(model, matching: match) else {
                fail("no playing row matching '\(match)'")
                finish(model)
                return
            }
            note("target=\(target.id.raw)")
            let saved = model.savedPercent(for: target.id)

            model.setPercent(99, for: target.id)
            try? await Task.sleep(for: .milliseconds(900))
            for line in model.engineDiagnostics() { note(line) }

            let active = model.rows.first { $0.id == target.id }?.isActive ?? false
            expect(active, "graph is active", "graph is not active: \(model.engineError ?? "no error")")

            let level = await measure(model, id: target.id, seconds: 2, settle: 0.5)
            expect(level > 0, "metering the target at \(fmt(level))", "no level measured")

            restore(model, target.id, saved)
            finish(model)
        }
    }

    static func runRender() {
        note("=== render ===")
        checkLayoutResolution()
        checkRendering()
        CoordinatorChecks.run { condition, name in expect(condition, name, name) }
        finish(nil)
    }

    private static func checkLayoutResolution() {
        let a = tap("a")
        let b = tap("b")

        switch GraphLayout.resolve(
            taps: [a, b], input: layout([2, 2]), output: layout([2])
        ) {
        case .failure(let fault):
            fail("interleaved stereo rejected: \(fault)")
        case .success(let layout):
            expect(layout.inputOffset == 0, "stereo pair maps at offset 0", "offset=\(layout.inputOffset)")
            expect(
                layout.slots.map(\.inputBuffer) == [0, 1],
                "slots read buffers 0,1",
                "slots read \(layout.slots.map(\.inputBuffer))"
            )
            expect(
                layout.outputChannels == [
                    .init(buffer: 0, offset: 0, stride: 2), .init(buffer: 0, offset: 1, stride: 2)
                ],
                "interleaved output map",
                "output map \(layout.outputChannels)"
            )
        }

        switch GraphLayout.resolve(
            taps: [a, b], input: layout([1, 2, 2]), output: layout([2]), inputPrefix: [1]
        ) {
        case .failure(let fault):
            fail("duplex input rejected: \(fault)")
        case .success(let layout):
            expect(
                layout.inputOffset == 1 && layout.slots.map(\.inputBuffer) == [1, 2],
                "duplex input skips the device's own input stream",
                "offset=\(layout.inputOffset) buffers=\(layout.slots.map(\.inputBuffer))"
            )
        }

        switch GraphLayout.resolve(taps: [a], input: layout([2]), output: layout([1, 1])) {
        case .failure(let fault):
            fail("non-interleaved output rejected: \(fault)")
        case .success(let layout):
            expect(
                layout.outputChannels == [
                    .init(buffer: 0, offset: 0, stride: 1), .init(buffer: 1, offset: 0, stride: 1)
                ],
                "non-interleaved output map",
                "output map \(layout.outputChannels)"
            )
        }

        switch GraphLayout.resolve(taps: [a], input: layout([2]), output: layout([8])) {
        case .failure(let fault):
            fail("multichannel output rejected: \(fault)")
        case .success(let layout):
            expect(
                layout.outputChannels.count == 8 && layout.slots[0].targets == [0, 1],
                "multichannel output keeps the tap on channels 0,1",
                "channels=\(layout.outputChannels.count) targets=\(layout.slots[0].targets)"
            )
        }

        switch GraphLayout.resolve(taps: [a], input: layout([2]), output: layout([1])) {
        case .failure(let fault):
            fail("mono output rejected: \(fault)")
        case .success(let layout):
            expect(
                layout.slots[0].targets == [0, 0],
                "mono output folds both tap channels",
                "targets=\(layout.slots[0].targets)"
            )
        }

        expectFault(
            GraphLayout.resolve(
                taps: [a], input: layout([2]),
                output: BufferLayout(bufferChannels: [2], isFloat32: false, sampleRate: 48000)
            ),
            .outputNotFloat32
        )
        expectFault(
            GraphLayout.resolve(taps: [a, b], input: layout([2]), output: layout([2])),
            .tapStreamsNotFound(input: [2], taps: [2, 2])
        )
        let resampled = GraphLayout.resolve(
            taps: [a, TapFormat(key: .bundle("b"), channels: 2, sampleRate: 44100, isFloat32: true)],
            input: layout([2, 2]), output: layout([2])
        )
        if case .success = resampled { expect(true, "HAL-converted taps use aggregate rate", "") }
        else { fail("valid aggregate conversion rejected") }
        expectFault(GraphLayout.resolve(taps: [a], input: layout([2]),
            output: BufferLayout(bufferChannels: [2], isFloat32: true, sampleRate: 44100)),
            .aggregateSampleRateMismatch(input: 48000, output: 44100))
        expectFault(GraphLayout.resolve(taps: [a], input: layout([2, 2]), output: layout([2])),
                    .tapStreamsNotFound(input: [2, 2], taps: [2]))
        expectFault(GraphLayout.resolve(taps: [a], input: layout([2]), output: layout([8]), stereoChannels: [8, 9]),
                    .invalidStereoChannels)
        expectFault(
            GraphLayout.resolve(
                taps: [TapFormat(key: .bundle("a"), channels: 6, sampleRate: 48000, isFloat32: true)],
                input: layout([6]), output: layout([2])
            ),
            .tapChannelsUnsupported(6)
        )
    }

    private static func checkRendering() {
        let frames = 64
        renderCase("normalized mono fold", input: [2], output: [1], gains: [1]) { input in
            input.fill(0) { _ in 0.25 }
        } verify: { output in
            expect(abs(output.sample(0, 0) - 0.25) < 0.0001,
                   "duplicated mono preserves unity", "mono fold changes level")
        }

        renderCase("interleaved stereo at 200%", input: [2], output: [2], gains: [2]) { input in
            input.fill(0) { _ in 0.25 }
        } verify: { output in
            let wrong = (0..<(frames * 2)).filter { abs(output.sample(0, $0) - 0.5) > 0.0001 }
            expect(wrong.isEmpty, "gain applied to every sample", "\(wrong.count) samples off")
        }

        renderCase("two slots sum", input: [2, 2], output: [2], gains: [1, 0.5]) { input in
            input.fill(0) { _ in 0.2 }
            input.fill(1) { _ in 0.4 }
        } verify: { output in
            expect(
                abs(output.sample(0, 0) - 0.4) < 0.0001,
                "slots summed with their own gains",
                "got \(output.sample(0, 0)) want 0.4"
            )
        }

        renderCase(
            "non-interleaved output", input: [2], output: [1, 1], gains: [1], prefill: 9
        ) { input in
            input.fill(0) { index in index % 2 == 0 ? 0.3 : 0.6 }
        } verify: { output in
            expect(
                abs(output.sample(0, 0) - 0.3) < 0.0001 && abs(output.sample(1, 0) - 0.6) < 0.0001,
                "both output buffers written",
                "left=\(output.sample(0, 0)) right=\(output.sample(1, 0))"
            )
        }

        renderCase(
            "multichannel output", input: [2], output: [8], gains: [1], prefill: 9
        ) { input in
            input.fill(0) { _ in 0.5 }
        } verify: { output in
            let front = abs(output.sample(0, 0) - 0.5) < 0.0001
                && abs(output.sample(0, 1) - 0.5) < 0.0001
            let rest = (2..<8).allSatisfy { output.sample(0, $0) == 0 }
            expect(front, "front channels carry the mix", "front=\(output.sample(0, 0))")
            expect(rest, "unused channels are cleared", "stale data left in channels 2-7")
        }

        renderCase(
            "duplex input offset", input: [1, 2], output: [2], gains: [1], prefill: 9
        ) { input in
            input.fill(0) { _ in 5 }
            input.fill(1) { _ in 0.25 }
        } verify: { output in
            expect(
                abs(output.sample(0, 0) - 0.25) < 0.0001,
                "the device's own input stream is not rendered",
                "got \(output.sample(0, 0)), expected 0.25"
            )
        }

        renderCase("hard clipping", input: [2], output: [2], gains: [2]) { input in
            input.fill(0) { _ in 0.8 }
        } verify: { output in
            expect(
                abs(output.sample(0, 0) - 1) < 0.0001,
                "output is clipped to unity",
                "got \(output.sample(0, 0))"
            )
        }

        let selected = try! GraphLayout.resolve(taps: [tap("selected")], input: layout([2]),
                                                output: layout([8]), stereoChannels: [2, 3]).get()
        let renderer = MixRenderer()
        renderer.apply(selected, gains: [1])
        let source = SyntheticBuffers([2], frames: 64)
        source.fill(0) { _ in 0.25 }
        let wide = SyntheticBuffers([8], frames: 64)
        renderer.render(input: source.list.unsafePointer, output: wide.list.unsafeMutablePointer)
        expect(wide.sample(0, 0) == 0 && wide.sample(0, 2) == 0.25 && wide.sample(0, 3) == 0.25,
               "explicit stereo pair selects its physical channels", "incorrect stereo pair")
        let changed = SyntheticBuffers([1], frames: 64, prefill: 9)
        renderer.render(input: source.list.unsafePointer, output: changed.list.unsafeMutablePointer)
        expect(renderer.takeLayoutFault() && changed.sample(0, 0) == 0,
               "changed output shape is silenced before stale-stride writes", "unsafe output shape accepted")

        let stereo = try! GraphLayout.resolve(taps: [tap("ramp")], input: layout([2]), output: layout([2])).get()
        renderer.apply(stereo, gains: [0])
        renderer.configure(sampleRate: 48000, framesPerBuffer: 64)
        renderer.setGain(1, slot: 0)
        let ramped = SyntheticBuffers([2], frames: 64)
        renderer.render(input: source.list.unsafePointer, output: ramped.list.unsafeMutablePointer)
        let last = ramped.sample(0, 126)
        expect(ramped.sample(0, 0) == 0 && last > 0 && last < 0.25,
               "gain changes ramp without a full-scale step", "gain ramp is discontinuous")
        renderer.render(input: source.list.unsafePointer, output: ramped.list.unsafeMutablePointer)
        expect(ramped.sample(0, 0) >= last, "gain ramp continues across buffers", "gain ramp resets at buffer boundary")
    }

    private static func renderCase(
        _ name: String,
        input channels: [Int],
        output outputChannels: [Int],
        gains: [Float],
        prefill: Float = 0,
        frames: Int = 64,
        setup: (SyntheticBuffers) -> Void,
        verify: (SyntheticBuffers) -> Void
    ) {
        let taps = channels.suffix(gains.count).enumerated().map { index, count in
            TapFormat(
                key: .bundle("slot\(index)"), channels: count, sampleRate: 48000, isFloat32: true
            )
        }
        let resolved = GraphLayout.resolve(
            taps: taps, input: layout(channels), output: layout(outputChannels),
            inputPrefix: Array(channels.dropLast(gains.count))
        )
        guard case .success(let graph) = resolved else {
            fail("\(name): layout rejected \(resolved)")
            return
        }

        let renderer = MixRenderer()
        renderer.configure(sampleRate: 48000, framesPerBuffer: frames)
        renderer.apply(graph, gains: gains)

        let input = SyntheticBuffers(channels, frames: frames)
        let output = SyntheticBuffers(outputChannels, frames: frames, prefill: prefill)
        setup(input)
        renderer.render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        note("- \(name)")
        verify(output)
    }

    private static func tap(_ name: String) -> TapFormat {
        TapFormat(key: .bundle(name), channels: 2, sampleRate: 48000, isFloat32: true)
    }

    private static func layout(_ channels: [Int]) -> BufferLayout {
        BufferLayout(bufferChannels: channels, isFloat32: true, sampleRate: 48000)
    }

    private static func expectFault(
        _ result: Result<GraphLayout, LayoutFault>, _ wanted: LayoutFault
    ) {
        switch result {
        case .success:
            fail("expected \(wanted) but the layout was accepted")
        case .failure(let fault):
            expect(fault == wanted, "rejected: \(fault)", "expected \(wanted), got \(fault)")
        }
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
            fail("register: \(error.localizedDescription)")
        }
        if !wasEnabled {
            do {
                try LoginItem.setEnabled(false)
                note("after unregister: status=\(LoginItem.statusName)")
            } catch {
                fail("unregister: \(error.localizedDescription)")
            }
        } else {
            note("left registered, it was already enabled before this run")
        }
        finish(nil)
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
                    .map { "\($0.name)\($0.isPlaying ? "*" : "")@\(Int($0.percent))\($0.isActive ? "!" : ($0.isControlled ? "?" : ""))" }
                    .joined(separator: ", ")
                note("t=\(elapsed)s rows=[\(listing)]")
                try? await Task.sleep(for: .seconds(3))
            }
            finish(model)
        }
    }

    static func runMulti(model: MixerModel) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--multi"), index + 4 < arguments.count else {
            fail("usage: --multi <matchA> <pctA> <matchB> <pctB>")
            finish(nil)
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
            let rows = model.rows.filter(\.isPlaying)
            for row in rows { note("playing: \(row.name) [\(row.id.raw)]") }

            guard let a = playing(model, matching: matchA) else {
                fail("no playing row matching '\(matchA)'")
                finish(model)
                return
            }
            guard let b = rows.first(where: { $0.id != a.id && matches($0, matchB) }) else {
                fail("no second playing row matching '\(matchB)' distinct from \(a.id.raw)")
                finish(model)
                return
            }
            note("A=\(a.id.raw) B=\(b.id.raw)")
            let savedA = model.savedPercent(for: a.id)
            let savedB = model.savedPercent(for: b.id)

            model.setPercent(pctA, for: a.id)
            try? await Task.sleep(for: .milliseconds(500))
            note("after A: controlled=\(controlledCount(model)) error=\(model.engineError ?? "none")")

            model.setPercent(pctB, for: b.id)
            try? await Task.sleep(for: .milliseconds(500))
            note("after B: controlled=\(controlledCount(model)) error=\(model.engineError ?? "none")")

            let first = await measurePair(model, a.id, b.id, seconds: 3, settle: 1.2)
            note("first A(\(Int(pctA))%)=\(fmt(first.0))  B(\(Int(pctB))%)=\(fmt(first.1))")
            expect(
                first.0 > 0 && first.1 > 0, "both sources render", "A=\(fmt(first.0)) B=\(fmt(first.1))"
            )

            model.setPercent(pctB, for: a.id)
            model.setPercent(pctA, for: b.id)
            let second = await measurePair(model, a.id, b.id, seconds: 3, settle: 1.2)
            note("swapped A(\(Int(pctB))%)=\(fmt(second.0))  B(\(Int(pctA))%)=\(fmt(second.1))")

            model.setPercent(0, for: a.id)
            let third = await measurePair(model, a.id, b.id, seconds: 2, settle: 2.5)
            note("muted A(0%)=\(fmt(third.0))  B(\(Int(pctA))%)=\(fmt(third.1))")
            expect(third.0 < first.0 * 0.2, "muting A silenced only A", "A still at \(fmt(third.0))")
            expect(third.1 > 0, "B keeps rendering while A is muted", "B fell to \(fmt(third.1))")

            note("clipping=\(model.clipping)")
            restore(model, a.id, savedA)
            restore(model, b.id, savedB)
            finish(model)
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
                note("playing: \(row.name) [\(row.id.raw)] objects=\(row.objectIDs.count)")
            }
            guard let target = model.rows.first(where: { matches($0, match) }) else {
                fail("no row matching '\(match)'")
                finish(model)
                return
            }
            let saved = model.savedPercent(for: target.id)

            model.setPercent(percent, for: target.id)
            try? await Task.sleep(for: .milliseconds(400))
            note("active=\(model.rows.first { $0.id == target.id }?.isActive ?? false) error=\(model.engineError ?? "none")")
            let boosted = await measure(model, id: target.id, seconds: 3)
            note("A boost \(Int(percent))%: peak=\(fmt(boosted))")
            expect(boosted > 0, "boosted source renders", "no level at \(Int(percent))%")

            model.setPercent(0, for: target.id)
            let muted = await measure(model, id: target.id, seconds: 2, settle: 2.5)
            note("B mute 0%: peak=\(fmt(muted))")
            expect(muted < boosted * 0.2, "mute silences the source", "still at \(fmt(muted))")

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
                    expect(after > 0, "still rendering after the switch", "peak fell to \(fmt(after))")
                    let restore = setDefaultOutput(original)
                    note("C restored \(originalName) status=\(statusName(restore))")
                    try? await Task.sleep(for: .milliseconds(1500))
                    let back = await measure(model, id: target.id, seconds: 2)
                    note("D after restore: output=\(model.outputDeviceName) peak=\(fmt(back))")
                    expect(back > 0, "still rendering after the restore", "peak fell to \(fmt(back))")
                } else {
                    note("C skipped, only one output device")
                }
            }

            note("clipping=\(model.clipping)")
            restore(model, target.id, saved)
            finish(model)
        }
    }

    private static func matches(_ row: MixerModel.Row, _ needle: String) -> Bool {
        needle.isEmpty
            || row.id.matches(needle)
            || row.name.localizedCaseInsensitiveContains(needle)
    }

    private static func playing(_ model: MixerModel, matching needle: String) -> MixerModel.Row? {
        model.rows.filter(\.isPlaying).first { matches($0, needle) }
    }

    private static func restore(_ model: MixerModel, _ id: SourceID, _ saved: Double?) {
        if let saved {
            model.setPercent(saved, for: id)
        } else {
            model.reset(id)
        }
        note("restored \(id.raw) to \(saved.map { String(Int($0)) } ?? "unset")")
    }

    private static func isControlled(_ model: MixerModel, _ id: SourceID) -> Bool {
        model.rows.first { $0.id == id }?.isControlled ?? false
    }

    private static func ownProcessObjects() -> [AudioObjectID] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return systemObject
            .array(propertyAddress(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)
            .filter {
                $0.value(propertyAddress(kAudioProcessPropertyPID), default: pid_t(-1)) == ownPID
            }
    }

    private static func holdsOutput() -> Bool {
        ownProcessObjects().contains {
            $0.value(propertyAddress(kAudioProcessPropertyIsRunningOutput), default: UInt32(0)) != 0
        }
    }

    private static func deviceRunning() -> Bool {
        defaultOutput().value(
            propertyAddress(kAudioDevicePropertyDeviceIsRunningSomewhere), default: UInt32(0)
        ) != 0
    }

    private static func controlledCount(_ model: MixerModel) -> Int {
        model.rows.filter(\.isControlled).count
    }

    private static func measurePair(
        _ model: MixerModel, _ idA: SourceID, _ idB: SourceID, seconds: Double, settle: Double
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

    private static func measure(
        _ model: MixerModel, id: SourceID, seconds: Double, settle: Double = 0.8
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

    private static func expect(_ condition: Bool, _ passed: String, _ failed: String) {
        if condition {
            note("PASS \(passed)")
        } else {
            fail(failed)
        }
    }

    private static func fail(_ message: String) {
        failures += 1
        note("FAIL \(message)")
    }

    private static func finish(_ model: MixerModel?) {
        note(failures == 0 ? "RESULT pass" : "RESULT fail (\(failures))")
        model?.shutdown()
        exit(failures == 0 ? 0 : 1)
    }

    private static func fmt(_ value: Float) -> String {
        String(format: "%.4f", value)
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

final class SyntheticBuffers {
    let list: UnsafeMutableAudioBufferListPointer
    private let channels: [Int]
    private let frames: Int
    private var storage: [UnsafeMutablePointer<Float>] = []

    init(_ channels: [Int], frames: Int, prefill: Float = 0) {
        self.channels = channels
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: max(channels.count, 1))
        list.count = channels.count
        for (index, count) in channels.enumerated() {
            let samples = count * frames
            let data = UnsafeMutablePointer<Float>.allocate(capacity: samples)
            data.initialize(repeating: prefill, count: samples)
            storage.append(data)
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(count),
                mDataByteSize: UInt32(samples * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(data)
            )
        }
    }

    deinit {
        for pointer in storage { pointer.deallocate() }
        free(list.unsafeMutablePointer)
    }

    func fill(_ buffer: Int, _ value: (Int) -> Float) {
        let count = channels[buffer] * frames
        for index in 0..<count { storage[buffer][index] = value(index) }
    }

    func sample(_ buffer: Int, _ index: Int) -> Float {
        storage[buffer][index]
    }
}
