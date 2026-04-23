import Foundation
import Combine

struct WhisperModelOption: Identifiable, Hashable {
    let id: String
    let label: String
    let note: String

    static let all: [WhisperModelOption] = [
        .init(id: "openai_whisper-base",                            label: "Base",       note: "smallest, quick drafts"),
        .init(id: "openai_whisper-small",                           label: "Small",      note: "balanced"),
        .init(id: "openai_whisper-large-v3-v20240930_turbo",        label: "Turbo",      note: "recommended"),
        .init(id: "openai_whisper-large-v3",                        label: "Large v3",   note: "best quality, slowest")
    ]

    static func label(for id: String) -> String {
        all.first(where: { $0.id == id })?.label ?? id
    }
}

struct LanguageOption: Identifiable, Hashable {
    let id: String   // "auto" or ISO code
    let label: String

    static let all: [LanguageOption] = [
        .init(id: "auto", label: "Auto-detect"),
        .init(id: "sv",   label: "Swedish"),
        .init(id: "en",   label: "English")
    ]
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var modelName: String { didSet { defaults.set(modelName, forKey: K.model) } }
    @Published var language: String  { didSet { defaults.set(language,  forKey: K.language) } }
    @Published var liveTranscription: Bool   { didSet { defaults.set(liveTranscription,   forKey: K.live) } }
    @Published var speakerDiarization: Bool  { didSet { defaults.set(speakerDiarization,  forKey: K.diarize) } }
    @Published var keepAudioFiles: Bool      { didSet { defaults.set(keepAudioFiles,      forKey: K.keepAudio) } }

    private enum K {
        static let model     = "model"
        static let language  = "language"
        static let live      = "liveTranscription"
        static let diarize   = "speakerDiarization"
        static let keepAudio = "keepAudioFiles"
    }

    private init() {
        modelName          = defaults.string(forKey: K.model)    ?? "openai_whisper-large-v3-v20240930_turbo"
        language           = defaults.string(forKey: K.language) ?? "auto"
        liveTranscription  = defaults.object(forKey: K.live)     as? Bool ?? true
        speakerDiarization = defaults.object(forKey: K.diarize)  as? Bool ?? true
        keepAudioFiles     = defaults.object(forKey: K.keepAudio) as? Bool ?? false
    }
}
