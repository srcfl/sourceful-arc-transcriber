import Foundation
import WhisperKit

enum Speaker: Hashable {
    case you
    case others
    case named(String)

    var label: String {
        switch self {
        case .you:            return "You"
        case .others:         return "Others"
        case .named(let s):   return s
        }
    }
}

struct SpeakerLine {
    let speaker: Speaker
    let start: Float
    let text: String
}

enum TranscriptMerger {

    /// Interleave mic and system-audio Whisper segments (tagged You / Others).
    static func merge(
        mic: [TranscriptionResult],
        system: [TranscriptionResult]
    ) -> String {
        let mineLines = segments(mic, as: .you)
        let theirLines = segments(system, as: .others)
        return format((mineLines + theirLines).sorted { $0.start < $1.start })
    }

    /// Tag Whisper segments with diarized speaker turns ("Speaker 1", "Speaker 2"…).
    /// Speakers are renumbered by first appearance for a friendlier transcript.
    static func mergeWithDiarization(
        whisper: [TranscriptionResult],
        turns: [SpeakerTurn]
    ) -> String {
        let labelMap = renumber(turns)
        var lines: [SpeakerLine] = []
        for result in whisper {
            for seg in result.segments {
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let id = bestSpeakerID(forStart: seg.start, end: seg.end, in: turns)
                let label = id.flatMap { labelMap[$0] } ?? "Speaker ?"
                lines.append(SpeakerLine(speaker: .named(label), start: seg.start, text: text))
            }
        }
        return format(lines.sorted { $0.start < $1.start })
    }

    static func formatSingleSpeaker(_ results: [TranscriptionResult]) -> String {
        results.map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func segments(_ results: [TranscriptionResult], as speaker: Speaker) -> [SpeakerLine] {
        results.flatMap { result in
            result.segments.map { seg in
                SpeakerLine(
                    speaker: speaker,
                    start: seg.start,
                    text: seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }
        .filter { !$0.text.isEmpty }
    }

    private static func bestSpeakerID(forStart start: Float, end: Float, in turns: [SpeakerTurn]) -> String? {
        // Pick the turn with the largest time overlap with [start, end].
        var bestID: String?
        var bestOverlap: Float = 0
        for t in turns {
            let overlap = min(end, t.end) - max(start, t.start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestID = t.speakerId
            }
        }
        return bestID
    }

    private static func renumber(_ turns: [SpeakerTurn]) -> [String: String] {
        var map: [String: String] = [:]
        var counter = 0
        for turn in turns {
            if map[turn.speakerId] == nil {
                counter += 1
                map[turn.speakerId] = "Speaker \(counter)"
            }
        }
        return map
    }

    private static func format(_ lines: [SpeakerLine]) -> String {
        guard !lines.isEmpty else { return "_(no speech detected)_" }

        var blocks: [String] = []
        var currentSpeaker: Speaker?
        var currentStart: Float = 0
        var currentText = ""

        func flush() {
            guard let s = currentSpeaker, !currentText.isEmpty else { return }
            blocks.append("**\(s.label)** [\(timeLabel(currentStart))] \(currentText)")
        }

        for line in lines {
            if line.speaker == currentSpeaker {
                currentText += " " + line.text
            } else {
                flush()
                currentSpeaker = line.speaker
                currentStart = line.start
                currentText = line.text
            }
        }
        flush()
        return blocks.joined(separator: "\n\n")
    }

    private static func timeLabel(_ seconds: Float) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
