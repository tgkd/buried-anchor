import Accelerate
import CoreAudio
import Foundation
import Synchronization

final class MixRenderer: @unchecked Sendable {
    static let maxSlots = 32
    static let maxTapChannels = 2
    static let maxOutputChannels = 64
    static let rampSeconds: Float = 0.03
    static let softClipKnee: Float = 0.7

    private let targets: UnsafeMutablePointer<Atomic<Float>>
    private let current: UnsafeMutablePointer<Atomic<Float>>
    private let slotPeak: UnsafeMutablePointer<Atomic<Float>>
    private let slotInputBuffer: UnsafeMutablePointer<Int32>
    private let slotChannels: UnsafeMutablePointer<Int32>
    private let slotTargets: UnsafeMutablePointer<Int32>
    private let slotScale: UnsafeMutablePointer<Float>
    private let outputBuffer: UnsafeMutablePointer<Int32>
    private let outputOffset: UnsafeMutablePointer<Int32>
    private let outputStride: UnsafeMutablePointer<Int32>
    private let outputPeak = Atomic<Float>(0)
    private let clipCount = Atomic<Int32>(0)
    private let activeSlots = Atomic<Int32>(0)
    private let outputChannelCount = Atomic<Int32>(0)
    private let softClip = Atomic<Bool>(false)
    private let coefficient = Atomic<Float>(0.3)
    private let layoutFault = Atomic<Bool>(false)

    init() {
        targets = .allocate(capacity: Self.maxSlots)
        current = .allocate(capacity: Self.maxSlots)
        slotPeak = .allocate(capacity: Self.maxSlots)
        slotInputBuffer = .allocate(capacity: Self.maxSlots)
        slotChannels = .allocate(capacity: Self.maxSlots)
        slotTargets = .allocate(capacity: Self.maxSlots * Self.maxTapChannels)
        slotScale = .allocate(capacity: Self.maxSlots)
        slotScale.initialize(repeating: 1, count: Self.maxSlots)
        outputBuffer = .allocate(capacity: Self.maxOutputChannels)
        outputOffset = .allocate(capacity: Self.maxOutputChannels)
        outputStride = .allocate(capacity: Self.maxOutputChannels)
        for slot in 0..<Self.maxSlots {
            (targets + slot).initialize(to: Atomic(1))
            (current + slot).initialize(to: Atomic(1))
            (slotPeak + slot).initialize(to: Atomic(0))
        }
        slotInputBuffer.initialize(repeating: -1, count: Self.maxSlots)
        slotChannels.initialize(repeating: 0, count: Self.maxSlots)
        slotTargets.initialize(repeating: -1, count: Self.maxSlots * Self.maxTapChannels)
        outputBuffer.initialize(repeating: -1, count: Self.maxOutputChannels)
        outputOffset.initialize(repeating: 0, count: Self.maxOutputChannels)
        outputStride.initialize(repeating: 1, count: Self.maxOutputChannels)
    }

    deinit {
        targets.deinitialize(count: Self.maxSlots)
        current.deinitialize(count: Self.maxSlots)
        slotPeak.deinitialize(count: Self.maxSlots)
        targets.deallocate()
        current.deallocate()
        slotPeak.deallocate()
        slotInputBuffer.deallocate()
        slotChannels.deallocate()
        slotTargets.deallocate()
        slotScale.deallocate()
        outputBuffer.deallocate()
        outputOffset.deallocate()
        outputStride.deallocate()
    }

    func configure(sampleRate: Double, framesPerBuffer: Int) {
        guard sampleRate > 0, framesPerBuffer > 0 else { return }
        let bufferSeconds = Float(Double(framesPerBuffer) / sampleRate)
        coefficient.store(1 - exp(-bufferSeconds / Self.rampSeconds), ordering: .relaxed)
    }

    func apply(_ layout: GraphLayout, gains: [Float]) {
        layoutFault.store(false, ordering: .relaxed)
        activeSlots.store(0, ordering: .releasing)
        let slots = min(layout.slots.count, Self.maxSlots)
        for slot in 0..<slots {
            let source = layout.slots[slot]
            slotInputBuffer[slot] = Int32(source.inputBuffer)
            slotChannels[slot] = Int32(source.channels)
            slotScale[slot] = source.scale
            for channel in 0..<Self.maxTapChannels {
                let target = channel < source.targets.count ? source.targets[channel] : -1
                slotTargets[slot * Self.maxTapChannels + channel] = Int32(target)
            }
            let gain = slot < gains.count ? gains[slot] : 1
            targets[slot].store(gain, ordering: .relaxed)
            current[slot].store(gain, ordering: .relaxed)
            slotPeak[slot].store(0, ordering: .relaxed)
        }
        let channels = min(layout.outputChannels.count, Self.maxOutputChannels)
        for channel in 0..<channels {
            let target = layout.outputChannels[channel]
            outputBuffer[channel] = Int32(target.buffer)
            outputOffset[channel] = Int32(target.offset)
            outputStride[channel] = Int32(max(target.stride, 1))
        }
        outputChannelCount.store(Int32(channels), ordering: .relaxed)
        activeSlots.store(Int32(slots), ordering: .releasing)
    }

    func clearSlots() {
        activeSlots.store(0, ordering: .releasing)
        outputChannelCount.store(0, ordering: .relaxed)
    }

    func setGain(_ gain: Float, slot: Int) {
        guard gain.isFinite, gain >= 0, slot >= 0, slot < Self.maxSlots else { return }
        targets[slot].store(gain, ordering: .relaxed)
    }

    func setSoftClip(_ enabled: Bool) {
        softClip.store(enabled, ordering: .relaxed)
    }

    func takePeak(slot: Int) -> Float {
        guard slot >= 0, slot < Self.maxSlots else { return 0 }
        return slotPeak[slot].exchange(0, ordering: .relaxed)
    }

    func takeClipCount() -> Int {
        Int(clipCount.exchange(0, ordering: .relaxed))
    }

    func takeOutputPeak() -> Float {
        outputPeak.exchange(0, ordering: .relaxed)
    }

    func takeLayoutFault() -> Bool {
        layoutFault.exchange(false, ordering: .relaxed)
    }

    func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>
    ) {
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        var frameLimit = Int.max
        for index in 0..<outputs.count {
            let buffer = outputs[index]
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let samples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard samples > 0 else { continue }
            vDSP_vclr(data, 1, vDSP_Length(samples))
            frameLimit = min(frameLimit, samples / Int(max(buffer.mNumberChannels, 1)))
        }
        guard frameLimit > 0, frameLimit != Int.max else { return }

        let slots = Int(activeSlots.load(ordering: .acquiring))
        let channelCount = Int(outputChannelCount.load(ordering: .relaxed))
        guard slots > 0, channelCount > 0 else { return }

        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        for channel in 0..<channelCount {
            let buffer = Int(outputBuffer[channel])
            guard buffer >= 0, buffer < outputs.count,
                  Int(outputs[buffer].mNumberChannels) == Int(outputStride[channel]),
                  Int(outputOffset[channel]) < Int(outputStride[channel]) else {
                layoutFault.store(true, ordering: .relaxed)
                return
            }
        }
        for slot in 0..<slots {
            let buffer = Int(slotInputBuffer[slot])
            guard buffer >= 0, buffer < inputs.count,
                  Int(inputs[buffer].mNumberChannels) == Int(slotChannels[slot]) else {
                layoutFault.store(true, ordering: .relaxed)
                return
            }
        }
        let ramp = coefficient.load(ordering: .relaxed)

        for slot in 0..<slots {
            let index = Int(slotInputBuffer[slot])
            guard index >= 0, index < inputs.count else { continue }
            let buffer = inputs[index]
            let channels = Int(slotChannels[slot])
            guard channels > 0, channels <= Self.maxTapChannels,
                  Int(buffer.mNumberChannels) == channels,
                  let source = buffer.mData?.assumingMemoryBound(to: Float.self)
            else { continue }

            let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let frames = min(available, frameLimit)
            guard frames > 0 else { continue }

            let from = current[slot].load(ordering: .relaxed)
            let to = from + (targets[slot].load(ordering: .relaxed) - from) * ramp
            let increment = (to - from) / Float(frames)
            var peak: Float = 0

            for channel in 0..<channels {
                let target = Int(slotTargets[slot * Self.maxTapChannels + channel])
                guard target >= 0, target < channelCount else { continue }
                let destination = Int(outputBuffer[target])
                guard destination >= 0, destination < outputs.count,
                      let base = outputs[destination].mData?.assumingMemoryBound(to: Float.self)
                else { continue }
                var start = from * slotScale[slot]
                var step = increment * slotScale[slot]
                vDSP_vrampmuladd(
                    source + channel, vDSP_Stride(channels),
                    &start, &step,
                    base + Int(outputOffset[target]), vDSP_Stride(outputStride[target]),
                    vDSP_Length(frames)
                )
                var channelPeak: Float = 0
                vDSP_maxmgv(source + channel, vDSP_Stride(channels), &channelPeak, vDSP_Length(frames))
                peak = max(peak, channelPeak)
            }

            current[slot].store(to, ordering: .relaxed)
            raiseMax(slotPeak[slot], to: peak * max(from, to))
        }

        var loudest: Float = 0
        let shaping = softClip.load(ordering: .relaxed)
        for index in 0..<outputs.count {
            let buffer = outputs[index]
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let samples = vDSP_Length(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            guard samples > 0 else { continue }
            var peak: Float = 0
            vDSP_maxmgv(data, 1, &peak, samples)
            loudest = max(loudest, peak)
            if shaping {
                Self.shape(data, count: Int(samples))
            } else {
                var low: Float = -1
                var high: Float = 1
                vDSP_vclip(data, 1, &low, &high, data, 1, samples)
            }
        }
        raiseMax(outputPeak, to: loudest)
        if loudest > 1 { clipCount.wrappingAdd(1, ordering: .relaxed) }
    }

    private func raiseMax(_ cell: borrowing Atomic<Float>, to value: Float) {
        var observed = cell.load(ordering: .relaxed)
        while value > observed {
            let (exchanged, latest) = cell.compareExchange(
                expected: observed, desired: value, ordering: .relaxed
            )
            if exchanged { return }
            observed = latest
        }
    }

    private static func shape(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        let knee = Self.softClipKnee
        let span = 1 - knee
        for index in 0..<count {
            let sample = samples[index]
            let magnitude = abs(sample)
            guard magnitude > knee else { continue }
            let shaped = knee + span * tanhf((magnitude - knee) / span)
            samples[index] = sample < 0 ? -shaped : shaped
        }
    }
}
