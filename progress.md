# Sprint: コードレビュー フォローアップ  — T-034 完了（実機OK）

コードレビュー堅牢化スプリント（Top3 完了）の残フォローアップ。まず T-033 由来のメモリ退行から。

| ID    | タスク                                              | 状態 | 担当 | PR  |
|-------|-----------------------------------------------------|------|------|-----|
| T-034 | AudioProcessor 内部バッファの頭打ち（T-033 由来メモリ） | Done | Codex | #16 |

- T-034: マージ済み（PR #16, squash）。T-033 のミラーバッファ化で `AudioProcessor.audioSamples` を purge
  しなくなり録音中に非有界成長（約3.8MB/分）していたのを、**タップコールバック内（append と同一オーディオ
  スレッド）から `purgeAudioSamples(keepingLast: 3s)` を 6s 超で呼び頭打ち**に（actor から呼ぶと T-033 が
  解消した競合を再導入するため不可）。energy 経路（actor 隔離）と mirror/transcribe は不変。
  WhisperKit 確認: `relativeEnergy` は別配列 `audioEnergy` を読み purge 対象外＝波形は壊れない。
  **実機計測OK**: 約5.5分連続録音で RSS 402→416MB（408〜416MB で安定・横ばい、推論時の瞬間スパイクは即復帰）。
  レビュー `docs/reviews/T-034.md`。`xcodebuild test` 13 tests 0 failures。
- 未着手の他候補: ロード失敗時の旧 engine 維持（T-032 由来 Low）/ ko ハルシネーションフィルタ /
  安全系 Low（force unwrap・終了時クリーンアップ 等）。`docs/reviews/code-review-2026-06-10.md` 参照。

---

# Sprint: コードレビュー指摘の堅牢化（Top3）  — 完了（実機OK）

2026.06.10 の全体コードレビュー（5観点並列＋敵対的検証、確定29件）から、優先度 Top3 をタスク化。
Critical/High は 0 件。テーマは **(1) ライフサイクル直列化の欠如 (2) オーディオ↔actor の並行性
(3) クリップボードの正しさ**。レビュー全文: `docs/reviews/code-review-2026-06-10.md`。

| ID    | タスク                                                | 状態 | 担当 | PR  |
|-------|-------------------------------------------------------|------|------|-----|
| T-031 | 空テキスト時のクリップボード上書き＆誤トーストを止める     | Done | Codex | #13 |
| T-032 | prewarmWhisper の多重実行を直列化（再試行/モデル切替競合）  | Done | Codex | #14 |
| T-033 | オーディオ↔actor のデータ競合解消＋energy 経路を actor 外へ | Done | Codex | #15 |

- 起点: `docs/reviews/code-review-2026-06-10.md`（Medium 7 / Low 22 / 計29件）。
- T-031: データ損失バグ（無音時に既存クリップボードを破壊＋誤「コピーしました」）。局所修正・低リスク。
  唯一「ユーザーデータを実際に破壊する」正しさ問題のため最優先。`AppDelegate.swift:130-139`。
- T-032: 再試行連打/モデル切替で engine とモデル名が食い違う（`.ready` なのに別モデル）＋二重ロード。
  「ライフサイクル直列化の欠如」テーマの中核で、他 Concurrency 指摘の堅牢化に波及。`AppDelegate.swift:63-110`。
- T-033: `audioSamples` の append(オーディオスレッド) vs purge(actor) の真のデータ競合 ＋ energy の
  3段ホップ・順序逆転を一箇所で解消。Swift 6 移行の最重要点。**高リスク（並行性変更）→ 単独リバート可能な
  コミット＋実機確認必須**（T-013 と同方針）。`StreamingTranscriber.swift:81-88`。
- 推奨順: T-031（独立・低リスク）→ T-032 → T-033（高リスク）。T-032/T-033 は `AppDelegate`/
  `StreamingTranscriber` を触るため、着手時に競合を避ける（同一ブランチ連続実装 or 順次）。
- 各タスクに受け入れ条件素案あり（`docs/tasks/{DONE,TODO}/T-031.md`〜`T-033.md`）。
- T-031: マージ済み（PR #13, squash）。レビュー `docs/reviews/T-031.md`（承認）。`xcodebuild test` 13 tests 0 failures。
  実機での最終確認（無音停止でクリップボード保持）は人間側で実施推奨。
- T-032: マージ済み（PR #14, squash）。レビュー `docs/reviews/T-032.md`（承認）。`xcodebuild test` 13 tests 0 failures。
  実機確認（再試行連打/モデル連続切替で `.ready` が正しいモデルを指す）は人間側で実施推奨。
  フォローアップ候補（別タスク化）: ロード失敗時の旧 engine 維持（早期 nil 化の解消）/ 並行性の自動テスト。
- T-033: マージ済み（PR #15, squash）。実機確認で波形改善を確認（人間OK）。レビュー `docs/reviews/T-033.md`。
  ミラーバッファ（`LiveAudioBuffer`）で `AudioProcessor.audioSamples` への actor アクセスを排除しデータ競合を
  解消、設定を Sendable スナップショット化（actor 内 `Settings.shared` 直接参照を排除）。
  **実機FB対応**: 初版は energy を coalesce + MainActor 直送に変えて波形が不規則に固まる退行が出たため、
  energy 配信は実証済みの actor 隔離方式（`applyEnergy`）へ戻した。`xcodebuild test` 13 tests 0 failures。
  知見追記: `docs/knowledge/actor-off-mainactor-fixes-waveform-freeze.md`（energy の actor 隔離は load-bearing）。
  要注意点: AudioProcessor 内部 `audioSamples` の非有界成長（長時間録音でメモリ増）→ 別タスクでフォロー候補。
- フォローアップ候補（未着手・別タスク化可）: ①AudioProcessor 内部 audioSamples の頭打ち（コールバック内
  same-thread purge）②ロード失敗時の旧 engine 維持（早期 nil 化の解消）③Low 残件（ko ハルシネーション
  フィルタ/終了時クリーンアップ/適応再推論 等、`docs/reviews/code-review-2026-06-10.md` 参照）。

---

# Sprint: 初回起動の不具合＆遅延改善（波形/権限/ウォームアップ/先頭エッジ）  — マージ済み (PR #12)

全体レビュー（2026.06.10）で洗い出した初回起動時の問題2件＋定常ラグへの対応。
**初回起動時に波形が出ない**（権限取得タイミング起因）と**初回発話のラグ**（コールドスタート起因）が主目的。

| ID    | タスク                                          | 状態 | 担当 | PR  |
|-------|-------------------------------------------------|------|------|-----|
| T-028 | マイク権限を起動時に先行取得＋波形ベースライン即時表示 | Done | Codex | #12 |
| T-029 | モデルロード後にウォームアップ推論を1回実行         | Done | Codex | #12 |
| T-030 | 先頭エッジのバジェット短縮（計測駆動・探索的）       | Done | Codex | #12 |

- 原因分析:
  - **波形(初回)**: 権限要求が録音開始時 → 初回だけ「ダイアログ待ち＋権限確定直後の audioProcessor 起動」が
    競合しエネルギーが流れない。権限を起動時に先行取得＋ベースラインを await 前に同期設定して解消（T-028）。
  - **初回ラグ**: `prewarm:true` はモデルコンパイルまで。実推論ホットパスが未初期化 → ロード後にダミー推論で温める（T-029）。
  - **定常ラグ**: 構造的下限（`realtime-budget-and-whisper-offline-limit.md`）。先頭エッジのみ一時短縮で第一表示を早める（T-030・要計測）。
- 3タスクとも `StreamingTranscriber.swift`/`AppDelegate.swift` を重複して触るため**同一ブランチ・連続実装**（競合回避）。
- 実装メモ:
  - `prewarmWhisper()` 開始時に `AudioProcessor.requestRecordPermission()` を fire-and-forget で先行起動。
    録音時の権限チェックは `StreamingTranscriber.start()` に残し、拒否時の既存エラー表示は維持。
  - `startRecording()` は `phase=.recording` 直前に `bufferEnergy=[0]` を同期設定し、初回ダイアログ待ち中も
    波形ベースライン枠を出す。
  - `WhisperEngine.warmupTranscription(...)` を追加。モデルロード成功後、`.ready` 前に 1.0s 無音配列を
    `pipe.transcribe(audioArray:decodeOptions:)` へ 1 回流して結果を破棄。失敗時はログのみで起動継続。
  - `StreamingTranscriber` の budget は定常 1.5s を維持しつつ、録音開始直後だけ 0.7s を使用。
    初回確定またはバッファ総量 1.5s 到達で 1.5s 固定へ復帰し、T-027 の適応budgetは復活させない。
- 計測: `rm -f /tmp/stt.log && script -q /tmp/stt.log <app>` で `[STT/timings]` を確認。
- ビルド: `env -u CC -u CXX xcodebuild -project STTLocalApp.xcodeproj -scheme STTLocalApp -configuration Debug -derivedDataPath build/DerivedData build` pass。

---

# Sprint: 再推論間隔の最適化＋窓ハードキャップ  — 実機OK

「詰まり」改善。budget(再推論間隔)の適応化を試行→撤回し**固定1.5s**に、窓暴走を**ハードキャップ**で抑制。

| ID    | タスク                                          | 状態 | 担当 | PR  |
|-------|-------------------------------------------------|------|------|-----|
| T-027 | 再推論間隔の最適化(適応試行→固定1.5s)＋窓ハードキャップ | 実機OK→PR | Codex/Claude | #10予定 |

- 結論: 適応budgetは周期的ジッタ/稀な大詰まりを残し**固定1.5s**が最良（元2.0sより速くスムーズ）。
  窓 > 10s で最後のセグメントも昇格可にし暴走を頭打ち（連続1セグメント発話対策）。
- 知見: `docs/knowledge/realtime-budget-and-whisper-offline-limit.md`
  （Whisperはオフライン型＝窓管理は緩和策。根治は軽量モデル or ストリーミング型エンジン）。
- 残課題: 稀な窓暴走の単発詰まりは budget では解消不可 → Issue #8(軽量) / 新Issue(ネイティブSpeech)。
- ブランチ: `feat/adaptive-budget`（base: main）。

---

# Sprint: モデル選択＋軽量化（M1対応）  — 実機OK

ユーザーがハード/用途でモデルを選べるように。既定は量子化版で軽量化。Issue #8 の本実装。

| ID    | タスク                                          | 状態 | 担当 | PR  |
|-------|-------------------------------------------------|------|------|-----|
| T-026 | モデル選択UI(メニューバー＋パネル)＋量子化既定     | 実機OK→PR | Codex | #9予定 |

- 決定: 既定 = 標準・量子化 `openai_whisper-large-v3_turbo_954MB`（高精度3GB/軽量216MBはセレクタで選択）。
- 実機知見: 量子化版は実用上ほぼ同等（固有名詞の漢字変換のみやや弱い）。M5 Pro では速度同等で、
  量子化の利点はメモリ/サイズ（M1 等で効く）。テキスト消失なし。
- レビュー: `docs/reviews/T-026.md` / 起点 Issue: #8。
- ブランチ: `feat/model-selection`（base: main）。

---

# Sprint: 韓国語対応（言語切替）  — マージ済み (PR #1)

多言語モデル(large-v3-turbo)はそのまま、デコード言語を ja/ko 切替。追加DLなし。
言語は録音セッション境界で確定（録音中は混在させない）。切替UIはフローティングパネル内。
日本語特化ハルシネーションフィルタは ja 選択時のみ適用。

| ID    | タスク                                          | 状態 | 担当 | PR  |
|-------|-------------------------------------------------|------|------|-----|
| T-022 | 言語切替の基盤（デコード切替/フィルタ条件/永続化） | Review | Codex | #1  |
| T-023 | パネル内 言語UI（初版: 2値トグル）                | Review | Codex | #1  |
| T-024 | 言語UIをドロップダウンに変更（日本語 / 한국어）   | Review | Codex | #1  |

- 仕様: `docs/spec/korean-language-support.md`
- 設計: `docs/plan/korean-language-support.md`
- レビュー: `docs/reviews/T-022.md`, `T-023.md`, `T-024.md`（いずれも承認 / build pass）
- PR: #1（T-022〜T-024 を同ブランチ feat/t-022-language-switch に集約）
- 依存: T-023 → T-022 → T-024（T-024 は T-023 の UI を置換）。
- 残: 人間による実機確認（ドロップダウンで ja↔ko 切替 / 再起動後保持 / 録音中無効）→ マージ。

---

# 単発修正

| ID    | タスク                                       | 状態 | 担当   |
|-------|----------------------------------------------|------|--------|
| T-021 | モデルキャッシュ未検出で毎回再DLされるバグ修正 | Done | Claude |

- 知見: `docs/knowledge/whisperkit-model-cache-detection.md`

---

# Sprint: 遅延改善（実測駆動）  — 進行中

「動作が少し遅い」への対応。M5 Pro 実機で `[STT/timings]` を計測し、**真因は decode の膨張**と判明。

## ベースライン実測（budget=2.0s / large-v3-turbo / ANE）
| audioIn（窓長） | encode | decode | pipeline |
|------|------|------|------|
| 2.1s | 314ms | 487ms | 508ms |
| 11.0s | 279ms | **1873ms** | **1902ms** |
| 4.1s | 279ms | 1031ms | 1061ms |

- `encode` は窓長に依らず **~280ms 固定**（30s パディングのため）→ **GPU併用は無意味、T-019 却下**。
- `decode` が窓長に比例して膨張。連続発話で窓が 5s 上限を超え **11s まで肥大**し pipeline が budget 寸前に。
- ⇒ 待機短縮(T-016)を先にやると budget 超過でバックログ＝逆効果。**まず窓を抑える(T-025)のが本筋**。

| ID    | タスク                                    | 状態 | 担当 | 主目的 |
|-------|-------------------------------------------|------|------|--------|
| T-025 | 窓のハードキャップ（無損失スライドで decode 抑制） | Review→実機OK | Codex | レイテンシ |
| T-016 | 再推論間隔の短縮（T-025 で pipeline<budget 後） | Blocked | — | 応答性 |
| T-019 | 計算ユニット .all（GPU併用）              | 却下（計測で encode 非支配項=~280ms固定と判明） | — | — |
| T-015 | 計測ハーネス（pipeline 可視化）            | 実質完了 | — | 既存ログで計測済 |
| T-017 | フル large-v3 切替＋既定モデル見直し         | Todo | —    | 精度 |
| T-018 | 推論窓・オーバーラップ拡大                  | 保留（T-025と逆方向） | — | 精度 |
| T-020 | デコード精度設定（Scope C: fallback/beam）  | Todo | —    | 精度 |

## T-025 結果（無損失版・実機OK）
- pipeline 中央 **818ms**（ベースライン 1902ms）/ テキスト消失 **ゼロ**（人間確認）。
- 設計: 窓が maxWindow 超で先頭セグメントを確定昇格＋既存スライド。**ただし最後の1セグメントは
  必ず未確定で残す**（後続ありの安定境界だけ確定）ことで継ぎ目の単語落ちを無くした。
- 知見: `docs/knowledge/streaming-window-cap-lossless-slide.md`
- レビュー: `docs/reviews/T-025.md`
- ブランチ: `feat/perf-window-cap`（base: feat/t-022-language-switch）。

- 概観: `docs/plan/performance-headroom-m5.md`
- タスク: `docs/tasks/DONE/T-025.md`
- 計測方法: `rm -f /tmp/stt.log && script -q /tmp/stt.log ./build/DerivedData/Build/Products/Debug/STTLocalApp.app/Contents/MacOS/STTLocalApp`
  （PTY 経由で print のバッファ問題を回避。script は追記なので毎回 rm 必須）。

---

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
