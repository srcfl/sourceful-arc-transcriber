import Foundation
import AVFoundation

/// Captures the default mic with AVAudioEngine, writes the raw audio to a file,
/// exposes a smoothed level, and optionally converts each buffer to 16 kHz mono
/// Float32 samples for live transcription.
final class MicRecorder: @unchecked Sendable {

    enum Failure: Error, LocalizedError {
        case fileCreationFailed(String)
        case engineStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .fileCreationFailed(let m): return "Could not create audio file: \(m)"
            case .engineStartFailed(let m):  return "Could not start audio engine: \(m)"
            }
        }
    }

    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var liveConverter: AVAudioConverter?
    private var liveFormat: AVAudioFormat?
    private(set) var outputURL: URL?

    private let levelLock = NSLock()
    private var _smoothedLevel: Float = 0

    var currentLevel: Float {
        levelLock.lock(); defer { levelLock.unlock() }
        return _smoothedLevel
    }

    /// Called on an arbitrary thread with 16 kHz mono Float32 samples when live is enabled.
    var onLiveSamples: (@Sendable ([Float]) -> Void)?

    func start(to url: URL, live: Bool) throws {
        let input = engine.inputNode
        let nativeFormat = input.outputFormat(forBus: 0)

        do {
            audioFile = try AVAudioFile(forWriting: url, settings: nativeFormat.settings)
        } catch {
            throw Failure.fileCreationFailed(error.localizedDescription)
        }
        outputURL = url

        if live {
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
            liveFormat = target
            if let target {
                liveConverter = AVAudioConverter(from: nativeFormat, to: target)
            }
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw Failure.engineStartFailed(error.localizedDescription)
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        audioFile = nil
        liveConverter = nil
        liveFormat = nil

        levelLock.lock()
        _smoothedLevel = 0
        levelLock.unlock()
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        try? audioFile?.write(from: buffer)

        let level = Self.normalizedLevel(from: buffer)
        levelLock.lock()
        _smoothedLevel = _smoothedLevel * 0.6 + level * 0.4
        levelLock.unlock()

        guard let converter = liveConverter,
              let target = liveFormat else { return }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard capacity > 0,
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var error: NSError?
        var supplied = false
        let inputBuffer = buffer
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return inputBuffer
        }
        guard error == nil,
              let ptr = out.floatChannelData?[0],
              out.frameLength > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: ptr, count: Int(out.frameLength)))
        onLiveSamples?(samples)
    }

    private static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sumSq: Float = 0
        for i in 0..<n {
            let v = channel[i]
            sumSq += v * v
        }
        let rms = sqrtf(sumSq / Float(n))
        let db = 20 * log10f(max(rms, 1e-4))
        let floor: Float = -50
        let clamped = max(floor, min(0, db))
        return (clamped - floor) / -floor
    }
}
