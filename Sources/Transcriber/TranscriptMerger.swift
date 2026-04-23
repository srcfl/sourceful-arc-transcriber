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
    let end: Float
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
        // Sorted + min/max are used below to distinguish legitimate
        // inter-turn gaps (keep, label "Speaker ?") from trailing or
        // leading hallucinations (drop). With our loosened Whisper
        // thresholds, Whisper happily emits a "Tack tack tack …" kind
        // of line on the quiet tail after Stop — the diarizer gives
        // us the authoritative speech range to clip against.
        let firstTurnStart = turns.map(\.start).min() ?? 0
        let lastTurnEnd = turns.map(\.end).max() ?? 0
        let tolerance: Float = 0.5   // allow half a second of drift at the edges

        var lines: [SpeakerLine] = []
        for result in whisper {
            for seg in result.segments {
                let text = stripWhisperTokens(seg.text)
                guard !text.isEmpty else { continue }

                let id = bestSpeakerID(forStart: seg.start, end: seg.end, in: turns)
                if id == nil {
                    let outsideRange = seg.end < firstTurnStart - tolerance
                                    || seg.start > lastTurnEnd + tolerance
                    if outsideRange { continue }  // drop — hallucination before / after any speech
                }
                let label = id.flatMap { labelMap[$0] } ?? "Speaker ?"
                lines.append(SpeakerLine(speaker: .named(label), start: seg.start, end: seg.end, text: text))
            }
        }
        return format(lines.sorted { $0.start < $1.start })
    }

    static func formatSingleSpeaker(_ results: [TranscriptionResult]) -> String {
        results.map(\.text)
            .map(stripWhisperTokens)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Belt-and-braces cleanup for Whisper special tokens like
    /// `<|startoftranscript|>`, `<|sv|>`, `<|transcribe|>`, and
    /// timestamp markers like `<|12.48|>`. With
    /// `DecodingOptions(skipSpecialTokens: true)` these shouldn't
    /// appear, but WhisperKit occasionally leaves fragments for some
    /// language / model combos — strip them defensively.
    static func stripWhisperTokens(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(
            of: #"<\|[^|<>]*\|>"#,
            with: " ",
            options: .regularExpression
        )
        return cleaned
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func segments(_ results: [TranscriptionResult], as speaker: Speaker) -> [SpeakerLine] {
        results.flatMap { result in
            result.segments.map { seg in
                SpeakerLine(
                    speaker: speaker,
                    start: seg.start,
                    end: seg.end,
                    text: stripWhisperTokens(seg.text)
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
        var currentEnd: Float = 0
        var currentText = ""

        func flush() {
            guard let s = currentSpeaker, !currentText.isEmpty else { return }
            blocks.append("**\(s.label)** [\(timeLabel(currentStart))–\(timeLabel(currentEnd))] \(currentText)")
        }

        for line in lines {
            if line.speaker == currentSpeaker {
                currentText += " " + line.text
                currentEnd = max(currentEnd, line.end)
            } else {
                flush()
                currentSpeaker = line.speaker
                currentStart = line.start
                currentEnd = line.end
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
