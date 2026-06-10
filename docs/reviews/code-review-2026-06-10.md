# STTLocalApp コードレビュー統合レポート

- 実施日: 2026-06-10
- 手法: Workflow（5観点並列レビュー → 敵対的検証 → 統合）。38 エージェント / 確定 29 件。
- 対象: `STTLocalApp/` 本体ソース（~2000 LOC / 21 ファイル）。`build/` 配下の依存パッケージは対象外。
- 種別: 報告のみ（コード変更なし）。

## エグゼクティブサマリ

5観点レビューと敵対的検証を通過した確定指摘 29 件を統合した。**Critical/High は 0 件**で、致命的なクラッシュやセキュリティ問題は検出されていない。最重要テーマは 3 つに集約される: **(1) Swift Concurrency の境界設計の甘さ**（actor とオーディオスレッド間の無ロック共有可変状態、非構造化 Task の乱立）、**(2) モデルロード/録音ライフサイクルの巻き戻し・直列化の欠如**（多重ロード競合、失敗時のロールバック/クリーンアップ無し）、**(3) クリップボード/トースト周りの正しさと UX**（空テキスト上書き、書き込み成否未確認）。いずれも現状で機能破綻は起きていないが、Swift 6 / Strict Concurrency 移行とエラー経路の堅牢化に向けた負債である。設計上のテーマとして AppState/AppDelegate への責務集中（テスト容易性の低さ）も全体に通底している。

---

## Medium

### [Medium] Settings シングルトンが MainActor と actor の両方から並行アクセスされ、getter に書き込み副作用がある
対象: `STTLocalApp/State/Settings.swift:3-25` （関連: `AppState.swift:24-27,56`、`AppDelegate.swift:75,98-99`、`StreamingTranscriber.swift:67,144`）

問題: `final class Settings`（Sendable でも actor でもない通常クラス）の `static let shared` が、MainActor 隔離ドメインと別アクター `StreamingTranscriber` の双方から直接触られている。さらに `modelName` の getter は読み取り時に `defaults.set(normalized,...)` を実行する read-during-get の副作用を持ち、MainActor 側の `selectModel`（set）と StreamingTranscriber 側の get がオーバーラップしうる。背後の UserDefaults はスレッドセーフだが read-then-write は非アトミックで、最悪ケースは一時的な stale read。Swift 6 / Strict Concurrency では Sendable 違反として検出される構造（現状ビルドは `SWIFT_STRICT_CONCURRENCY=minimal` のため未検出）。

改善方針: Settings を actor 化するか、録音開始前に MainActor で各プロパティを読み取り、値型（Sendable）のスナップショットとして `StreamingTranscriber.start()` の引数で渡す。少なくとも StreamingTranscriber 内からの直接 `Settings.shared` アクセス（67,144 行）を排除する。あわせて正規化処理は専用メソッド（例: `migrateModelNameIfNeeded()`）として起動時に 1 回だけ呼ぶ形にし、getter を純粋な読み取りに保つ（low 指摘 `Settings.swift:15-25` を統合）。

### [Medium] オーディオタップのコールバックと actor が同一の WhisperKit AudioProcessor 状態へ無ロックで並行アクセス
対象: `STTLocalApp/Speech/StreamingTranscriber.swift:81-88`

問題: `startRecordingLive` のコールバックはオーディオ（リアルタイム）スレッドで発火し、WhisperKit `AudioProcessor`（`open class: NSObject`、内部ロック無し）の `audioSamples` に append する。一方 StreamingTranscriber actor は同じ `audioSamples` を読み（130,246 行）、`purgeAudioSamples(keepingLast:)`（248 行）の `removeFirst` で破壊的に変更する。append（オーディオスレッド）と read/removeFirst（actor スレッド）が無ロックで同一配列に同時アクセスしうるため真のデータ競合が成立する。※検証で、84 行が読むのは `relativeEnergy`(→`audioEnergy`) であり purge 対象の `audioSamples` とは別配列であることが判明。真に鋭いレースは「audioSamples の append vs read/purge」のペア。purge は窓スライド時（>5s）のみで稀、append は連続のため衝突確率は低め。

改善方針: WhisperKit `AudioProcessor` のスレッド安全性を確認の上、前提をコメントで明文化する。スレッドセーフでないなら energy 取得もメインのループ側へ寄せる。purge 実行中にコールバックが走らない保証が無い点を明示的に検討する。

### [Medium] 再試行/モデル再読込の連打で prewarmWhisper が多重実行され、engine とモデル名が食い違う
対象: `STTLocalApp/App/AppDelegate.swift:44-49, 63-110`

問題: `.retryModelLoad` は無条件に `prewarmWhisper()` を呼び（44-46 行、再試行ボタンはデバウンス無し）、`.reloadModel` も `reloadModelIfPossible()` 経由で呼ぶ。どちらも進行中フラグ・世代トークン・Task の保持/cancel が無い。`prewarmWhisper` は複数の await（権限要求、`isModelCached`、`engine.load`、`warmupTranscription`）を持ち、各サスペンドポイントで別呼び出しがインターリーブ可能。各呼び出しが独立した `WhisperEngine()` を生成し、最後に `whisperEngine`/`streamingTranscriber`/`appState.phase` を上書きするが完了順序は非保証。遅い旧ロードが速い新ロードを上書きすると、`currentModelName` が指すモデルと実際の engine が食い違ったまま `.ready` になる。reload 経路にも `isModelCached`(81 行) 前に phase が `.ready/.error` のままで 2 回目がすり抜けるウィンドウがある。各ロードが warmup 推論まで走るため CPU/メモリも二重消費。

改善方針: ロード中フラグまたは現在の Task を保持して旧 Task を cancel し、`prewarmWhisper` を直列化する。世代トークンを持たせ、最新世代の結果のみ appState/engine へ反映する。

### [Medium] 録音停止時に空の最終テキストでも常にクリップボードを上書きし、誤った「コピーしました」を表示する
対象: `STTLocalApp/App/AppDelegate.swift:130-139`

問題: `stopRecording` は `finalText` の内容に関係なく `Clipboard.copy(finalText)` と `flashCopiedToast()` を無条件に呼ぶ。`Clipboard.copy`（`Clipboard.swift:4-8`）は `clearContents()` 後に `setString` するため、無音・極短音声・全セグメントがハルシネーション除去された等で `stop()` が空文字を返すと、ユーザーが直前にコピーしていた内容が消える。さらに「クリップボードにコピーしました」トーストが出るため、何もコピーされていないのに成功と誤認させる。

改善方針: `finalText` が空（trim 後）なら `Clipboard.copy` とトーストをスキップする。`lastFinalText` も空での上書き要否を検討する。

### [Medium] 波形エネルギー更新がオーディオコールバックごとに Task→actor→MainActor の 3 段ホップを発生させ、推論の重さに依存する
対象: `STTLocalApp/Speech/StreamingTranscriber.swift:81-88`（関連: `applyEnergy` 259-263 行）

問題: タップコールバックはオーディオスレッドで音声バッファ到来のたび（数十 ms 周期）に発火し、そのたびに `Task { await self?.applyEnergy(energy) }` という非構造化 Task を生成 → actor 隔離の `applyEnergy` 内で再度 `MainActor.run` へホップする 3 段越境が走る。78-80 行のコメントは「文字起こしループや推論の重さに一切依存せずリアルタイム追従する」と明言するが、energy を推論ループと同一の actor 経由にしているためこの独立性が破られている。pipe.transcribe の同期 CPU 区間が actor executor を占有しうる点、energy 更新が推論と同一 executor 上で直列化される点が実害。

改善方針: energy のスムージング/トリムは actor を経由せず、コールバックから直接 MainActor へ渡す（`MainActor.assumeIsolated` や専用の軽量バッファ）。actor ホップを廃し、コールバック側で前回値との差分が小さければ送出をスキップする throttling を入れる。

### [Medium] start() でオーディオタップ起動に失敗しても巻き戻しが無く、内部状態が不整合になりマイクが解放されない可能性
対象: `STTLocalApp/Speech/StreamingTranscriber.swift:57-93`（関連: `AppDelegate.swift:123-128`）

問題: `start()` は 68 行で `isRunning=true`、69 行で `self.pipe=pipe` を設定した後に 81 行の `try pipe.audioProcessor.startRecordingLive(...)` を呼ぶ。これが throw すると `isRunning` は true、`pipe` は非 nil のまま残り、`loopTask`（90 行）も生成されず「実行中なのにループ無し」の不整合になる。do/catch によるロールバック（`isRunning=false`/`stopRecording()`/`pipe=nil`）が無い。さらに呼び出し元 `AppDelegate.startRecording` の catch（123-128 行）も `appState.phase=.error` にするだけで `st.stop()` を呼ばないため、誰も後始末をしない。startRecordingLive がタップ部分設置後に throw した場合、オーディオタップ/エンジンが起動したまま残りうる（この transcriber は復旧時に新規生成・差し替えられ stop() 未呼び出しで破棄される）。`.error` 状態では `toggleRecording` が何もせず再録音導線も塞がる（モデル再読込でのみ復旧可能）。

改善方針: `startRecordingLive` と `loopTask` 起動を do/catch で囲み、失敗時に `isRunning=false`/`stopRecording()`/`pipe=nil` へ確実にロールバックしてから throw する。`isRunning`/`pipe` の設定はタップ起動成功後に行う。呼び出し元 catch でも `await st.stop()`（冪等）を呼んでからエラー表示へ遷移させる（low 連動指摘 `AppDelegate.swift:123-128` を統合）。

### [Medium] AppDelegate が録音制御・モデル読込・パネル・通知・ホットキーを全て抱える God Object
対象: `STTLocalApp/App/AppDelegate.swift:6-155`

問題: `AppDelegate` が appState 保持（8 行）、ホットキー登録（25-32 行）、5 本の通知購読（34-49 行）、Whisper のロード/ウォームアップ（`prewarmWhisper` 68-110 行）、録音の開始/停止オーケストレーション（`startRecording`/`stopRecording` 112-139 行）、エラー整形（`presentableRecordingError` 141-154 行）を一手に引き受けている。これらの業務ロジックはすべて private かつ AppDelegate に密結合で、テストシームが無く単体テスト不能。※実際の重い処理は WhisperEngine/StreamingTranscriber 等に委譲済みで、規模は約 155 行のため「God Object」はやや強めの表現だが、SRP/テスタビリティの保守性懸念は妥当。

改善方針: 録音オーケストレーション（start/stop/エラー整形）とモデル読込（prewarm/reload）を `RecordingCoordinator`・`ModelLoader` 等の `@MainActor` クラスへ切り出し、AppDelegate は配線（wiring）に専念させる。

---

## Low

### [Low] オーディオコールバック内の Task でエネルギー更新が順序保証なく投入され、波形が前後しうる
対象: `STTLocalApp/Speech/StreamingTranscriber.swift:85-87`

問題: コールバックごとに生成される `Task { await self?.applyEnergy(energy) }` は独立した非構造化タスクで、actor への到達順序がスケジューラ依存となり生成順の実行が保証されない。`applyEnergy` は actor 隔離なのでデータ競合は無いが（263 行の `!=` ガードは重複排除のみで順序逆転は防げない）、高頻度コールバック下で古い energy 配列が新しいものの後に適用され、波形表示が一瞬巻き戻る可能性がある。安全性ではなく正しさ（表示順序）の問題。

改善方針: 最新値のみを保持する仕組み（actor 内に `latestEnergy` を置き単一更新タスク/AsyncStream で coalesce、または MainActor 上で直接最新値を上書き）に変更し、タスク乱立と順序逆転を避ける。※Medium の 3 段ホップ指摘と同根のため、energy 経路の再設計でまとめて解消できる。

### [Low] 末尾セグメントがハルシネーション除去されると確定境界が前進せず同区間を再デコードし続ける
対象: `STTLocalApp/Speech/StreamingTranscriber.swift:165-167, 192-208`

問題: `transcribeStep` は `rawSegments` を `HallucinationFilter.filter` した後の配列を `updateSegments` に渡し、`lastConfirmedSegmentEndSeconds` と `clipTimestamps` をフィルタ後セグメントの end を基準に前進させる。確定対象（prefix 側）のセグメントがフィルタで丸ごと消えると `newlyConfirmed.last` が本来の end を指さず境界が前進せず、`clipTimestamps` が据え置かれて同区間を再デコードし続け窓が伸びる。HallucinationFilter が謳う「タイミングに影響しない純粋なポストフィルタ」の前提が崩れている。※`slideWindowIfNeeded` の hardCap=10s が安全網として機能し、窓は 10s で頭打ち・幻聴区間も purge されて構造的に回復するため、実害は「幻聴出現〜10s 到達までデコード窓が想定 5s より重くなる一過性のデグレード」に留まる。

改善方針: 確定境界の前進・`clipTimestamps` は raw セグメントの end を基準に計算し、ハルシネーション除去は committedText/表示テキスト生成の段にのみ適用する（タイミングと表示でセグメント列を分離する）。

### [Low] クリップボード書き込みの成否を確認せずトーストを出す
対象: `STTLocalApp/Speech/Clipboard.swift:4-8`（関連: `PanelRootView.swift:280-281`、`AppDelegate.swift:135`）

問題: `NSPasteboard.setString(_:forType:)` は Bool（成功可否）を返すが戻り値を破棄している。他アプリがペーストボードをロックしている等で書き込みに失敗しても呼び出し側は成功扱いで「コピーしました」トーストを表示する。ローカル完結アプリのため発生は稀。

改善方針: `copy` を `@discardableResult Bool` に変更して `setString` の戻り値を返し、呼び出し側で失敗時はトーストを出さない/エラー表示する。

### [Low] 録音開始の await 中に停止トグルが入ると phase 代入が逆転し UI 状態がずれる
対象: `STTLocalApp/App/AppDelegate.swift:112-139`

問題: `startRecording` は先に `appState.phase=.recording` にしてから `await st.start()` する。suspension 中にホットキー/ボタンでトグルすると `toggleRecording` が `.recording` を見て `stopRecording` を起動し phase を `.processing`→`.ready` にする。start/stop は actor 上で直列化されるが、AppDelegate 側の 2 つの `@MainActor` Task の phase 代入順は非保証。start() が permission 拒否等で throw すると、stop が `.ready` を書いた後に startRecording の catch が `.error` で上書きし、停止したのに UI がエラー表示になる余地がある。※タイトルの「processing→recording 逆転」は厳密には起きない（成功パスは phase 無代入）。実際の不整合経路は `.error` 上書き側。

改善方針: 録音の開始/停止を AppDelegate 側でも単一の状態機械（in-flight フラグや直列キュー）で扱い、start の継続が phase を書き戻す前に最新の意図を確認する。

### [Low] ko 選択時はハルシネーションフィルタが完全に無効
対象: `STTLocalApp/Speech/StreamingTranscriber.swift:166`（関連: `HallucinationFilter.swift`）

問題: `language == "ja"` のときだけ `HallucinationFilter.filter` を適用し、ko では三項演算子の else 側で `rawSegments` がそのまま使われフィルタ自体が呼ばれない。加えて `HallucinationFilter` の `alwaysDropSubstrings`/`standaloneDropPhrases` は全て日本語定型句のみで韓国語語彙は皆無。ko でも無音区間で韓国語の定型アウトロ（구독/시청 감사 等）が高確信度で出る傾向があり、無音時の幻聴が最終テキストに残る（二重の欠落）。

改善方針: ko 用の定型句辞書を追加し、言語に応じてフィルタ語彙を切り替えて適用する。少なくともフィルタ適用自体は言語非依存にする。

### [Low] normalize 後に空になるセグメント（記号のみ）はハルシネーション判定をすり抜ける
対象: `STTLocalApp/Speech/HallucinationFilter.swift:33-48`

問題: `isHallucination` は 35 行の `guard !normalized.isEmpty else { return false }` により、normalize 後に空のセグメントは「残す」で early return する。`normalize`（52-59 行）は whitespace/punctuation/symbols を全除去するため「。。。」「♪」等の記号のみセグメントは空になり無条件保持される。WhisperKit が無音/音楽区間で出す記号セグメントが最終テキストに残る（ja パス限定）。

改善方針: normalized が空のセグメントは無音由来として除去対象に含めるか、最低限 guard の意図を明文化する。

### [Low] HallucinationFilter.normalize が推論ごとに全 scalar へ 3 回の CharacterSet 包含チェックを実行
対象: `STTLocalApp/Speech/HallucinationFilter.swift:52-59, 44-47`

問題: ja の各推論結果セグメントに対し scalar 単位で whitespacesAndNewlines/punctuationCharacters/symbols の 3 つの `CharacterSet.contains` を評価し、`standaloneDropPhrases` ぶん `replacingOccurrences` で新規文字列を生成する。1.5s ごと・短文なので致命的ではないがマイクロ最適化の余地。※「normalize を短文時のみ実行」案は normalize が alwaysDrop チェックより前に走る依存関係上、実現不可。

改善方針: 3 つの CharacterSet を union した単一セットにして contains 回数を 1/3 にする。alwaysDrop の部分一致による早期 return（38 行に既存）を徹底する。

### [Low] 録音中の毎トークン更新で copyableText/trim 計算が複数ビューで重複実行され再描画を誘発
対象: `STTLocalApp/UI/PanelRootView.swift:299-301`（関連: `AppState.swift:65-76`、`TranscriptView.swift:75-141`）

問題: `CopyButton.isEnabled`（`!appState.copyableText.isEmpty`）は `.disabled` と backgroundColor の双方から呼ばれ、1 回の再描画で `copyableText`（confirmedText+unconfirmedText の連結＋trim）が複数回計算される。TranscriptView でも `displayText`/`visibleText`/`transcriptText`/`trimmedDisplaySegments` が独立に同じ連結＋trim を行う。録音中は毎推論（0.7〜1.5s）で更新され body 再評価される。※絶対コストは ML 推論に律速されるパス上で軽微（冗長計算のマイクロ最適化）。

改善方針: 連結済み/トリム済みテキストを AppState 側で一度だけ計算してキャッシュ（didSet で派生プロパティ更新）し、各ビューはそれを読むだけにする。`isEnabled` は専用 bool フラグで判定しテキスト計算と切り離す。

### [Low] WaveformView へ渡す前後で suffix による配列コピーが二重発生し毎フレーム再生成
対象: `STTLocalApp/UI/PanelRootView.swift:67`（関連: `StreamingTranscriber.swift:261`）

問題: `applyEnergy` 側で既に `energy.suffix(120)` を Array 化して `bufferEnergy` に格納済みなのに、`MainBar` は `WaveformView(energies: Array(appState.bufferEnergy.suffix(80)))` でさらに suffix(80) の新規 Array を作る（120→80 の二重トリム）。`MainBar` は `bufferEnergy` と `phase` の両方を読むため、推論より高頻度の入力モニタ更新のたびに body 再評価＋Canvas 全描画＋`resampledEnergies` 再生成が走る。※80 要素 Float コピーは軽微で本質コストはライブ Canvas 再描画。

改善方針: トリム長を片側（格納時 or 表示時）に一本化する。`WaveformView` を別サブビューに切り出して `bufferEnergy` のみに依存させ、phase 等無関係な状態変化での再描画を避ける。

### [Low] 1.5s 固定再推論ループの待機が固定 100ms ポーリングで、推論飽和時のバックログ検知・間隔調整がない
対象: `STTLocalApp/Speech/StreamingTranscriber.swift:136-139, 47`

問題: `realtimeLoop` は新規音声が `steadyMinNewAudioSeconds=1.5s` 溜まるまで 100ms sleep を繰り返すポーリング方式。1 回の transcribe が 1.5s を超える環境では推論中も録音継続で `audioSamples` が伸び、完了時に常に `next>1.5s` となり休みなく次推論へ突入する＝実効間隔は「pipeline 実時間」になり RTF<1.0 で恒常的にバックログが溜まる。`timings.fullPipeline` は取得済みだが print のみで適応制御が無い。※`hardCapSeconds=10s` の頭打ちで無制限成長は防がれ、破綻ではなく段階デグレード。

改善方針: 直近の pipeline 実測を使い、budget を継続的に超えたら `minNewAudioSeconds` を動的に引き上げる/`maxWindowSeconds` を縮める適応制御を入れる。固定ポーリングではなく必要サンプル到達までの推定残時間に応じた sleep にする。

### [Low] ウォームアップが固定 1.0 秒無音で 1 回のみ、初回実発話の先頭で実窓サイズの再コンパイルが残りうる
対象: `STTLocalApp/Speech/WhisperEngine.swift:57-70`

問題: `warmupTranscription` は durationSeconds=1.0 の無音 1 本のみを transcribe する。実ストリーミングは clipTimestamps 指定・可変長窓・prefill prompt 有りで推論する。CoreML/ANE は入力 shape ごとに内部最適化が走るため、1.0s 固定 shape のウォームアップが実運用窓を代表せず、初回到達時に追加コンパイル/メモリ確保レイテンシが先頭発話に乗りうる。※`maxWindowSeconds` は実際には 5.0（指摘の「最大 10s」は誤り）。ウォームアップは既に同一 `DecodingPresets.streaming` を使用（clipTimestamps が無いだけ）。

改善方針: ウォームアップを実運用の代表窓長（`maxWindowSeconds` 相当）でも 1 回実行し、clipTimestamps を付けた実経路と同じ DecodingOptions で温める。コストは初回 1 回のみ。

### [Low] NotificationCenter のブロック型オブザーバのトークンを保持/解除していない
対象: `STTLocalApp/App/AppDelegate.swift:35-49`

問題: `addObserver(forName:object:queue:using:)` は解除用トークン（NSObjectProtocol）を返すが 5 件とも戻り値を破棄している。AppDelegate はアプリ生存期間のシングルトンかつ各クロージャは `[weak self]` のため実害は出にくいが、同パターンを他オブジェクトに流用すると確実にリークする。

改善方針: 返り値を `[NSObjectProtocol]` に蓄積し、deinit もしくは適切なタイミングで removeObserver する。

### [Low] currentScreen() の NSScreen.screens.first! による force unwrap
対象: `STTLocalApp/Panel/FloatingPanelController.swift:73`

問題: `?? NSScreen.main ?? NSScreen.screens.first!` の最終フォールバックで force unwrap している。スクリーンが 1 枚も無い（ヘッドレス/リモート切断等）極端な状況でクラッシュする。GUI アプリ動作中の文脈では極めて稀。

改善方針: `guard let` で安全に取り出し、取得できなければパネル配置をスキップする等のフォールバックにする。

### [Low] flashCopiedToast のトースト消去がフラグ判定だけで競合する
対象: `STTLocalApp/State/AppState.swift:78-84`

問題: `justCopied=true` 後 1.6 秒 sleep して true なら false に戻すが、その間に再コピーされると前の Task のタイマーが新しいトーストのフラグを早期に false へ落とし、2 回目トーストの表示時間が短縮される（例: t=0 と t=1.0 でコピーすると 2 回目は 0.6 秒で消える）。世代管理が無く Task がキャンセルされず重複する。

改善方針: 既存の dismiss Task を保持してキャンセルしてから新規開始する、または世代カウンタで「自分が最後に立てたトーストか」を判定する。

### [Low] AppState が NotificationCenter / Settings へ直接依存しテスト容易性が低い
対象: `STTLocalApp/State/AppState.swift:53-59`

問題: `selectModel` が `Settings.shared` への書き込みと `NotificationCenter.post(.reloadModel)` を直接行い、`language` の didSet も `Settings.shared` を直接更新する。状態モデルが永続化と通知配信を内部に抱えるため、単体テストで副作用が発生し依存差し替えができない。※31 行に `onRecordingChange` という closure 注入の前例が既にある。

改善方針: 永続化と再読込トリガを delegate/closure 経由（`onModelChange` など）に外出しし、AppState を純粋な状態保持に寄せる。

### [Low] prewarmWhisper 内のマイク権限要求が await されない fire-and-forget Task
対象: `STTLocalApp/App/AppDelegate.swift:68-71`

問題: async 関数 `prewarmWhisper` の先頭で `Task { _ = await AudioProcessor.requestRecordPermission() }` と投げっぱなしにしている。権限要求とモデルロードの順序が保証されず結果も使われない。意図（並行で先に権限ダイアログを出す）も読み取りにくい。

改善方針: 並行実行が目的なら `async let` でロードと並走させて完了を待つ、不要なら直接 await する。意図をコメント化する。

### [Low] アプリ終了時にオーディオタップ/録音を停止するクリーンアップが無い
対象: `STTLocalApp/App/AppDelegate.swift:13-23`（関連: `STTLocalAppApp.swift:45`）

問題: `applicationWillTerminate`/`applicationShouldTerminate` が未実装で、メニューの「終了」と ⌘Q は `NSApp.terminate(nil)` を直接呼ぶ。録音中に終了すると `StreamingTranscriber.stop()`/`audioProcessor.stopRecording()` が呼ばれずプロセスが落ち、確定前テキストが失われる。※マイクタップ自体は OS がプロセス終了時に回収するため、実損失は in-flight の未確定テキストのみ。

改善方針: `applicationWillTerminate`（または `applicationShouldTerminate` を遅延終了に）で録音中なら `streamingTranscriber.stop()` を呼び、オーディオを停止してから終了する。

### [Low] warmupTranscription の失敗を print のみで握りつぶしユーザーに通知しない
対象: `STTLocalApp/App/AppDelegate.swift:96-103`

問題: ウォームアップを内側 do/catch で囲み、失敗時は print するだけで処理を継続する。続行設計自体は妥当（致命的なロード失敗は外側 catch で `.error` 提示）だが、モデルや Neural Engine の問題兆候を完全に隠す。本番では初回録音時に同種失敗が再発しうる。

改善方針: ログレベルを明確化し、繰り返し失敗する場合の検知（カウント/フラグ）を検討する。致命でない方針自体は維持してよい。

### [Low] realtimeLoop の transcribe 失敗時に確定済みテキストの退避が無い
対象: `STTLocalApp/Speech/StreamingTranscriber.swift:108-127`

問題: `transcribeStep` が throw すると catch（115-124 行）でタップ停止し `phase=.error` へ遷移するが、それまで `committedText`/`confirmedSegments` に溜まった確定テキストを `assembledText()` で退避する処理が無い。`stop()` 経由なら assembledText がクリップボードへ渡るが、エラー経路では失われる。※データは `appState.confirmedText` 内には残存するが、`.error` フェーズでは TranscriptView が空文字を返し UI 上でも見られず、クリップボードにも自動コピーされない。

改善方針: エラー停止時にも `assembledText()` をクリップボードや `lastFinalText` に退避し、ユーザーが文字起こし結果を取り戻せるようにする。

### [Low] prewarmWhisper でロード失敗時、既存 engine/transcriber を nil 化したまま再試行に依存
対象: `STTLocalApp/App/AppDelegate.swift:68-110`

問題: `prewarmWhisper` 冒頭（77-78 行）で `whisperEngine=nil`/`streamingTranscriber=nil` にしてからロードを試みる。ネットワーク失敗等で `load` が throw すると catch で `.error` になるが、それまで動作していた前モデルの engine も既に nil 化済みのため、再試行が成功するまで録音不能になる。特に `reloadModelIfPossible`（モデル切替）経由で動作中モデルがある状態の切替失敗時に顕著。

改善方針: 新モデルのロード成功後に `whisperEngine`/`streamingTranscriber` を差し替える（ロード失敗時は旧 engine を維持）構成にし、DL 失敗でも直前まで使えたモデルで録音継続できるようにする。

---

## 優先対応おすすめ Top 3

### 1. 空テキスト時のクリップボード上書き＆誤トーストを止める（Medium / `AppDelegate.swift:130-139`）
理由: 確定指摘の中で唯一「ユーザーの既存データ（クリップボード内容）を実際に破壊し、かつ成功と誤認させる」正しさ＋データ損失バグ。無音・全除去で容易に再現し、ユーザー体験への直接的悪影響が最も明確。修正は局所的（空判定の早期 return）で低コスト・低リスク。
受け入れ条件素案: `finalText` が trim 後に空のとき `Clipboard.copy` と `flashCopiedToast` が呼ばれず、既存クリップボード内容が保持されること（空入力ケースのユニットテストで検証）。

### 2. prewarmWhisper の多重実行を直列化する（Medium / `AppDelegate.swift:44-49, 63-110`）
理由: 再試行連打/モデル切替という現実的な操作で、engine とモデル名の不整合（`.ready` なのに実体が別モデル）＋ CPU/メモリ二重消費を引き起こす。Concurrency 系の他指摘（start ロールバック、energy 経路、phase 逆転）と同じ「ライフサイクル直列化の欠如」テーマの中核で、ここを正すと連鎖的に堅牢化できる。
受け入れ条件素案: ロード進行中に `.retryModelLoad`/`.reloadModel` が連続発火しても同時に走る `prewarmWhisper` は 1 つだけで、最新世代の結果のみが `whisperEngine`/`currentModelName`/`phase` に反映されること（旧 Task は cancel または結果破棄）。

### 3. オーディオスレッドと actor の AudioProcessor 共有のデータ競合を解消し、energy 経路を actor から外す（Medium / `StreamingTranscriber.swift:81-88`）
理由: 確定指摘の中で唯一クラッシュ/メモリ破損の可能性がある真のデータ競合（`audioSamples` の append vs purge）であり、同時に energy 3 段ホップ（Medium）と順序逆転（Low）も同一箇所で解消できる一石三鳥。Swift 6 移行に向けた Concurrency 負債の最重要ポイント。
受け入れ条件素案: 録音開始前に Settings をスナップショット化して直接 `Settings.shared` アクセスを排除し、energy 更新が actor を経由せず MainActor へ直接（または coalesce して）渡ること。WhisperKit AudioProcessor の共有可変状態へのアクセス方式（同期保証 or 排他）が明文化され、purge とタップコールバックの並行前提がコメント化されていること。
