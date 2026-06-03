# 波形の固まりは StreamingTranscriber の actor 化で解消した（実機確認済み）

## 結論
`waveform-as-input-monitor.md` 末尾で「将来の保険」とされていた *推論を MainActor から外す*
変更を T-013 で実施。`StreamingTranscriber` を `@MainActor final class` → **`actor`** にし、
推論ループ（`transcribe` の同期前後処理を含む）をバックグラウンドのエグゼキュータで回し、
`appState` への書き込みだけ `await MainActor.run { ... }` で hop する構成にしたところ、
**録音中（推論中）も波形が固まらなくなった**（実機で確認）。

## なぜ効くか
- 旧構成（@MainActor）では `transcribeStep` の同期処理と、録音タップ由来の波形更新 Task が
  どちらも MainActor を奪い合い、推論サイクル中は波形更新が滞っていた。
- actor 化で推論側が MainActor を一切専有しなくなり、`await pipe.transcribe` の suspension 中に
  `applyEnergy` → `MainActor.run` が割り込めるようになった。

## 注意・前提
- タイミング中立を厳守（窓・clipTimestamps・slide/purge・各秒数は不変）。最終テキストも一致。
- `AudioProcessor` へのアクセス元が MainActor→actor(bg) に変わるが、WhisperKit は並行アクセス前提で
  実機で問題なし。過去 T-001/T-004 の並行性リバートは「パイプライン肥大による CPU 枯渇」が原因で
  あり、actor 化そのものとは別問題（短窓化 T-010 後は枯渇しない）。

## 関連
- 感度は `WaveformView.normalizedEnergy` を `value*3.0` ゲイン＋`pow(...,0.72)` に調整。
- UI 整理: 状態表現は「入力＝波形 / 推論中・確定＝文字色（薄=未確定, 濃=確定）」の2系統に集約し、
  推論ステータスバッジは冗長として撤去（`StatusBadge.swift` は残置）。
