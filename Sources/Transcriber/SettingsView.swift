import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var arcAuth: ArcAuthStore

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
                Picker("Environment", selection: $settings.arcEnvironment) {
                    ForEach(ArcEnvironment.allCases) { env in
                        Text(env.label).tag(env.rawValue)
                    }
                }
                .disabled(arcAuth.isSignedIn)
                .help(arcAuth.isSignedIn ? "Sign out to change the Arc environment." : "")

                if settings.arcEnvironment == ArcEnvironment.other.rawValue {
                    TextField("Custom base URL", text: $settings.arcBaseURL)
                        .disabled(arcAuth.isSignedIn)
                } else if let url = settings.arcWebURL {
                    Text(url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if arcAuth.isSignedIn {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Signed in")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(arcAuth.userEmail ?? "(unknown account)")
                                .font(.callout)
                        }
                        Spacer()
                        Button("Sign out", role: .destructive) {
                            arcAuth.signOut()
                        }
                    }

                    Divider()

                    Picker("Upload mode", selection: $settings.arcUploadMode) {
                        ForEach(UploadMode.allCases) { m in
                            Text(m.label).tag(m.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    Text(uploadModeHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button("Sign in to Arc") {
                        openArcAuthorize()
                    }
                    .disabled(settings.arcWebURL == nil)
                    Text("Opens Arc in your browser to authorize this app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 500)
        .padding(.top, 8)
    }

    private var uploadModeHelp: String {
        switch UploadMode(rawValue: settings.arcUploadMode) ?? .inbox {
        case .inbox:
            return "Transcripts appear in your personal Arc inbox. Link them to a project or site from there."
        case .ask:
            return "After each recording, pick the project — or send it to your inbox to triage later."
        case .skip:
            return "Transcripts stay on this Mac. Upload manually from the transcripts window (soon)."
        }
    }

    private func openArcAuthorize() {
        guard let base = settings.arcWebURL else { return }
        let target = base.appendingPathComponent("authorize-desktop")
        NSWorkspace.shared.open(target)
    }
}

