# リアルタイム文字起こしの音声パイプライン timing は安易に変えない

## 事実 / 学び
`StreamingTranscriber` は `@MainActor` クラスで、`pipe.transcribe(...)` を MainActor 文脈から
await する。transcribe 中は MainActor が実質専有され、UI 更新（波形 `bufferEnergy`）が止まる。
そのため「波形更新を別 Task（50ms）に分離」しても、同じ MainActor 上である限り改善しない
（波形は transcribe 完了後にまとめて動く）。

VAD ゲート（無声時に transcribe をスキップ）は、バッファ切り詰め `slideWindowIfNeeded` が
transcribe 後にしか走らない設計と噛み合わず、無音中にバッファが肥大化 → 発話再開時の transcribe が
重くなる → MainActor 専有時間が伸びて UI が固まる、という連鎖でリグレッションを起こした。

## 教訓
- 幻聴抑制のような「出力の補正」は、**transcribe 後の純粋なポストフィルタ**（タイミング中立）で
  やるのが安全。`HallucinationFilter` はこの方針で成功している。
- 音声バッファ投入やループ周期に手を入れる変更は、スライディングウィンドウ／clipTimestamps／
  MainActor 専有と密結合しており、副作用が読みにくい。やるなら transcribe を MainActor から
  切り離すアーキテクチャ変更とセットで（= 大きめのタスク）。
- 「速度」「UI 追従」のリグレッションは、まず **直近で触った音声パイプライン変更を撤回**して
  既知良好状態に戻し、原因を切り分けるのが速い。

## 出典
T-001(VAD) 導入 → 遅延 + 波形停止のリグレッション → T-004 で部分対処を試みるも未解決 →
T-005 で VAD 撤回・T-002 フィルタのみへ復元。
