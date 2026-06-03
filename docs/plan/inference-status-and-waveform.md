# 設計: 推論ステータスの可視化 ＋ 波形の入力追従

対象タスク: T-011（データモデル）, T-012（プレゼンテーション）, T-013（波形固まり修正）。
仕様: `docs/spec/inference-status-and-waveform.md`。

## 全体方針
- 内部に既にある 3 層（committed / confirmed / unconfirmed）を **UI まで素通しする**。
  AppState で「確定テキスト」「未確定テキスト」「推論中フラグ」を別々に公開する。
- 波形の固まりは、`waveform-as-input-monitor.md` 末尾「将来の保険」で予告済みの
  **推論を MainActor から外す**アーキテクチャ変更で解消する。

---

## T-011: データモデル（AppState + StreamingTranscriber）

### AppState
```swift
var confirmedText: String = ""    // committedText + confirmedSegments
var unconfirmedText: String = ""  // unconfirmedSegments（再デコードで変わりうる末尾）
var isInferring: Bool = false     // transcribe() が今まさに 1 パス実行中か

// currentText は確定+未確定の連結に統一（コピー・後方互換用）。
var currentText: String { confirmedText + unconfirmedText }
```
- `currentText` を stored から computed に変更する。`copyableText` はそのまま `currentText`
  を使えば従来と同じ連結結果になる（コピー内容不変）。
- 録音開始時のリセット（`AppDelegate.startRecording`）は
  `currentText = ""` → `confirmedText = ""; unconfirmedText = ""` に置換する。

### StreamingTranscriber
- `updateDisplayText()` を分割し、確定/未確定を別々に反映:
  ```swift
  appState.confirmedText = (committedText + confirmedSegments.map(\.text).joined())
      .trimmingCharacters(in: .whitespacesAndNewlines) は使わず、連結はトリムせず保持。
      ※ 既存の assembledText() と同じ「生スペース保持」方針を踏襲。
  appState.unconfirmedText = unconfirmedSegments.map(\.text).joined()
  ```
  - 表示トリムは UI 側（TranscriptView）で行い、確定/未確定の境界スペースを壊さない。
- `isInferring` は `pipe.transcribe(...)` の直前で `true`、直後（および early-return / 例外 /
  `stop()`）で `false` にする。確実に倒すため `defer` を使う。
- `stop()` で `appState.isInferring = false` を保証する。

### 受け入れ確認（T-011）
- ユニットテスト可能な範囲: `currentText == confirmedText + unconfirmedText` の不変条件。
- `stop()` 後に `isInferring == false`。

---

## T-012: プレゼンテーション（TranscriptView + ステータスバッジ）

### TranscriptView の色分け
- `Text` の連結で確定/未確定を別色にする:
  ```swift
  (Text(confirmed).foregroundStyle(.primary)
   + Text(unconfirmed).foregroundStyle(unconfirmedColor)
   + Text(showsCursor ? "…" : "").foregroundStyle(unconfirmedColor))
  ```
  - `unconfirmedColor`: グレー薄色（例 `.white.opacity(0.45)` か `.secondary`）。ダークパネル
    前提なので実機で薄すぎ/濃すぎを微調整。
  - `.ready` 時は `lastFinalText` を全文 `.primary` で表示（未確定なし、`…` なし）。
  - 表示直前のトリムは「全体の先頭空白のみ除去」に留め、確定↔未確定の境界スペースは保持。
- `displayText`（スクロール追従の `onChange` キー）は `confirmedText + unconfirmedText` を見るよう更新。

### ステータスバッジ（新規 View）
- 配置: `MainBar` 左カラム、波形の直上（プレビュー: `● 推論中…  ▁▂▅▇▆▃`）。
- 状態 → 表示:
  | 状態 | ドット | ラベル |
  |------|--------|--------|
  | `.recording` かつ `isInferring` | 脈動 | 推論中… |
  | `.recording` かつ `!isInferring` | 静的(淡) | 聞いています |
  | `.processing` | 脈動 | 推論中… |
  | `.ready` / その他 | 非表示 | — |
- 脈動アニメ: `isInferring` を `withAnimation(.easeInOut.repeatForever)` でドットの
  opacity/scale を振る。`isInferring == false` で停止。
  - これが UX 決定の「アイコンアニメ」。既存 `StatusIcon` は現状のまま（録音中の waveform 記号）。

### 受け入れ確認（T-012）
- 手動: 録音中に末尾がグレー、確定部が濃色。喋り進めると薄→濃へ昇格。
- 手動: 推論パスの実行/非実行でドットの脈動が切り替わる。

---

## T-013: 波形固まり修正（推論を MainActor から外す）

### 根本原因
`StreamingTranscriber` は `@MainActor`。`realtimeLoop` → `transcribeStep` も MainActor 上で動き、
`pipe.transcribe(...)` の実行中 MainActor が専有される。波形はタップコールバックから
`Task { @MainActor in applyEnergy }` で更新するが、この Task は推論が MainActor を返すまで
実行されずキューに溜まる → 推論中は波形が固まり、終了後にまとめて反映（カクつき/固まり）。

（progress.md T-001/T-004、`docs/knowledge/avoid-mutating-audio-pipeline-timing.md` 参照。
当時はパイプライン肥大で別タスク化しても CPU 枯渇したが、T-005/T-010 で推論が軽くなった今は
MainActor を空けることが有効。）

### 方針: 推論ループをバックグラウンドへ
- `StreamingTranscriber` の `@MainActor` 全体付与を外し、`realtimeLoop` / `transcribeStep` を
  **非 MainActor**で実行する（`Task.detached` もしくはクラスを `actor` 化）。
- `appState`（`@MainActor @Observable`）への書き込みは `await MainActor.run { ... }` で hop。
  - 書き込み箇所: `confirmedText` / `unconfirmedText` / `isInferring` / `phase`（エラー時）。
- 波形のエネルギー反映（`applyEnergy`）は appState のみ触るので **MainActor 直行**のまま。
  推論が MainActor を専有しなくなるため、推論中もこの更新が滞らない。
- 状態の競合: 推論ループは単一の直列タスク。`stop()` は MainActor から呼ばれるので、
  `isRunning` / `pipe` の参照を安全にする（`actor` 化が最も素直。もしくは MainActor 隔離の
  制御フラグ＋ループ側はスナップショットで読む）。実装方式は Codex 判断、ただし下記制約を厳守。

### 厳守する制約（過去のリグレッション再発防止）
- **タイミング中立**: `transcribe` に渡す音声窓・`clipTimestamps`・スライド/purge ロジック・
  `minNewAudioSeconds` 等は一切変えない。バッファ操作は「現在のライブ長」基準を維持
  （`docs/plan/vad-regression-fix.md`）。
- 最終テキスト（`stop()` の戻り）は従来と一致すること。
- `[STT/timings]` ログは残す（回帰検証に使う）。

### 感度調整（波形）
- `WaveformView.normalizedEnergy` のゲイン/指数を調整し、通常会話で大半の高さまで立てる。
  ```swift
  // 例: 入力ゲインを掛けてから正規化
  let boosted = min(1, value * inputGain)        // inputGain は実機で 2.0〜4.0 目安
  return max(0.06, pow(CGFloat(boosted), exponent))
  ```
  - 値は実機の `relativeEnergy` 実測（無音/通常/大声）で決める。クリップ（張り付き）しない範囲。

### 受け入れ確認（T-013）
- 手動: 発話しながら（= transcribe 実行中）波形が滑らかに動き続ける。
- 手動: 無音→静まる / 発話→立つ が入力に追従。通常音量で十分な高さ。
- 回帰: 同一音声で最終テキストが変更前と一致。`[STT/timings]` の pipeline 時間が悪化しない。

### リスク
- **高リスク**: 並行性の変更は過去 2 回（T-001/T-004）リグレッションでリバートした領域。
  必ず手動の発話テスト＋最終テキスト一致確認を通すこと。問題時は T-013 のみ単独リバート可能なよう、
  T-011/T-012 と分離してコミットする。

---

## タスク分割と順序
1. **T-011**（データモデル）— StreamingTranscriber に触れるが低リスク。先行。
2. **T-012**（UI）— T-011 の公開プロパティに依存。並行/後続可。
3. **T-013**（波形固まり修正）— StreamingTranscriber の並行性変更。T-011 の後に実施し、
   単独でリバート可能な粒度でコミット。
