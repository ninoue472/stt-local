import Foundation
import WhisperKit

@MainActor
final class StreamingTranscriber {
    private let engine: WhisperEngine
    private let appState: AppState
    private var transcriber: AudioStreamTranscriber?
    private let waitingPlaceholder = "Waiting for speech..."
    /// 録音中フラグ。停止後に遅延到着したコールバックが確定テキストを上書きするのを防ぐ。
    private var isRunning = false

    init(engine: WhisperEngine, appState: AppState) async {
        self.engine = engine
        self.appState = appState
    }

    func start() async throws {
        let pipe = try await engine.require()
        guard let tokenizer = pipe.tokenizer else {
            throw TranscriberError.tokenizerMissing
        }
        guard await AudioProcessor.requestRecordPermission() else {
            throw TranscriberError.microphonePermissionDenied
        }

        let options = DecodingPresets.japanese(noSpeechThreshold: Settings.shared.noSpeechThreshold)

        let callback: AudioStreamTranscriberCallback = { [weak self] _, newState in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                let appState = self.appState

                // テキストが実際に変わったときだけ書き込む（@Observable は等値判定をしないため、
                // 同じ値の代入でも再描画・パネル再計算が走ってしまう）。
                let text = self.presentableText(from: newState, previous: appState.currentText)
                if appState.currentText != text {
                    appState.currentText = text
                }

                let energy = newState.bufferEnergy
                if !energy.isEmpty {
                    appState.bufferEnergy = Array(energy.suffix(120))
                }
            }
        }
        isRunning = true

        let t = AudioStreamTranscriber(
            audioEncoder: pipe.audioEncoder,
            featureExtractor: pipe.featureExtractor,
            segmentSeeker: pipe.segmentSeeker,
            textDecoder: pipe.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: pipe.audioProcessor,
            decodingOptions: options,
            // 1 にすると末尾1セグメントだけ未確定として再デコードし、それ以前は確定。
            // これでデコード開始位置(clipTimestamps)が前進し、毎ループ全体を再処理する遅延を防ぐ。
            requiredSegmentsForConfirmation: 1,
            silenceThreshold: 0.3,
            compressionCheckWindow: 60,
            useVAD: false,
            stateChangeCallback: callback
        )
        self.transcriber = t
        try await t.startStreamTranscription()
    }

    func stop() async -> String {
        guard let t = transcriber else { return appState.currentText }
        // 先にフラグを下ろし、以降に到着するコールバックの書き込みを止める。
        isRunning = false
        await t.stopStreamTranscription()
        let result = sanitizedTranscript(appState.currentText)
        self.transcriber = nil
        return result
    }

    private func sanitizedTranscript(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != waitingPlaceholder else { return "" }
        return trimmed
    }

    private func presentableText(from state: AudioStreamTranscriber.State, previous: String) -> String {
        let segmentText = (state.confirmedSegments + state.unconfirmedSegments)
            .map(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !segmentText.isEmpty {
            return segmentText
        }

        let current = sanitizedTranscript(state.currentText)
        if !current.isEmpty {
            return current
        }

        return previous
    }

    enum TranscriberError: Error, LocalizedError {
        case tokenizerMissing
        case microphonePermissionDenied

        var errorDescription: String? {
            switch self {
            case .tokenizerMissing:
                return "Whisper tokenizer not loaded"
            case .microphonePermissionDenied:
                return "マイク権限がありません。システム設定 > プライバシーとセキュリティ > マイク で STTLocalApp を許可してください"
            }
        }
    }
}
