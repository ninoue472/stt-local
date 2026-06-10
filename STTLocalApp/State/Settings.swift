import Foundation

struct WhisperRuntimeSettingsSnapshot: Sendable {
    let modelName: String
    let language: String
    let noSpeechThreshold: Float
}

final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard
    private static let defaultModelName = "openai_whisper-large-v3_turbo_954MB"

    private enum Keys {
        static let modelName = "stt.modelName"
        static let noSpeechThreshold = "stt.noSpeechThreshold"
        static let silenceThreshold = "stt.silenceThreshold"
        static let language = "stt.language"
    }

    var modelName: String {
        get {
            let stored = defaults.string(forKey: Keys.modelName) ?? Self.defaultModelName
            let normalized = normalizeModelName(stored)
            if normalized != stored {
                defaults.set(normalized, forKey: Keys.modelName)
            }
            return normalized
        }
        set { defaults.set(newValue, forKey: Keys.modelName) }
    }

    var noSpeechThreshold: Float {
        get {
            if defaults.object(forKey: Keys.noSpeechThreshold) == nil { return 0.6 }
            return defaults.float(forKey: Keys.noSpeechThreshold)
        }
        set { defaults.set(newValue, forKey: Keys.noSpeechThreshold) }
    }

    var silenceThreshold: Float {
        get {
            if defaults.object(forKey: Keys.silenceThreshold) == nil { return 0.3 }
            return defaults.float(forKey: Keys.silenceThreshold)
        }
        set { defaults.set(newValue, forKey: Keys.silenceThreshold) }
    }

    var language: String {
        get { defaults.string(forKey: Keys.language) ?? "ja" }
        set { defaults.set(newValue, forKey: Keys.language) }
    }

    @MainActor
    func makeWhisperRuntimeSettingsSnapshot() -> WhisperRuntimeSettingsSnapshot {
        WhisperRuntimeSettingsSnapshot(
            modelName: modelName,
            language: language,
            noSpeechThreshold: noSpeechThreshold
        )
    }

    private func normalizeModelName(_ modelName: String) -> String {
        switch modelName {
        case "openai_whisper-large-v3-turbo":
            return "openai_whisper-large-v3_turbo"
        case "large-v3-turbo":
            return "large-v3_turbo"
        default:
            return modelName
        }
    }
}
