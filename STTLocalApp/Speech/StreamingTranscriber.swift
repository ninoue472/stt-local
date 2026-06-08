import Foundation
import WhisperKit

/// マイク入力をリアルタイムに文字起こしするストリーミング処理。
///
/// WhisperKit 組み込みの `AudioStreamTranscriber` は録音音声を録音開始から全部ためcontinueし、
/// 毎ループ全体を再処理するため、長く喋るほど1回の処理が重くなり追従できなくなる。
/// ここでは自前ループにし、確定済みセグメントの終端で音声バッファを切り捨てる
/// （スライディングウィンドウ）ことで、何分喋っても1回の処理コストを一定に保つ。
actor StreamingTranscriber {
    private let engine: WhisperEngine
    private let appState: AppState
    private var pipe: WhisperKit?
    private var loopTask: Task<Void, Never>?
    private var isRunning = false
    private var language = "ja"

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
    private var minNewAudioSeconds: Float = 2.0
    private var pipelineEMASeconds: Float = 0
    private let budgetFloor: Float = 0.8
    private let budgetCap: Float = 4.0
    private let budgetSafetyFactor: Float = 1.2
    private let emaAlphaUp: Float = 0.5
    private let emaAlphaDown: Float = 0.2
    /// 【診断・暫定】skip 分岐で窓が肥大したまま transcribe が走らない状況を間引いて記録するための counter。
    private var skipDiagCounter = 0
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
        language = Settings.shared.language
        isRunning = true
        self.pipe = pipe

        // 入力モニタ（波形）を録音開始の瞬間から表示する。データ到来前でもベースラインを見せ、
        // 「マイクが生きている」ことをユーザーに即座に伝える。
        await MainActor.run { [appState] in
            appState.bufferEnergy = [0]
        }

        // 波形は「入力モニタ」。文字起こし（重く間欠的）とは目的が別なので、録音タップの
        // コールバック（音声到来の瞬間にオーディオスレッドで発火）から直接駆動する。
        // これにより文字起こしループのスケジューリングや推論の重さに一切依存せず、
        // 喋り始めた瞬間からリアルタイムに追従する。docs/plan/waveform-as-input-monitor.md
        try pipe.audioProcessor.startRecordingLive(inputDeviceID: nil) { [weak self, weak pipe] _ in
            // オーディオスレッド。直前に processBuffer が relativeEnergy を更新済み。
            guard let pipe else { return }
            let energy = pipe.audioProcessor.relativeEnergy
            Task {
                await self?.applyEnergy(energy)
            }
        }

        loopTask = Task { [weak self] in
            await self?.realtimeLoop()
        }
    }

    func stop() async -> String {
        isRunning = false
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
        let currentBuffer = pipe.audioProcessor.audioSamples

        // 新規に一定量たまってから処理（細かすぎる再処理を避け、推論頻度を抑える）。
        let nextBufferSize = currentBuffer.count - lastBufferSize
        let nextBufferSeconds = Float(nextBufferSize) / sampleRate
        guard nextBufferSeconds > minNewAudioSeconds else {
            // 【診断・暫定】窓が maxWindow を超えているのに transcribe が走らない＝skip が続く状況を
            // 約1秒間隔で記録。next が負/極小なら lastBufferSize の desync を疑う。原因特定後に削除。
            let bufSec = Float(currentBuffer.count) / sampleRate
            if bufSec > maxWindowSeconds {
                skipDiagCounter += 1
                if skipDiagCounter % 10 == 0 {
                    print("[STT/diag] SKIP win=\(String(format: "%.1f", bufSec))s "
                        + "lastBuf=\(String(format: "%.1f", Float(lastBufferSize) / sampleRate))s "
                        + "next=\(String(format: "%.1f", nextBufferSeconds))s "
                        + "budget=\(String(format: "%.2f", minNewAudioSeconds))s")
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            return
        }
        skipDiagCounter = 0
        lastBufferSize = currentBuffer.count

        var options = DecodingPresets.streaming(
            language: language,
            noSpeechThreshold: Settings.shared.noSpeechThreshold
        )
        // 確定済み部分はデコードし直さない（速度と確定テキストの安定のため）。
        options.clipTimestamps = [lastConfirmedSegmentEndSeconds]

        await setInferring(true)
        let results: [TranscriptionResult]
        do {
            results = try await pipe.transcribe(
                audioArray: Array(currentBuffer),
                decodeOptions: options
            )
        } catch {
            await setInferring(false)
            throw error
        }
        await setInferring(false)
        guard isRunning else { return }

        if let t = results.first?.timings {
            let pipelineSec = Float(t.fullPipeline)
            if pipelineEMASeconds == 0 {
                pipelineEMASeconds = pipelineSec
            } else {
                let a = pipelineSec > pipelineEMASeconds ? emaAlphaUp : emaAlphaDown
                pipelineEMASeconds = a * pipelineSec + (1 - a) * pipelineEMASeconds
            }
            minNewAudioSeconds = min(max(pipelineEMASeconds * budgetSafetyFactor, budgetFloor), budgetCap)
        }

        // 無音ハルシネーション（「ありがとうございます」等）の定型句を、低確信度時のみ除去する。
        // 音声パイプラインのタイミングには一切影響しない純粋なポストフィルタ。
        let rawSegments = results.flatMap(\.segments)
        let segments = language == "ja" ? HallucinationFilter.filter(rawSegments) : rawSegments
        updateSegments(segments)
        let confirmedEndForLog = lastConfirmedSegmentEndSeconds
        let slid = slideWindowIfNeeded(pipe, bufferCount: currentBuffer.count)

        // 【診断・暫定】窓暴走の切り分け用。transcribe を走らせた毎ステップを無条件に記録する。
        // results が空（無音等で timings ログが出ない局面）でも、窓長・結果数・確定・スライド状態を残す。
        // 「窓が育つのに slid=false が続く」「results=0 が続く」等のパターンを特定する。原因特定後に削除。
        print("[STT/diag] win=\(String(format: "%.1f", Float(currentBuffer.count) / sampleRate))s "
            + "results=\(results.count) segs=\(rawSegments.count) "
            + "confEnd=\(String(format: "%.1f", confirmedEndForLog))s slid=\(slid) "
            + "budget=\(String(format: "%.2f", minNewAudioSeconds))s")

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
    private func slideWindowIfNeeded(_ pipe: WhisperKit, bufferCount: Int) -> Bool {
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
        // 録音された新規音声は必ず残す。purge は「現在の」バッファ長を基準に計算しないと、
        // transcribe 中に増えた未処理音声まで前から削ってしまい、発話がスキップされる。
        let cutSeconds = lastConfirmedSegmentEndSeconds - overlapSeconds
        let cutSamples = min(Int(cutSeconds * sampleRate), bufferCount)
        let liveCount = pipe.audioProcessor.audioSamples.count
        let keep = max(0, liveCount - cutSamples)
        pipe.audioProcessor.purgeAudioSamples(keepingLast: keep)

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
