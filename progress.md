# Sprint: 推論ステータスの可視化 ＋ 波形の入力追従  (2026.06.03 — 2026.06.03) ✅完了

「いま何が起きているか」をユーザーに伝える。最終的に状態表現を2系統へ集約：
**入力の有無＝波形 / 推論中・確定＝文字色（薄=未確定, 濃=確定）**。波形は推論中も固まらない。

| ID    | タスク                                  | 状態 | 担当 | PR  |
|-------|-----------------------------------------|------|------|-----|
| T-011 | 確定/未確定テキスト＋推論中フラグを公開     | Done | Codex | —   |
| T-012 | 確定/未確定の色分け＋推論ステータスバッジ   | Done | Codex | —   |
| T-013 | 波形固まり修正（推論を MainActorから外す）  | Done（実機確認済） | Codex | —   |
| T-014 | UX微調整（バッジ撤去＋未確定色 0.45→0.3）   | Done | Claude | —  |

## ドキュメント (本 Sprint)
- 仕様: `docs/spec/inference-status-and-waveform.md`
- 設計: `docs/plan/inference-status-and-waveform.md`
- レビュー: `docs/reviews/T-011.md`, `T-012.md`, `T-013.md`
- 知見: `docs/knowledge/actor-off-mainactor-fixes-waveform-freeze.md`,
  `docs/knowledge/build-requires-unset-cc-cxx.md`

## メモ (本 Sprint)
- UX 決定（承認済み）: 波形=現状維持＋固まり修正 / 未確定=グレー薄色 / ステータス=テキストバッジ＋ドット脈動。
- **追補（実機FB反映）**: 「聞いています」⇄「推論中」のチラつきが分かりにくいとの指摘。
  入力の有無は**波形**が担い、バッジは**推論ステータス専用**へ分離。録音中は合間も実質推論が
  進むため、録音中・処理中は安定して「推論中…」を表示（`isInferring` の細かな ON/OFF で
  ラベルを切り替えない）。変更は `StatusBadge.swift` のみ（Claude 直接）。`isInferring` は
  AppState に残置（UI 未使用、将来用）。
- T-013 は高リスク（並行性変更）。T-011/T-012 と分離コミットし単独リバート可能にする。
- 依存: T-012 → T-011。T-013 は T-011 の後。

---

# Sprint: 無音ハルシネーション抑制  (2026.06.01 — 2026.06.03)

発話していない/発話直後の無音区間に定型句（「ありがとうございます」「ご視聴ありがとうございました」）が
混入する問題への対策。スコープ A（VAD ゲート）+ B（幻聴ポストフィルタ）。

| ID    | タスク                              | 状態  | 担当  | PR  |
|-------|-------------------------------------|-------|-------|-----|
| T-001 | VAD ゲートで無音区間をスキップ        | Reverted | Codex | —   |
| T-002 | 幻聴フレーズの信頼度ゲート付きフィルタ | Done  | Codex | —   |
| T-003 | XCTest ハーネス整備 + フィルタ単体テスト | Done  | Codex | —   |
| T-004 | VAD リグレッション修正（遅延+波形停止）  | Reverted | Codex | —   |
| T-005 | VAD撤回・フィルタのみ構成へ復元          | Done  | Claude | —  |
| T-006 | 波形を文字起こしから分離（入力モニタ化）  | Done  | Claude | —  |
| T-007 | 波形をタップコールバック駆動＋初動表示    | Done  | Claude | —  |
| T-008 | 幻聴フィルタ強化（部分一致/standalone）   | Done  | Claude | —  |
| T-009 | 再文字起こし間隔 1s→2s（軽量化）          | Done  | Claude | —  |
| T-010 | 推論バッファ短窓化（直近~5s+overlap）     | Done  | Claude | —  |

## ドキュメント
- 仕様: `docs/spec/hallucination-suppression.md`
- 設計: `docs/plan/hallucination-suppression.md`, `docs/plan/vad-regression-fix.md`, `docs/plan/realtime-short-window.md`

## メモ
- 本リポジトリは git 管理外。PR フローは適用せず、Codex 実装 → Claude レビュー → 人間承認で進める。
- スコープ C（temperatureFallbackCount 等のデコード閾値見直し）は本 Sprint 対象外（将来検討）。
- **T-001/T-004 撤回**: VAD ゲートは無音中にバッファを肥大化させ、発話再開時の transcribe を
  重くして UI（波形）も固めるリグレッションを起こした。`StreamingTranscriber` は @MainActor で
  transcribe 中 MainActor が専有されるため、波形更新を別タスク化しても改善しなかった。
  → VAD を撤回し、タイミング中立な T-002 ポストフィルタのみを幻聴対策として残す構成（T-005）。
- 現在の幻聴対策は T-002（`HallucinationFilter`）のみ。漏れる場合は blocklist 追加か
  信頼度閾値（noSpeechProb 0.4 / avgLogprob -0.7）の調整で対応（いずれもタイミング中立）。
