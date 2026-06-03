# 設計: 無音ハルシネーション抑制

対象 spec: `docs/spec/hallucination-suppression.md`

## 方針

既存の `StreamingTranscriber.transcribeStep` のループ構造を保ったまま、
**(A) transcribe 呼び出しの手前に VAD ゲートを差し込む** ことと、
**(B) transcribe 結果のセグメント配列を確定処理に渡す前にフィルタする** ことの 2 点に閉じる。
WhisperKit 純正 `AudioStreamTranscriber`（`useVAD` ブロック, L139-154）と同じパターンを踏襲する。

## アーキテクチャ

```
realtimeLoop
  └─ transcribeStep
       1. 新規バッファ量チェック (既存: >1.0s)
       2. ★A: VAD ゲート ← AudioProcessor.isVoiceDetected
            - 無声なら lastBufferSize 据え置き + 100ms sleep + return
       3. transcribe 実行 (既存)
       4. ★B: 幻聴ポストフィルタ ← HallucinationFilter.filter(segments)
       5. updateSegments / updateDisplayText / slideWindow (既存, フィルタ後の配列を使用)
```

## A: VAD ゲート

`transcribeStep` 内、`lastBufferSize = currentBuffer.count` を行う**前**に挿入:

```swift
let voiceDetected = AudioProcessor.isVoiceDetected(
    in: pipe.audioProcessor.relativeEnergy,
    nextBufferInSeconds: nextBufferSeconds,
    silenceThreshold: Settings.shared.silenceThreshold
)
guard voiceDetected else {
    // 無声: 音声を捨てず（lastBufferSize 据え置き）、次ループへ。
    try await Task.sleep(nanoseconds: 100_000_000)
    return
}
lastBufferSize = currentBuffer.count   // 既存行はここへ
```

- `lastBufferSize` を更新しないことで、無音中にたまった音声は破棄されず、
  発話が来た時点でその区間込みで処理される（純正実装と同じ）。
- 閾値は `Settings.silenceThreshold`（新規, 既定 0.3）。

### Settings 追加
`State/Settings.swift` に `noSpeechThreshold` と同形で:
```swift
var silenceThreshold: Float  // key "stt.silenceThreshold", default 0.3
```

## B: 幻聴ポストフィルタ

新規ファイル `Speech/HallucinationFilter.swift`:

```swift
enum HallucinationFilter {
    static let phrases: Set<String> = [
        "ご視聴ありがとうございました", "ご視聴ありがとうございます",
        "ありがとうございました", "ありがとうございます",
    ]
    static let noSpeechProbThreshold: Float = 0.4
    static let avgLogprobThreshold: Float = -0.7

    /// 低確信度かつ blocklist 一致のセグメントを除去する。
    static func filter(_ segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        segments.filter { !isHallucination($0) }
    }

    static func isHallucination(_ s: TranscriptionSegment) -> Bool {
        let normalized = normalize(s.text)
        guard phrases.contains(normalized) else { return false }
        return s.noSpeechProb >= noSpeechProbThreshold || s.avgLogprob <= avgLogprobThreshold
    }

    static func normalize(_ text: String) -> String {
        // 前後空白・句読点・記号（。、!?！？ 等）・空白を除去
        ...
    }
}
```

`transcribeStep` 側:
```swift
let segments = HallucinationFilter.filter(results.flatMap(\.segments))
updateSegments(segments)
```

### 設計上の注意
- フィルタは `updateSegments` の**前**に適用する。除外したセグメントは
  `confirmedSegments` にも `lastConfirmedSegmentEndSeconds` にも入らない（AC-B4 充足）。
- 信頼度ゲート（noSpeechProb / avgLogprob）で実発話を保護（AC-B3）。
  閾値は保守的に設定し、誤除去より取りこぼし側に倒す。
- blocklist は完全一致のみ（部分一致にすると「〜ありがとうございます。では本題」等を巻き込むため）。

## テスト

`HallucinationFilter` は純粋関数なので単体テスト可能:
- 低 noSpeechProb（実発話相当）＋ blocklist 一致 → 残る
- 高 noSpeechProb ＋ blocklist 一致 → 除去
- blocklist 非一致 → 常に残る
- normalize: 「ご視聴ありがとうございました。」「 ありがとうございます 」→ 正規化一致

VAD ゲートはエネルギー配列を渡す純関数（`isVoiceDetected`）の薄いラッパなので、
StreamingTranscriber の挙動は手動検証（spec の検証方法）で確認する。

## タスク分割

- **T-001**: VAD ゲート（A） + `Settings.silenceThreshold` 追加。
- **T-002**: 幻聴ポストフィルタ（B） + `HallucinationFilter` + 単体テスト。

T-001 と T-002 は同じ `transcribeStep` を触るが、挿入箇所が異なり独立。
T-001 → T-002 の順で着手（T-002 は T-001 後のセグメント取得行を前提にすると衝突が少ない）。

## リスク
- VAD 閾値 0.3 が環境ノイズで誤検出 → ノイズを音声扱いし幻聴が残る可能性。
  その場合 B が二重防御として効く。閾値は Settings で調整可能にしておく。
- マイクゲインが低いと実発話を無声判定する恐れ → 既定 0.3 は WhisperKit 純正既定値で実績あり。
