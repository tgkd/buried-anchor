import CoreAudio
import Foundation

struct BufferLayout: Equatable {
    let bufferChannels: [Int]
    let isFloat32: Bool
    let sampleRate: Double

    var totalChannels: Int { bufferChannels.reduce(0, +) }

    static let empty = BufferLayout(bufferChannels: [], isFloat32: false, sampleRate: 0)
}

struct TapFormat: Equatable {
    let key: SourceID
    let channels: Int
    let sampleRate: Double
    let isFloat32: Bool
}

enum LayoutFault: Error, Equatable {
    case noTaps
    case noOutputChannels
    case outputNotFloat32
    case inputNotFloat32
    case tapNotFloat32
    case tapChannelsUnsupported(Int)
    case aggregateSampleRateMismatch(input: Double, output: Double)
    case capacityExceeded
    case invalidStereoChannels
    case tapStreamsNotFound(input: [Int], taps: [Int])

    var message: String {
        switch self {
        case .noTaps:
            "no taps to route"
        case .noOutputChannels:
            "the output device exposes no output channels"
        case .outputNotFloat32:
            "this output device does not use 32-bit float samples"
        case .inputNotFloat32:
            "the mix device did not come up as 32-bit float"
        case .tapNotFloat32:
            "a capture stream did not come up as 32-bit float"
        case .tapChannelsUnsupported(let channels):
            "a capture stream reported \(channels) channels"
        case .aggregateSampleRateMismatch:
            "the aggregate input and output sample rates could not be verified"
        case .capacityExceeded:
            "the audio layout exceeds the renderer capacity"
        case .invalidStereoChannels:
            "the output's preferred stereo channels are invalid"
        case .tapStreamsNotFound(let input, let taps):
            "could not match \(taps.count) capture streams to the mix device inputs \(input)"
        }
    }
}

struct GraphLayout: Equatable {
    struct Slot: Equatable {
        let key: SourceID
        let inputBuffer: Int
        let channels: Int
        let targets: [Int]
        var scale: Float = 1
    }

    struct OutputChannel: Equatable {
        let buffer: Int
        let offset: Int
        let stride: Int
    }

    let slots: [Slot]
    let outputChannels: [OutputChannel]
    let inputOffset: Int
    let sampleRate: Double

    static func resolve(
        taps: [TapFormat], input: BufferLayout, output: BufferLayout,
        inputPrefix: [Int] = [], stereoChannels: [Int] = [0, 1]
    ) -> Result<GraphLayout, LayoutFault> {
        guard !taps.isEmpty else { return .failure(.noTaps) }
        guard taps.count <= MixRenderer.maxSlots,
              output.totalChannels <= MixRenderer.maxOutputChannels else {
            return .failure(.capacityExceeded)
        }
        guard output.totalChannels > 0 else { return .failure(.noOutputChannels) }
        guard output.isFloat32 else { return .failure(.outputNotFloat32) }
        guard input.isFloat32 else { return .failure(.inputNotFloat32) }
        guard taps.allSatisfy(\.isFloat32) else { return .failure(.tapNotFloat32) }

        for tap in taps where tap.channels < 1 || tap.channels > MixRenderer.maxTapChannels {
            return .failure(.tapChannelsUnsupported(tap.channels))
        }

        let rate = output.sampleRate
        guard rate.isFinite, rate > 0, input.sampleRate == rate else {
            return .failure(.aggregateSampleRateMismatch(input: input.sampleRate, output: rate))
        }

        let wanted = taps.map(\.channels)
        let offset = inputPrefix.count
        guard input.bufferChannels == inputPrefix + wanted else {
            return .failure(.tapStreamsNotFound(input: input.bufferChannels, taps: wanted))
        }

        var outputChannels: [OutputChannel] = []
        for (buffer, channels) in output.bufferChannels.enumerated() {
            for channel in 0..<channels {
                outputChannels.append(
                    OutputChannel(buffer: buffer, offset: channel, stride: channels)
                )
            }
        }

        let total = outputChannels.count
        guard total == 1 || (stereoChannels.count == 2
            && Set(stereoChannels).count == 2
            && stereoChannels.allSatisfy { $0 >= 0 && $0 < total }) else {
            return .failure(.invalidStereoChannels)
        }
        let slots = taps.enumerated().map { index, tap in
            Slot(
                key: tap.key,
                inputBuffer: offset + index,
                channels: tap.channels,
                targets: (0..<tap.channels).map { channel in
                    if total == 1 { return 0 }
                    return stereoChannels[channel]
                },
                scale: total == 1 && tap.channels == 2 ? 0.5 : 1
            )
        }

        return .success(
            GraphLayout(
                slots: slots, outputChannels: outputChannels, inputOffset: offset, sampleRate: rate
            )
        )
    }

    var summary: String {
        let outputs = outputChannels.map { "b\($0.buffer)+\($0.offset)/\($0.stride)" }
        return "rate=\(Int(sampleRate)) inputOffset=\(inputOffset)"
            + " slots=[\(slots.map { "\($0.key.raw)@buf\($0.inputBuffer)x\($0.channels)" }.joined(separator: " "))]"
            + " out=[\(outputs.joined(separator: " "))]"
    }
}
