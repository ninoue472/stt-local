import Foundation
import WhisperKit

private final class LiveAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive = false
    private var samples: ContiguousArray<Float> = []

    func activate() {
        lock.lock()
        defer { lock.unlock() }
        isActive = true
        samples.removeAll(keepingCapacity: true)
    }

    func deactivate() {
        lock.lock()
        defer { lock.unlock() }
        isActive = false
        samples.removeAll(keepingCapacity: true)
    }

    func append(_ buffer: [Float]) {
        guard !buffer.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return }
        samples.append(contentsOf: buffer)
    }

    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return [] }
        return Array(samples)
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return 0 }
        return samples.count
    }

    func purgeKeepingLast(_ keep: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return }
        if samples.count > keep {
            samples.removeFirst(samples.count - keep)
        }
    }
}

/// マイク入力をリアルタイムに文字起こしするストリーミング処理。
///
/// WhisperKit 組み込みの `AudioStreamTranscriber` は録音音声を録音開始から全部ためcontinueし、
/// 毎ループ全体を再処理するため、長く喋るほど1回の処理が重くなり追従できなくなる。
/// ここでは自前ループにし、確定済みセグメントの終端で音声バッファを切り捨てる
/// （スライディングウィンドウ）ことで、何分喋っても1回の処理コストを一定に保つ。
actor StreamingTranscriber {
    private let engine: WhisperEngine
    private let appState: AppState
    // WhisperKit AudioProcessor は audioSamples/audioEnergy を通常の可変配列として持ち、
    // append/read/purge の排他保証を公開していない。actor 側はそれらに触らず、タップコールバックで
    // 到着した生PCMだけをこの同期付きミラーバッファへ集約して read/purge する。
    private let liveAudioBuffer = LiveAudioBuffer()
    private var pipe: WhisperKit?
    private var loopTask: Task<Void, Never>?
    private var isRunning = false
    private var runtimeSettings: WhisperRuntimeSettingsSnapshot?

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
    /// 推論で処理する窓の上限秒。これを超えたら確定境界の手前でスライドする。
    /// 小さいほどエンコーダ処理量が減り 1 回の推論が軽くなる（リアルタイム性向上）。
    /// docs/plan/realtime-short-window.md
    private let maxWindowSeconds: Float = 5.0
    /// 窓のハードキャップ。連続発話で Whisper が 1 セグメントしか返さず確定が進まないまま窓が
    /// この秒数を超えたら、最後のセグメントも確定へ昇格させて窓を必ず頭打ちにする（decode 詰まり防止）。
    private let hardCapSeconds: Float = 10.0
    /// スライド時に確定境界の手前へ音響文脈として残す秒数。窓境界での単語切れを防ぐ
    /// （エンコーダに左文脈を与える）。デコード開始位置はこの分だけ後ろへずらし二重出力を防ぐ。
    private let overlapSeconds: Float = 1.0
    /// 新規音声がこの秒数たまってから再文字起こしする。大きいほど推論頻度が下がり軽くなる
    /// （CPU 負荷とバックログが減る）が、ライブ表示の更新が粗くなる。最終テキストは不変。
    /// 定常値は 1.5s 固定。録音開始直後だけ先頭エッジ短縮を使い、初回確定後または 1.5s 到達で復帰する。
    private let steadyMinNewAudioSeconds: Float = 1.5
    private let initialMinNewAudioSeconds: Float = 0.7
    private let sampleRate = Float(WhisperKit.sampleRate)
    // WhisperKit の relativeEnergy は audioEnergy（直近 20 バッファ程度の履歴）を読むため、
    // audioSamples は波形用途では保持不要。数秒だけ残し、しきい値超過時だけまとめて purge する。
    private let audioProcessorPurgeKeepSamples = 3 * WhisperKit.sampleRate
    private let audioProcessorPurgeThresholdSamples = 6 * WhisperKit.sampleRate
    private var usesShortInitialBudget = true

    init(engine: WhisperEngine, appState: AppState) async {
        self.engine = engine
        self.appState = appState
    }

    func start(runtimeSettings: WhisperRuntimeSettingsSnapshot) async throws {
        let pipe = try await engine.require()
        guard pipe.tokenizer != nil else {
            throw TranscriberError.tokenizerMissing
        }
        guard await AudioProcessor.requestRecordPermission() else {
            throw TranscriberError.microphonePermissionDenied
        }

        resetState()
        liveAudioBuffer.activate()
        self.runtimeSettings = runtimeSettings
        isRunning = true
        self.pipe = pipe

        // 入力モニタ（波形）を録音開始の瞬間から表示する。データ到来前でもベースラインを見せ、
        // 「マイクが生きている」ことをユーザーに即座に伝える。
        await MainActor.run { [appState] in
            appState.bufferEnergy = [0]
        }

        do {
            let liveAudioBuffer = self.liveAudioBuffer
            // 波形は「入力モニタ」。文字起こし（重く間欠的）とは目的が別なので、録音タップの
            // コールバック（音声到来の瞬間にオーディオスレッドで発火）から直接駆動する。
            // AudioProcessor.audioSamples には actor から触らず、到着PCMを自前バッファへミラーして
            // 推論用の read/purge を分離することで append との競合を避ける。
            let audioProcessorPurgeKeepSamples = self.audioProcessorPurgeKeepSamples
            let audioProcessorPurgeThresholdSamples = self.audioProcessorPurgeThresholdSamples
            try pipe.audioProcessor.startRecordingLive(
                inputDeviceID: nil
            ) { [weak self, weak pipe, liveAudioBuffer] buffer in
                // オーディオスレッド。processBuffer が直前に audioSamples/audioEnergy を更新済み。
                liveAudioBuffer.append(buffer)
                guard let pipe else { return }
                let audioProcessor = pipe.audioProcessor
                if audioProcessor.audioSamples.count > audioProcessorPurgeThresholdSamples {
                    audioProcessor.purgeAudioSamples(keepingLast: audioProcessorPurgeKeepSamples)
                }
                let energy = audioProcessor.relativeEnergy
                Task {
                    await self?.applyEnergy(energy)
                }
            }
        } catch {
            isRunning = false
            self.pipe = nil
            self.runtimeSettings = nil
            liveAudioBuffer.deactivate()
            pipe.audioProcessor.stopRecording()
            throw error
        }

        loopTask = Task { [weak self] in
            await self?.realtimeLoop()
        }
    }

    func stop() async -> String {
        isRunning = false
        runtimeSettings = nil
        liveAudioBuffer.deactivate()
        await setInferring(false)
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
            do {
                try await transcribeStep(pipe)
            } catch is CancellationError {
                break
            } catch {
                // 以前はエラーを握り潰してループを抜けるだけで、録音中のまま固まっていた。
                // ここで停止し、エラー表示に復帰させる。
                pipe.audioProcessor.stopRecording()
                isRunning = false
                await setInferring(false)
                await MainActor.run { [appState] in
                    appState.phase = .error(message: "文字起こしエラー: \(error.localizedDescription)")
                }
                break
            }
        }
    }

    private func transcribeStep(_ pipe: WhisperKit) async throws {
        guard let runtimeSettings else { return }
        let currentBuffer = liveAudioBuffer.snapshot()

        // 新規に一定量たまってから処理（細かすぎる再処理を避け、推論頻度を抑える）。
        let nextBufferSize = currentBuffer.count - lastBufferSize
        let nextBufferSeconds = Float(nextBufferSize) / sampleRate
        let minNewAudioSeconds = currentMinNewAudioSeconds()
        guard nextBufferSeconds > minNewAudioSeconds else {
            try await Task.sleep(nanoseconds: 100_000_000)
            return
        }
        lastBufferSize = currentBuffer.count

        var options = DecodingPresets.streaming(
            language: runtimeSettings.language,
            noSpeechThreshold: runtimeSettings.noSpeechThreshold
        )
        // 確定済み部分はデコードし直さない（速度と確定テキストの安定のため）。
        options.clipTimestamps = [lastConfirmedSegmentEndSeconds]

        await setInferring(true)
        let results: [TranscriptionResult]
        do {
            results = try await pipe.transcribe(
                audioArray: currentBuffer,
                decodeOptions: options
            )
        } catch {
            await setInferring(false)
            throw error
        }
        await setInferring(false)
        guard isRunning else { return }

        // 無音ハルシネーション（「ありがとうございます」等）の定型句を、低確信度時のみ除去する。
        // 音声パイプラインのタイミングには一切影響しない純粋なポストフィルタ。
        let rawSegments = results.flatMap(\.segments)
        let segments = runtimeSettings.language == "ja" ? HallucinationFilter.filter(rawSegments) : rawSegments
        updateSegments(segments)
        if usesShortInitialBudget, shouldRestoreSteadyBudget(bufferCount: currentBuffer.count) {
            usesShortInitialBudget = false
        }
        let confirmedEndForLog = lastConfirmedSegmentEndSeconds
        let slid = slideWindowIfNeeded(bufferCount: currentBuffer.count)

        // 【診断】推論コストの実測ログ。encode が支配項か／再推論間隔(budget)に対し飽和しているかを
        // 切り分ける用。pipeline > budget なら追従できずバックログが溜まる。不要になれば本ブロック削除。
        // docs/plan/realtime-short-window.md
        if let t = results.first?.timings {
            let encodeMs = Int((t.encoding * 1000).rounded())
            let logmelMs = Int((t.logmels * 1000).rounded())
            let decodeMs = Int((t.decodingLoop * 1000).rounded())
            let pipelineMs = Int((t.fullPipeline * 1000).rounded())
            print("[STT/timings] audioIn=\(String(format: "%.1f", t.inputAudioSeconds))s "
                + "logmel=\(logmelMs)ms encode=\(encodeMs)ms decode=\(decodeMs)ms pipeline=\(pipelineMs)ms "
                + "encRuns=\(Int(t.totalEncodingRuns)) budget=\(minNewAudioSeconds)s "
                + "confirmedEnd=\(String(format: "%.1f", confirmedEndForLog))s slid=\(slid)")
        }

        await updateDisplayTexts()
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

    /// 窓が長くなりすぎたら、必要に応じて先頭の未確定セグメントを丸ごと確定へ昇格させてから、
    /// 既存の確定境界スライドで縮める。セグメント途中では切らない。
    /// 切り捨て分のテキストは committedText に退避するので、表示・コピー内容は失われない。
    /// 直近 ~maxWindowSeconds を保ち、連続発話でも 1 回の推論を軽くする。
    /// docs/plan/realtime-short-window.md
    private func slideWindowIfNeeded(bufferCount: Int) -> Bool {
        let bufferSeconds = Float(bufferCount) / sampleRate
        guard bufferSeconds > maxWindowSeconds else { return false }
        let requiredCutSeconds = bufferSeconds - maxWindowSeconds
        let needConfirmEnd = requiredCutSeconds + overlapSeconds

        // 後続セグメントがある（=境界が安定した）ものだけ確定へ昇格。最後の1つは必ず未確定で残し、
        // 次回デコードで再生成させる（継ぎ目の単語落ちを防ぐ。元の自然確定と同じ無損失原理）。
        // ただし窓が hardCapSeconds を超えたら（連続発話で Whisper が 1 セグメントしか返さず確定が
        // 進まないまま窓が暴走する稀ケース）、最後の 1 つも昇格可にして窓を必ず頭打ちにする。
        // この場合のみ継ぎ目リスクが極小残るが、巨大窓での decode 詰まりを構造的に防ぐ（段階デグレード）。
        let minUnconfirmedToKeep = bufferSeconds > hardCapSeconds ? 0 : 1
        while lastConfirmedSegmentEndSeconds < needConfirmEnd, unconfirmedSegments.count > minUnconfirmedToKeep {
            let first = unconfirmedSegments.removeFirst()
            if !confirmedSegments.contains(first) {
                confirmedSegments.append(first)
            }
            lastConfirmedSegmentEndSeconds = first.end
        }

        // ここから先は既存の確定境界スライドのみを使う。overlap を確保できなければ切らない。
        guard lastConfirmedSegmentEndSeconds > overlapSeconds else { return false }

        // 確定済みウィンドウテキストを凍結。
        committedText += confirmedSegments.map(\.text).joined()

        // 確定境界の overlapSeconds 手前までを破棄し、オーバーラップ＋未確定の末尾＋transcribe中に
        // 録音された新規音声は必ず残す。liveAudioBuffer は callback 側 append と actor 側 purge を
        // 同一ロックで直列化する。purge は「現在の」バッファ長を基準に計算しないと、transcribe 中に
        // 増えた未処理音声まで前から削ってしまい、発話がスキップされる。
        let cutSeconds = lastConfirmedSegmentEndSeconds - overlapSeconds
        let cutSamples = min(Int(cutSeconds * sampleRate), bufferCount)
        let liveCount = liveAudioBuffer.count()
        let keep = max(0, liveCount - cutSamples)
        liveAudioBuffer.purgeKeepingLast(keep)

        // 先頭から cutSamples 分だけ巻き取ったので、処理済みマーカーも同じだけ前へずらす。
        lastBufferSize = max(0, bufferCount - cutSamples)
        // 残したオーバーラップ分はエンコーダの左文脈に使うだけで、デコードはし直さない（二重出力防止）。
        lastConfirmedSegmentEndSeconds = overlapSeconds
        confirmedSegments = []
        return true
    }

    /// 録音タップのコールバックから渡された入力エネルギーを波形へ反映する。
    private func applyEnergy(_ energy: [Float]) async {
        guard isRunning, !energy.isEmpty else { return }
        let trimmed = Array(energy.suffix(120))
        await MainActor.run { [appState] in
            if appState.bufferEnergy != trimmed {
                appState.bufferEnergy = trimmed
            }
        }
    }

    private func updateDisplayTexts() async {
        let confirmedText = committedText + confirmedSegments.map(\.text).joined()
        let unconfirmedText = unconfirmedSegments.map(\.text).joined()
        await MainActor.run { [appState] in
            if appState.confirmedText != confirmedText {
                appState.confirmedText = confirmedText
            }
            if appState.unconfirmedText != unconfirmedText {
                appState.unconfirmedText = unconfirmedText
            }
        }
    }

    private func setInferring(_ value: Bool) async {
        await MainActor.run { [appState] in
            if appState.isInferring != value {
                appState.isInferring = value
            }
        }
    }

    /// 確定済み + 現在ウィンドウのテキストを連結（生のセグメント間スペースを保持）。
    private func assembledText() -> String {
        committedText + (confirmedSegments + unconfirmedSegments).map(\.text).joined()
    }

    private func currentMinNewAudioSeconds() -> Float {
        usesShortInitialBudget ? initialMinNewAudioSeconds : steadyMinNewAudioSeconds
    }

    private func shouldRestoreSteadyBudget(bufferCount: Int) -> Bool {
        if lastConfirmedSegmentEndSeconds > 0 {
            return true
        }
        let bufferedSeconds = Float(bufferCount) / sampleRate
        return bufferedSeconds >= steadyMinNewAudioSeconds
    }

    private func resetState() {
        committedText = ""
        confirmedSegments = []
        unconfirmedSegments = []
        lastBufferSize = 0
        lastConfirmedSegmentEndSeconds = 0
        usesShortInitialBudget = true
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
