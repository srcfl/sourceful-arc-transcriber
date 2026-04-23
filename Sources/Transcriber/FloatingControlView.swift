import SwiftUI
import AppKit

struct FloatingControlView: View {
    @ObservedObject var state: RecordingState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            if showLiveText {
                Divider()
                Text(state.liveText)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .animation(nil, value: state.liveText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 280)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.2), value: showLiveText)
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Button(action: state.onToggle) {
                Image(systemName: iconName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(state.isTranscribing)
            .help(state.isRecording ? "Stop recording" : "Start recording")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(primaryLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    if showMeters {
                        LevelMeterView(level: state.micLevel, tint: .yellow)
                            .help("Your microphone")
                        LevelMeterView(level: state.systemLevel, tint: .purple)
                            .help("System audio (other participants)")
                    }
                }
                if let secondary = secondaryLabel {
                    Text(secondary)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button("Show Transcriptions…") { state.onShowTranscripts() }
                Divider()
                Button("Quit Transcriber") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var iconName: String {
        if state.isTranscribing { return "waveform.badge.magnifyingglass" }
        return state.isRecording ? "stop.circle.fill" : "record.circle"
    }

    private var iconColor: Color {
        if state.isTranscribing { return .secondary }
        return state.isRecording ? .red : .primary
    }

    private var primaryLabel: String {
        if state.isTranscribing { return "Transcribing…" }
        return state.isRecording ? "Recording" : "Transcriber"
    }

    private var secondaryLabel: String? {
        state.status == primaryLabel ? nil : state.status
    }

    private var showMeters: Bool {
        state.isRecording || state.isTranscribing
    }

    private var showLiveText: Bool {
        state.isRecording && !state.liveText.isEmpty
    }
}

struct LevelMeterView: View {
    let level: Float     // 0…1
    let tint: Color

    private let multipliers: [CGFloat] = [0.55, 1.0, 0.7]
    private let minBar: CGFloat = 3
    private let maxBar: CGFloat = 14

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(multipliers.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(tint.opacity(0.35 + Double(level) * 0.65))
                    .frame(width: 2.5, height: height(for: i))
            }
        }
        .frame(width: 14, height: maxBar)
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private func height(for index: Int) -> CGFloat {
        let h = minBar + CGFloat(level) * multipliers[index] * (maxBar - minBar)
        return min(maxBar, max(minBar, h))
    }
}
