import Foundation
import WhisperKit

/// マイク入力をリアルタイムに文字起こしするストリーミング処理。
///
/// WhisperKit 組み込みの `AudioStreamTranscriber` は録音音声を録音開始から全部ためcontinueし、
/// 毎ループ全体を再処理するため、長く喋るほど1回の処理が重くなり追従できなくなる。
/// ここでは自前ループにし、確定済みセグメントの終端で音声バッファを切り捨てる
/// （スライディングウィンドウ）ことで、何分喋っても1回の処理コストを一定に保つ。
@MainActor
final class StreamingTranscriber {
    private let engine: WhisperEngine
    private let appState: AppState
    private var pipe: WhisperKit?
    private var loopTask: Task<Void, Never>?
    private var isRunning = false

    // MARK: ストリーミング状態

    /// 切り捨て済み（確定）テキスト。再デコード対象から外れた、もう変化しない部分。
    private var committedText = ""
    /// 現在ウィンドウ内で確定したセグメント。
    private var confirmedSegments: [TranscriptionSegment] = []
    /// 現在ウィンドウ内の未確定（末尾・再デコードされうる）セグメント。
    private var unconfirmedSegments: [TranscriptionSegment] = []
    /// 前回処理時点のバッファサンプル数（新規音声量の算出用）。
    private var lastBufferSize = 0
    /// 確定済みセグメントの終端秒（現在バッファ先頭からの相対秒）。デコード開始位置に使う。
    private var lastConfirmedSegmentEndSeconds: Float = 0

    /// 末尾この数だけは未確定として残し、再デコードで補正できるようにする。
    /// 大きいほど毎ループの再処理（末尾の再エンコード/デコード）が増えて遅くなるため 1。
    private let requiredSegmentsForConfirmation = 1
    /// バッファがこの秒数を超えたら、確定済み部分を切り捨ててウィンドウを巻き取る。
    private let maxBufferSeconds: Float = 20
    private let sampleRate = Float(WhisperKit.sampleRate)

    init(engine: WhisperEngine, appState: AppState) async {
        self.engine = engine
        self.appState = appState
    }

    func start() async throws {
        let pipe = try await engine.require()
        guard pipe.tokenizer != nil else {
            throw TranscriberError.tokenizerMissing
        }
        guard await AudioProcessor.requestRecordPermission() else {
            throw TranscriberError.microphonePermissionDenied
        }

        resetState()
        isRunning = true
        self.pipe = pipe

        // ライブ録音開始（audioProcessor.audioSamples に随時たまっていく）。
        try pipe.audioProcessor.startRecordingLive(inputDeviceID: nil, callback: nil)

        loopTask = Task { [weak self] in
            await self?.realtimeLoop()
        }
    }

    func stop() async -> String {
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
        pipe?.audioProcessor.stopRecording()
        let result = assembledText().trimmingCharacters(in: .whitespacesAndNewlines)
        pipe = nil
        return result
    }

    // MARK: - リアルタイムループ

    private func realtimeLoop() async {
        guard let pipe else { return }
        while isRunning {
            updateEnergy(pipe)
            do {
                try await transcribeStep(pipe)
            } catch is CancellationError {
                break
            } catch {
                // 以前はエラーを握り潰してループを抜けるだけで、録音中のまま固まっていた。
                // ここで停止し、エラー表示に復帰させる。
                pipe.audioProcessor.stopRecording()
                isRunning = false
                appState.phase = .error(message: "文字起こしエラー: \(error.localizedDescription)")
                break
            }
        }
    }

    private func transcribeStep(_ pipe: WhisperKit) async throws {
        let currentBuffer = pipe.audioProcessor.audioSamples

        // 新規に1秒以上たまってから処理（細かすぎる再処理を避ける）。
        let nextBufferSize = currentBuffer.count - lastBufferSize
        let nextBufferSeconds = Float(nextBufferSize) / sampleRate
        guard nextBufferSeconds > 1.0 else {
            try await Task.sleep(nanoseconds: 100_000_000)
            return
        }
        lastBufferSize = currentBuffer.count

        var options = DecodingPresets.japanese(noSpeechThreshold: Settings.shared.noSpeechThreshold)
        // 確定済み部分はデコードし直さない（速度と確定テキストの安定のため）。
        options.clipTimestamps = [lastConfirmedSegmentEndSeconds]

        let results: [TranscriptionResult] = try await pipe.transcribe(
            audioArray: Array(currentBuffer),
            decodeOptions: options
        )
        guard isRunning else { return }

        let segments = results.flatMap(\.segments)
        updateSegments(segments)
        updateDisplayText()
        slideWindowIfNeeded(pipe, bufferCount: currentBuffer.count)
    }

    /// セグメントを確定/未確定に振り分ける（WhisperKit 標準と同じロジック）。
    private func updateSegments(_ segments: [TranscriptionSegment]) {
        guard segments.count > requiredSegmentsForConfirmation else {
            unconfirmedSegments = segments
            return
        }
        let confirmCount = segments.count - requiredSegmentsForConfirmation
        let newlyConfirmed = Array(segments.prefix(confirmCount))
        let remaining = Array(segments.suffix(requiredSegmentsForConfirmation))

        if let last = newlyConfirmed.last, last.end > lastConfirmedSegmentEndSeconds {
            lastConfirmedSegmentEndSeconds = last.end
            for segment in newlyConfirmed where !confirmedSegments.contains(segment) {
                confirmedSegments.append(segment)
            }
        }
        unconfirmedSegments = remaining
    }

    /// バッファが長くなりすぎたら、確定済みセグメントの終端で音声を切り捨てる。
    /// 切り捨て分のテキストは committedText に退避するので、表示・コピー内容は失われない。
    private func slideWindowIfNeeded(_ pipe: WhisperKit, bufferCount: Int) {
        let bufferSeconds = Float(bufferCount) / sampleRate
        guard bufferSeconds > maxBufferSeconds, lastConfirmedSegmentEndSeconds > 1.0 else { return }

        // 確定済みウィンドウテキストを凍結。
        committedText += confirmedSegments.map(\.text).joined()

        // 確定済みの音声（先頭〜確定終端）だけを破棄し、未確定の末尾＋transcribe中に
        // 録音された新規音声は必ず残す。purge は「現在の」バッファ長を基準に計算しないと、
        // transcribe 中に増えた未処理音声まで前から削ってしまい、発話がスキップされる。
        let cutSamples = min(Int(lastConfirmedSegmentEndSeconds * sampleRate), bufferCount)
        let liveCount = pipe.audioProcessor.audioSamples.count
        let keep = max(0, liveCount - cutSamples)
        pipe.audioProcessor.purgeAudioSamples(keepingLast: keep)

        // 先頭から cutSamples 分だけ巻き取ったので、処理済みマーカーも同じだけ前へずらす。
        lastBufferSize = max(0, bufferCount - cutSamples)
        lastConfirmedSegmentEndSeconds = 0
        confirmedSegments = []
        // unconfirmedSegments は次回 transcribe で残り音声から再生成されるまで表示継続。
    }

    private func updateEnergy(_ pipe: WhisperKit) {
        let energy = pipe.audioProcessor.relativeEnergy
        guard !energy.isEmpty else { return }
        let trimmed = Array(energy.suffix(120))
        if appState.bufferEnergy != trimmed {
            appState.bufferEnergy = trimmed
        }
    }

    private func updateDisplayText() {
        let text = assembledText().trimmingCharacters(in: .whitespacesAndNewlines)
        if appState.currentText != text {
            appState.currentText = text
        }
    }

    /// 確定済み + 現在ウィンドウのテキストを連結（生のセグメント間スペースを保持）。
    private func assembledText() -> String {
        committedText + (confirmedSegments + unconfirmedSegments).map(\.text).joined()
    }

    private func resetState() {
        committedText = ""
        confirmedSegments = []
        unconfirmedSegments = []
        lastBufferSize = 0
        lastConfirmedSegmentEndSeconds = 0
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
