# 計画(概観): M5 Pro の余力を使ったパフォーマンス強化（バックログ）

実装はまだ。**選択肢を Issue 化して記録**するためのオーバービュー。各タスク T-015〜T-020 が本書を参照する。

## 背景
現状のアプリは「非力なマシンでもリアルタイム追従できる」よう、全体が**軽さ最優先**で
チューニングされている。一方、実機は **Apple M5 Pro / 18コア(6+12) / 64GB / macOS 26.4** で
ANE・GPU・CPU・メモリすべてに大きな余力がある。この余力を精度・応答性へ振り向けられる。

## 現状の保守的設定（チューニング起点）
| 項目 | 現在値 | ファイル |
|------|--------|----------|
| モデル | `openai_whisper-large-v3_turbo`（デコーダ削減版） | `State/Settings.swift` |
| 計算ユニット | `.cpuAndNeuralEngine`（ANEのみ、GPU不使用） | `Speech/WhisperEngine.swift` |
| `minNewAudioSeconds`（再推論間隔/ライブ更新粒度） | 2.0s | `Speech/StreamingTranscriber.swift` |
| `maxWindowSeconds`（推論窓上限） | 5.0s | 同上 |
| `overlapSeconds`（境界の音響文脈） | 1.0s | 同上 |
| `temperatureFallbackCount`（低確信リトライ） | 0 | `Speech/DecodingPresets.swift` |
| `temperature` / beam | 0.0 / 無し | 同上 |

## 改善レバーと方向（トレードオフは逆向き）
- **応答性↑（レイテンシ低減）**: `minNewAudioSeconds` を下げ高頻度再推論（T-016）。
  ただし短く頻繁な推論は**無音幻聴を増やしうる**（`HallucinationFilter` で吸収しつつ要確認）。
- **精度↑**: フル `large-v3`（T-017）＋窓拡大（T-018）＋デコードのリトライ/ビーム（T-020）。
  1回の推論は重くなるがレイテンシと逆方向。M5 Pro なら許容範囲を実測で見極める。
- **スループット↑**: 計算ユニット `.all`（GPU併用）で encode 高速化の可能性（T-019）。

M5 Pro+64GB なら「**両取り**（精度を上げつつ応答性も改善）」も十分現実的。

## 進め方（必須方針）
- **計測駆動**: まず T-015 で `[STT/timings]` の pipeline ms と ANE/GPU 使用率を可視化。
  以後すべての変更は「pipeline ms が budget(=`minNewAudioSeconds`×1000) を恒常的に下回る」
  範囲内で行い、変更前後を実測比較する。
- **段階的・単独可逆**: 音声パイプラインのタイミングは過去 T-001/T-004 でリグレッション→
  リバートした繊細領域（`docs/knowledge/avoid-mutating-audio-pipeline-timing.md`）。
  1レバーずつ・単独リバート可能な粒度で。
- **回帰確認**: 同一音声で最終テキストの妥当性、無音幻聴の増減を毎回チェック。

## タスク一覧（バックログ）
| ID | 内容 | 主目的 | 依存 |
|----|------|--------|------|
| T-015 | 計測ハーネス（pipeline/ANE/GPU 可視化・configログ） | 計測基盤 | — |
| T-016 | 再推論間隔の短縮/可変化（応答性） | レイテンシ | T-015 |
| T-017 | フル `large-v3` 切替＋既定モデル見直し（精度） | 精度 | T-015 |
| T-018 | 推論窓・オーバーラップ拡大（文脈・境界精度） | 精度 | T-015 |
| T-019 | 計算ユニット `.all`（GPU併用）検証 | スループット | T-015 |
| T-020 | デコード精度設定（Scope C: fallback/beam 等） | 精度 | T-015, T-017 |
