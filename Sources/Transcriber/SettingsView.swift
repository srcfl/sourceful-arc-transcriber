import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Model", selection: $settings.modelName) {
                    ForEach(WhisperModelOption.all) { m in
                        Text("\(m.label) — \(m.note)").tag(m.id)
                    }
                }

                Picker("Language", selection: $settings.language) {
                    ForEach(LanguageOption.all) { l in
                        Text(l.label).tag(l.id)
                    }
                }

                Toggle("Live transcription while recording", isOn: $settings.liveTranscription)
                Toggle("Tag speakers (diarization)", isOn: $settings.speakerDiarization)
            }

            Section("Audio files") {
                Toggle("Keep audio files after transcribing", isOn: $settings.keepAudioFiles)
                Text("When off, the raw `.wav` / `.caf` files are deleted after the transcript is saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Arc") {
                Text("Uploading transcripts to your Arc project — coming soon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 380)
        .padding(.top, 8)
    }
}
