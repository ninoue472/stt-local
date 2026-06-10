import Foundation
import WhisperKit
import CoreML

actor WhisperEngine {
    private(set) var pipe: WhisperKit?

    func load(modelName: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let modelsRoot = try modelStorageURL()
        try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)

        progress(0.05)

        let computeOptions = ModelComputeOptions(
            audioEncoderCompute: .cpuAndNeuralEngine,
            textDecoderCompute: .cpuAndNeuralEngine
        )

        let config: WhisperKitConfig
        if let localModelFolder = existingLocalModelFolder(named: modelName, under: modelsRoot) {
            config = WhisperKitConfig(
                model: modelName,
                // downloadBase を渡すと tokenizerFolder = downloadBase となり、tokenizer を
                // キャッシュ（modelsRoot/models/openai/whisper-large-v3）からオフライン解決できる。
                // これを省くと tokenizer が見つからず毎回 Hub から取得しに行く。
                downloadBase: modelsRoot,
                modelFolder: localModelFolder.path,
                computeOptions: computeOptions,
                verbose: false,
                prewarm: true,
                load: true,
                download: false
            )
        } else {
            config = WhisperKitConfig(
                model: modelName,
                downloadBase: modelsRoot,
                computeOptions: computeOptions,
                verbose: false,
                prewarm: true,
                load: true,
                download: true
            )
        }

        let pipe = try await WhisperKit(config)
        self.pipe = pipe

        progress(1.0)
    }

    func require() throws -> WhisperKit {
        guard let pipe else { throw EngineError.notLoaded }
        return pipe
    }

    func warmupTranscription(
        language: String,
        noSpeechThreshold: Float,
        durationSeconds: Double = 1.0
    ) async throws {
        let pipe = try require()
        let sampleCount = max(1, Int(durationSeconds * Double(WhisperKit.sampleRate)))
        let silence = [Float](repeating: 0, count: sampleCount)
        let options = DecodingPresets.streaming(
            language: language,
            noSpeechThreshold: noSpeechThreshold
        )
        _ = try await pipe.transcribe(audioArray: silence, decodeOptions: options)
    }

    private func modelStorageURL() throws -> URL {
        let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return appSupport
            .appendingPathComponent("STTLocalApp", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    /// モデルが既にローカルへ用意済みか（= ダウンロード不要か）。
    func isModelCached(modelName: String) -> Bool {
        guard let modelsRoot = try? modelStorageURL() else { return false }
        return existingLocalModelFolder(named: modelName, under: modelsRoot) != nil
    }

    private func existingLocalModelFolder(named modelName: String, under modelsRoot: URL) -> URL? {
        let candidates = [
            // WhisperKit は downloadBase 配下の "models/argmaxinc/whisperkit-coreml/<model>" へ
            // モデルを保存する。既存キャッシュはここに入るため最優先で確認する。これを見ないと
            // 毎回ダウンロード経路へ入り、「初回のみ」のはずの DL が毎回走ってしまう。
            modelsRoot
                .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
                .appendingPathComponent(modelName, isDirectory: true),
            modelsRoot.appendingPathComponent(modelName, isDirectory: true),
            modelsRoot
        ]

        return candidates.first(where: hasRequiredModelFiles(in:))
    }

    private func hasRequiredModelFiles(in folder: URL) -> Bool {
        let requiredModelNames = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
        return requiredModelNames.allSatisfy { modelName in
            let modelURL = ModelUtilities.detectModelURL(inFolder: folder, named: modelName)
            return FileManager.default.fileExists(atPath: modelURL.path)
        }
    }

    enum EngineError: Error, LocalizedError {
        case notLoaded
        var errorDescription: String? { "Whisperモデルが読み込まれていません" }
    }
}
