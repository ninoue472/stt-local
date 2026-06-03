# 設計: 推論バッファの短窓化（直近~5s + オーバーラップ）

対象: T-010。リアルタイム性向上のため、推論時に渡す音声を全バッファ（最大20s）から
直近 ~5s の固定窓へ縮小する。

## 背景・動機
`StreamingTranscriber.transcribeStep` は現状 `Array(currentBuffer)`（最大 `maxBufferSeconds=20s`）を
**まるごと** `transcribe` に渡す。`clipTimestamps` で確定済みプレフィックスのデコードはスキップするが、
**エンコーダは渡した音声長すべてを処理する**。長い窓ほど 1 回の推論が重く、体感のリアルタイム性が落ちる。

→ 渡す窓を直近 ~5s に縮めればエンコーダ処理量がほぼ一定・小になり、軽くなる。

## 制約・既知のリスク
- **短窓化は無音幻聴（「ありがとうございました」等）を増やしうる**。Whisper は短い/無音に近いクリップで
  締めの定型句を出しやすい。→ `HallucinationFilter`（T-002/T-008）は**撤去せず残す**。
- 単純なチャンク分割は窓境界で単語が切れ、重複・脱落・精度低下を招く。→ **音響オーバーラップ**で緩和する。
- 過去 T-001/T-004 の教訓: バッファ操作は transcribe 中も録音が進む前提で「現在のライブ長」基準に行う。
  `lastBufferSize` のズレで新規音声をスキップさせないこと（`docs/plan/vad-regression-fix.md` 参照）。

## 方針: 確定境界の手前にオーバーラップを残す短窓スライド

既存の確定/未確定（confirm/commit）機構はそのまま流用し、**窓を小さく・スライドを積極化**する。
鍵は「確定境界の手前 `overlapSeconds` 分の確定済み音声を残す」こと:

- エンコーダにはオーバーラップ込みの窓を渡す → 左文脈（音響）が残り単語切れを防ぐ。
- デコード開始位置 `clipTimestamps` はオーバーラップ分だけ後ろにずらす → 確定済みテキストを二重出力しない。

### パラメータ
```swift
/// 推論で処理する窓の上限秒。これを超えたら確定境界の手前でスライドする。
private let maxWindowSeconds: Float = 5.0          // 旧 maxBufferSeconds=20 を置換
/// スライド時に確定境界の手前に音響文脈として残す秒数。
private let overlapSeconds: Float = 1.0
```
`minNewAudioSeconds`（再推論間隔）は当面 2.0 のまま据え置き（窓が軽くなった分の追値下げは別タスクで検討）。

### slideWindowIfNeeded の変更
```swift
private func slideWindowIfNeeded(_ pipe: WhisperKit, bufferCount: Int) {
    let bufferSeconds = Float(bufferCount) / sampleRate
    // オーバーラップを残せるだけ確定が進んでいることを条件にする。
    guard bufferSeconds > maxWindowSeconds,
          lastConfirmedSegmentEndSeconds > overlapSeconds else { return }

    committedText += confirmedSegments.map(\.text).joined()

    // 確定境界の overlapSeconds 手前で切る（オーバーラップを残す）。
    let cutSeconds = lastConfirmedSegmentEndSeconds - overlapSeconds
    let cutSamples = min(Int(cutSeconds * sampleRate), bufferCount)
    let liveCount = pipe.audioProcessor.audioSamples.count
    let keep = max(0, liveCount - cutSamples)
    pipe.audioProcessor.purgeAudioSamples(keepingLast: keep)

    lastBufferSize = max(0, bufferCount - cutSamples)
    // 残したオーバーラップ分はデコードし直さない（二重出力防止）。
    lastConfirmedSegmentEndSeconds = overlapSeconds
    confirmedSegments = []
}
```

変更点は (1) 発火閾値 20→5s、(2) 切り取り位置を `overlapSeconds` 手前に、(3) スライド後の
`lastConfirmedSegmentEndSeconds` を 0 ではなく `overlapSeconds` に設定、の 3 点のみ。

### transcribeStep
基本そのまま。`Array(currentBuffer)` を渡すが、上の積極スライドで窓が ~5s + 処理中増分に保たれるため
実効的に「直近 ~5s + オーバーラップ」を渡すことになる。フィルタ呼び出し・確定ロジックは不変。

## テスト/検証
- ビルド成功（`xcodebuild` でターゲットがコンパイルできること）。
- 既存 `HallucinationFilterTests` が pass（フィルタは不変なので影響しないはず）。
- 手動: 長め（30s+）に連続発話 → 1 回の推論が体感で軽い／追従する。窓境界で単語が切れたり
  同じ語が二重に出ないこと。無音区間で定型句が出ないこと（フィルタ維持の確認）。

## ロールバック
`maxWindowSeconds`/`overlapSeconds` の 2 定数と `slideWindowIfNeeded` の 3 点のみの変更。
問題時は `maxWindowSeconds=20`・切り取り位置を確定境界ちょうど・`lastConfirmedSegmentEndSeconds=0`
へ戻せば従来挙動に復帰する。
