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

    private func modelStorageURL() throws -> URL {
        let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return appSupport
            .appendingPathComponent("STTLocalApp", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    private func existingLocalModelFolder(named modelName: String, under modelsRoot: URL) -> URL? {
        let candidates = [
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
