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

## ⚠️ energy 更新の actor 隔離は load-bearing（最適化で外すと波形が固まる）
- T-033（2026.06.10）で、コードレビュー指摘「energy 更新が Task→actor→MainActor の3段ホップで
  推論の重さに依存する」を真に受け、energy 配信を **actor 隔離をやめて `CoalescedEnergyUpdater` +
  MainActor 直送**に置き換えたところ、実機で**録音中に波形が不規則に固まる退行**が出た。
- 原因: 上記「なぜ効くか」の仕組みは、energy 更新が **actor 隔離タスクとして transcribe と同じ
  executor に積まれ、`await pipe.transcribe` のサスペンド中に割り込んで処理される**ことに依存して
  いた。MainActor 直送（単一 coalesce タスク）にすると、この割り込み駆動が失われ、重い推論との
  スケジューリング競合で配信が不規則に遅延する。
- 結論: **`startRecordingLive` コールバックからの energy 配信は `Task { await self?.applyEnergy(energy) }`
  （actor 隔離）の形を維持する。3段ホップは欠陥ではなく、波形をリアルタイムに保つための設計である。**
- 補足: T-033 の残り（WhisperKit `AudioProcessor.audioSamples` への actor アクセスを排除する
  `LiveAudioBuffer` ミラー＋設定の Sendable スナップショット）はデータ競合解消として有効なので維持。
  energy 経路だけを実証済み方式へ戻した。

## 関連
- 感度は `WaveformView.normalizedEnergy` を `value*3.0` ゲイン＋`pow(...,0.72)` に調整。
- UI 整理: 状態表現は「入力＝波形 / 推論中・確定＝文字色（薄=未確定, 濃=確定）」の2系統に集約し、
  推論ステータスバッジは冗長として撤去（`StatusBadge.swift` は残置）。
