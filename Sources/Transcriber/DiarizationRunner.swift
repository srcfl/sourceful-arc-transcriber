import Foundation
import AVFoundation
import FluidAudio

struct SpeakerTurn: Sendable {
    let start: Float
    let end: Float
    let speakerId: String
}

@MainActor
final class DiarizationRunner {
    private var diarizer: DiarizerManager?

    func diarize(audioURL: URL) async throws -> [SpeakerTurn] {
        let d = try await loadIfNeeded()
        let samples = try Self.loadMono16k(from: audioURL)
        guard samples.count > 16_000 else { return [] }  // <1s: skip
        let result = try d.performCompleteDiarization(samples, sampleRate: 16_000)
        return result.segments.map {
            SpeakerTurn(start: $0.startTimeSeconds, end: $0.endTimeSeconds, speakerId: $0.speakerId)
        }
    }

    private func loadIfNeeded() async throws -> DiarizerManager {
        if let d = diarizer { return d }
        let models = try await DiarizerModels.downloadIfNeeded()
        // Single-mic recordings tend to collapse into one cluster at
        // the default 0.7 (FluidAudio's own docs: "Lower = more
        // speakers"). 0.6 nudges it toward splitting voices that sit
        // near the threshold; bump further if very similar speakers
        // still merge.
        var config = DiarizerConfig()
        config.clusteringThreshold = 0.6
        let d = DiarizerManager(config: config)
        d.initialize(models: models)
        diarizer = d
        return d
    }

    static func loadMono16k(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { return [] }

        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else { return [] }

        try file.read(into: input)

        let ratio = target.sampleRate / sourceFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(frameCount) * ratio + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap),
              let converter = AVAudioConverter(from: sourceFormat, to: target) else { return [] }

        var error: NSError?
        var supplied = false
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }

        guard let ptr = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ptr, count: Int(output.frameLength)))
    }
}
