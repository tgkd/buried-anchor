import Accelerate
import CoreAudio
import Foundation
import Synchronization

final class MixRenderer: @unchecked Sendable {
    static let maxSlots = 32
    static let rampSeconds: Float = 0.03
    static let softClipKnee: Float = 0.7

    private let targets: UnsafeMutablePointer<Atomic<Float>>
    private let current: UnsafeMutablePointer<Atomic<Float>>
    private let slotPeak: UnsafeMutablePointer<Atomic<Float>>
    private let outputPeak = Atomic<Float>(0)
    private let clipCount = Atomic<Int32>(0)
    private let activeSlots = Atomic<Int32>(0)
    private let softClip = Atomic<Bool>(false)
    private let coefficient = Atomic<Float>(0.3)

    init() {
        targets = .allocate(capacity: Self.maxSlots)
        current = .allocate(capacity: Self.maxSlots)
        slotPeak = .allocate(capacity: Self.maxSlots)
        for slot in 0..<Self.maxSlots {
            (targets + slot).initialize(to: Atomic(1))
            (current + slot).initialize(to: Atomic(1))
            (slotPeak + slot).initialize(to: Atomic(0))
        }
    }

    deinit {
        targets.deinitialize(count: Self.maxSlots)
        current.deinitialize(count: Self.maxSlots)
        slotPeak.deinitialize(count: Self.maxSlots)
        targets.deallocate()
        current.deallocate()
        slotPeak.deallocate()
    }

    func configure(sampleRate: Double, framesPerBuffer: Int) {
        guard sampleRate > 0, framesPerBuffer > 0 else { return }
        let bufferSeconds = Float(Double(framesPerBuffer) / sampleRate)
        coefficient.store(1 - exp(-bufferSeconds / Self.rampSeconds), ordering: .relaxed)
    }

    func setSlotCount(_ count: Int) {
        activeSlots.store(Int32(min(count, Self.maxSlots)), ordering: .relaxed)
    }

    func setGain(_ gain: Float, slot: Int) {
        guard slot >= 0, slot < Self.maxSlots else { return }
        targets[slot].store(gain, ordering: .relaxed)
    }

    func primeGain(_ gain: Float, slot: Int) {
        guard slot >= 0, slot < Self.maxSlots else { return }
        targets[slot].store(gain, ordering: .relaxed)
        current[slot].store(gain, ordering: .relaxed)
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

    func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        guard let outBuffer = outputs.first,
              let destination = outBuffer.mData?.assumingMemoryBound(to: Float.self)
        else { return }

        let outCount = vDSP_Length(Int(outBuffer.mDataByteSize) / MemoryLayout<Float>.size)
        guard outCount > 0 else { return }
        vDSP_vclr(destination, 1, outCount)

        let ramp = coefficient.load(ordering: .relaxed)
        let slots = min(Int(activeSlots.load(ordering: .relaxed)), min(inputs.count, Self.maxSlots))
        for slot in 0..<slots {
            guard let source = inputs[slot].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let available = vDSP_Length(Int(inputs[slot].mDataByteSize) / MemoryLayout<Float>.size)
            let count = min(available, outCount)
            guard count > 0 else { continue }

            let from = current[slot].load(ordering: .relaxed)
            let to = from + (targets[slot].load(ordering: .relaxed) - from) * ramp
            var start = from
            var step = (to - from) / Float(count)
            vDSP_vrampmuladd(source, 1, &start, &step, destination, 1, count)
            current[slot].store(to, ordering: .relaxed)

            var peak: Float = 0
            vDSP_maxmgv(source, 1, &peak, count)
            raiseMax(slotPeak[slot], to: peak * max(from, to))
        }

        var peak: Float = 0
        vDSP_maxmgv(destination, 1, &peak, outCount)
        raiseMax(outputPeak, to: peak)
        if peak > 1 { clipCount.wrappingAdd(1, ordering: .relaxed) }

        if softClip.load(ordering: .relaxed) {
            Self.shape(destination, count: Int(outCount))
        } else {
            var low: Float = -1
            var high: Float = 1
            vDSP_vclip(destination, 1, &low, &high, destination, 1, outCount)
        }
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
