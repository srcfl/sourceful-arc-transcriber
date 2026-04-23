import Foundation
import WhisperKit

/// Keeps a rolling window of recent audio samples, periodically transcribes
/// them, and pushes the text back to the caller.
@MainActor
final class LiveTranscriber {

    private let whisper: WhisperKit
    private let sampleRate = 16_000
    private let windowSeconds = 30
    private let pollInterval: TimeInterval = 2.0

    private let buffer = LiveAudioBuffer(maxSamples: 30 * 16_000)
    private var task: Task<Void, Never>?

    var onText: (@MainActor (String) -> Void)?

    init(whisper: WhisperKit) {
        self.whisper = whisper
    }

    func feed(samples: [Float]) {
        Task { await buffer.append(samples) }
    }

    func start(language: String?) {
        task?.cancel()
        task = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Int(self.pollInterval)))
                if Task.isCancelled { break }
                await self.transcribeOnce(language: language)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        Task { [buffer] in await buffer.clear() }
    }

    private func transcribeOnce(language: String?) async {
        let snapshot = await buffer.snapshot()
        guard snapshot.count > sampleRate / 2 else { return }   // need at least 0.5 s

        let options: DecodingOptions = {
            if let language, language != "auto" {
                return DecodingOptions(task: .transcribe, language: language, detectLanguage: false)
            }
            return DecodingOptions(task: .transcribe, detectLanguage: true)
        }()

        do {
            let results = try await whisper.transcribe(audioArray: snapshot, decodeOptions: options)
            let text = results
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run { self.onText?(text) }
        } catch {
            // Swallow — live failures shouldn't bubble up to the user.
        }
    }
}

actor LiveAudioBuffer {
    private var samples: [Float] = []
    private let maxSamples: Int

    init(maxSamples: Int) {
        self.maxSamples = maxSamples
    }

    func append(_ new: [Float]) {
        samples.append(contentsOf: new)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    func snapshot() -> [Float] { samples }
    func clear() { samples.removeAll() }
}
