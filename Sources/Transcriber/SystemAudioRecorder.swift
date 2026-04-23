import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// Captures system (other apps') audio via ScreenCaptureKit into a CAF file.
/// Requires Screen Recording permission (macOS prompts on first use).
final class SystemAudioRecorder: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {

    enum Failure: Error, LocalizedError {
        case noDisplayAvailable
        case writerCreationFailed
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .noDisplayAvailable: return "No display available for capture."
            case .writerCreationFailed: return "Could not create audio writer."
            case .permissionDenied:
                return "Screen Recording permission is required to capture system audio. Grant it in System Settings → Privacy & Security → Screen Recording."
            }
        }
    }

    private let queue = DispatchQueue(label: "io.srcful.transcriber.system-audio")

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false
    private(set) var outputURL: URL?

    private let levelLock = NSLock()
    private var _smoothedLevel: Float = 0
    private var loggedFirstSample = false

    /// Smoothed 0…1 audio level. Safe to read from any thread.
    var currentLevel: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return _smoothedLevel
    }

    func start(to url: URL) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Failure.permissionDenied
        }
        guard let display = content.displays.first else { throw Failure.noDisplayAvailable }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        // Mono keeps RMS bookkeeping simple (one buffer in the
        // AudioBufferList regardless of planar vs interleaved) and is
        // enough for a level meter — stereo layouts had the right
        // channel's level silently dropped.
        config.channelCount = 1
        // We're not using video; keep it tiny and slow.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let newWriter: AVAssetWriter
        do {
            newWriter = try AVAssetWriter(url: url, fileType: .caf)
        } catch {
            throw Failure.writerCreationFailed
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let newInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        newInput.expectsMediaDataInRealTime = true
        guard newWriter.canAdd(newInput) else { throw Failure.writerCreationFailed }
        newWriter.add(newInput)

        guard newWriter.startWriting() else {
            throw newWriter.error ?? Failure.writerCreationFailed
        }

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)

        queue.sync {
            self.stream = newStream
            self.writer = newWriter
            self.input = newInput
            self.outputURL = url
            self.sessionStarted = false
            self.loggedFirstSample = false
        }

        try await newStream.startCapture()
    }

    func stop() async {
        let (capturedStream, capturedWriter, capturedInput): (SCStream?, AVAssetWriter?, AVAssetWriterInput?) =
            await withCheckedContinuation { cont in
                queue.async {
                    let s = self.stream
                    let w = self.writer
                    let i = self.input
                    self.stream = nil
                    cont.resume(returning: (s, w, i))
                }
            }

        if let s = capturedStream {
            try? await s.stopCapture()
        }

        await withCheckedContinuation { cont in
            queue.async {
                capturedInput?.markAsFinished()
                if let w = capturedWriter {
                    w.finishWriting { cont.resume() }
                } else {
                    cont.resume()
                }
                self.writer = nil
                self.input = nil
            }
        }

        queue.async { [self] in
            levelLock.lock()
            _smoothedLevel = 0
            levelLock.unlock()
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Delivered on `queue`.
        guard type == .audio, sampleBuffer.isValid else { return }
        if !loggedFirstSample {
            loggedFirstSample = true
            let n = CMSampleBufferGetNumSamples(sampleBuffer)
            NSLog("[SystemAudio] First audio sample received (%d frames)", n)
        }
        if !sessionStarted {
            writer?.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            sessionStarted = true
        }
        if let input = input, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }

        let level = Self.computeNormalizedLevel(from: sampleBuffer)
        levelLock.lock()
        _smoothedLevel = _smoothedLevel * 0.7 + level * 0.3
        levelLock.unlock()
    }

    private static func computeNormalizedLevel(from sb: CMSampleBuffer) -> Float {
        var audioBufferList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return 0 }

        let abl = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        var sumSq: Float = 0
        var count: Int = 0
        for buffer in abl {
            guard let data = buffer.mData else { continue }
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
            let floats = data.bindMemory(to: Float32.self, capacity: sampleCount)
            for i in 0..<sampleCount {
                let v = floats[i]
                sumSq += v * v
            }
            count += sampleCount
        }
        guard count > 0 else { return 0 }
        let rms = sqrtf(sumSq / Float(count))
        // Map -50 dBFS…0 dBFS to 0…1 for a usable visual range.
        let db = 20 * log10f(max(rms, 1e-4))
        let floor: Float = -50
        let clamped = max(floor, min(0, db))
        return (clamped - floor) / -floor
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Logged only; stop() path handles finalization.
        NSLog("SCStream stopped with error: \(error)")
    }
}
