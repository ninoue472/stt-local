# 設計: VAD ゲート導入によるリグレッション修正

対象: T-001（VAD ゲート）導入後に発生した 2 つのリグレッション。

## 症状
1. 動作が遅い（発話再開時に重い）。
2. 発話中の波形アニメーションが動かない（固まる）。

## 根本原因
`StreamingTranscriber.transcribeStep` は VAD が無声と判断すると transcribe をスキップする。
しかし音声バッファの切り詰め `slideWindowIfNeeded` は **transcribe 成功後にしか走らない**。
→ 無音中 `pipe.audioProcessor.audioSamples` が上限なく伸び続ける。
   - 発話再開時に巨大バッファ全体を transcribe → 重い（症状1）。
   - 波形は `realtimeLoop` 先頭の `updateEnergy` でしか更新されず、長い transcribe 中はループが
     進まないため固まる。症状1で transcribe が伸びた分、固まりが長くなる（症状2）。

VAD 導入前は毎ループ transcribe→slide が走り、バッファは常に ≤ maxBufferSeconds(20s) に保たれていた。

## 修正

### A. 無音中のバッファ切り詰め（症状1の解消）
`transcribeStep` の VAD 無声分岐で、バッファが伸びていたら確定/未確定テキストを `committedText` に
退避してから末尾の短いマージン（onset 用 ~1.5s）だけ残して purge する。

```swift
guard voiceDetected else {
    pruneSilence(pipe)               // ★追加
    try await Task.sleep(nanoseconds: 100_000_000)
    return
}
```

```swift
/// 無音が続いてバッファが伸びたら、確定テキストを退避し末尾マージンだけ残して切り捨てる。
/// 発話再開後の transcribe を軽量に保つ。
private func pruneSilence(_ pipe: WhisperKit) {
    let liveCount = pipe.audioProcessor.audioSamples.count
    let bufferSeconds = Float(liveCount) / sampleRate
    let silenceMargin: Float = 1.5            // 発話頭の取りこぼし防止に残す秒数
    guard bufferSeconds > silenceMargin + 1.0 else { return }

    // 直近 transcribe 時点までの確定/未確定テキストを最終結果として退避。
    committedText += (confirmedSegments + unconfirmedSegments).map(\.text).joined()
    confirmedSegments = []
    unconfirmedSegments = []
    lastConfirmedSegmentEndSeconds = 0

    let keep = Int(silenceMargin * sampleRate)
    pipe.audioProcessor.purgeAudioSamples(keepingLast: keep)
    lastBufferSize = min(lastBufferSize, keep) // 残した分だけを基準に新規量を測り直す
}
```

注意点:
- 無音中に未確定テールを確定化することになるが、これは「発話が止まった＝テールは確定」で意味的に正しい。
  silenceMargin + 1.0s 以上溜まってから動くので、語中の一瞬の無音では発火しない。
- `lastBufferSize` を残バッファ長に合わせて縮める。purge 後に `nextBufferSize` が負やズレを起こさないこと。

### B. 波形をループから分離（症状2の根本解消）
`updateEnergy` を transcribe ループ依存から外し、独立した短周期タイマーで回す。
長い transcribe 中でも波形が更新され続ける。

- `start()` で録音開始時に Timer（または `Task` + `Task.sleep(50ms)` ループ）を起動し、
  毎 ~50ms `updateEnergy(pipe)` を呼ぶ。
- `stop()` でタイマーを停止。
- `realtimeLoop` 内の `updateEnergy` 呼び出しは削除（二重更新を避ける）。
- @MainActor 上で `appState.bufferEnergy` を更新するため、タイマーコールバックも MainActor で実行する。

## テスト/検証
- ビルド成功。
- 手動: 録音 → 発話と無音を交互 → 発話再開時に体感ラグが無い、波形が常時動く。
- 既存の幻聴抑制（T-001/T-002）の効果が維持されていること（無音区間で定型句が出ない）。

## タスク
- T-004: 上記 A + B を実装（いずれも `StreamingTranscriber.swift` のみ）。
