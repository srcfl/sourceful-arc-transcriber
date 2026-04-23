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

enum ArcEnvironment: String, CaseIterable, Identifiable {
    case mainnet
    case testnet
    case devnet
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mainnet: return "Mainnet (production)"
        case .testnet: return "Testnet"
        case .devnet:  return "Devnet"
        case .other:   return "Other (custom URL)"
        }
    }

    /// The URL the user would open in a browser. `nil` for `.other`
    /// means "use the user-entered `arcBaseURL` as-is".
    var baseURL: String? {
        switch self {
        case .mainnet: return "https://arc.sourceful.energy"
        case .testnet: return "https://novacore-testnet.sourceful.dev/applications/arc"
        case .devnet:  return "https://novacore-devnet.sourceful.dev/applications/arc"
        case .other:   return nil
        }
    }
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
    @Published var arcEnvironment: String    { didSet { defaults.set(arcEnvironment,     forKey: K.arcEnv) } }
    @Published var arcBaseURL: String        { didSet { defaults.set(arcBaseURL,          forKey: K.arcBase) } }
    @Published var arcUploadMode: String     { didSet { defaults.set(arcUploadMode,       forKey: K.arcMode) } }

    private enum K {
        static let model       = "model"
        static let language    = "language"
        static let live        = "liveTranscription"
        static let diarize     = "speakerDiarization"
        static let keepAudio   = "keepAudioFiles"
        static let arcEnv      = "arcEnvironment"
        static let arcBase     = "arcBaseURL"
        static let arcMode     = "arcUploadMode"
    }

    /// Raw base URL — the one the user would open in a browser. For
    /// named environments (mainnet/testnet/devnet) this comes from the
    /// enum; for `.other` it comes from the user-entered `arcBaseURL`.
    private var rawBaseURLString: String {
        let env = ArcEnvironment(rawValue: arcEnvironment) ?? .mainnet
        return env.baseURL ?? arcBaseURL.trimmingCharacters(in: .whitespaces)
    }

    /// URL the browser opens for sign-in / consent.
    var arcWebURL: URL? {
        URL(string: rawBaseURLString)
    }

    /// URL the REST API is served at. In production both web and API
    /// share one hostname behind a reverse proxy, so this is usually
    /// the same as the web URL. In local dev the web is on :3000 and
    /// the API is on :8000, so we swap the port on localhost.
    var arcAPIURL: URL? {
        guard var comps = URLComponents(string: rawBaseURLString) else { return nil }
        if let host = comps.host, host == "localhost" || host == "127.0.0.1" {
            if comps.port == 3000 || comps.port == nil {
                comps.port = 8000
            }
        }
        return comps.url
    }

    private init() {
        let storedBaseURL = defaults.string(forKey: K.arcBase) ?? "http://localhost:3000"

        modelName           = defaults.string(forKey: K.model)      ?? "openai_whisper-large-v3-v20240930_turbo"
        language            = defaults.string(forKey: K.language)   ?? "auto"
        liveTranscription   = defaults.object(forKey: K.live)       as? Bool ?? true
        speakerDiarization  = defaults.object(forKey: K.diarize)    as? Bool ?? true
        keepAudioFiles      = defaults.object(forKey: K.keepAudio)  as? Bool ?? false
        arcBaseURL          = storedBaseURL
        arcUploadMode       = defaults.string(forKey: K.arcMode)    ?? UploadMode.inbox.rawValue

        // Migrate existing installs: if no environment is stored yet,
        // infer it from the existing `arcBaseURL` so users pointing at
        // localhost keep working. New installs default to mainnet.
        let storedEnv = defaults.string(forKey: K.arcEnv).flatMap { ArcEnvironment(rawValue: $0) }
        arcEnvironment = (storedEnv ?? Self.inferEnvironment(fromURL: storedBaseURL)).rawValue
    }

    private static func inferEnvironment(fromURL url: String) -> ArcEnvironment {
        let u = url.trimmingCharacters(in: .whitespaces)
        if u.isEmpty { return .mainnet }
        for env in ArcEnvironment.allCases where env != .other {
            if env.baseURL == u { return env }
        }
        if u.contains("localhost") || u.contains("127.0.0.1") { return .other }
        return .mainnet
    }
}

enum UploadMode: String, CaseIterable, Identifiable {
    case inbox         // upload to user's Arc inbox (no project) — they triage in Arc
    case ask           // show picker after each recording
    case skip          // don't upload (user still signed in, but no auto-upload)

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inbox: return "Upload to my Arc inbox (triage in Arc)"
        case .ask:   return "Ask which project after each recording"
        case .skip:  return "Don't upload automatically"
        }
    }
}
