# STTLocalApp

このMacのローカル環境で動作する、日本語向けリアルタイム音声文字起こしアプリ。

- 画面下部フローティングパネル UI（Claudeデスクトップのオーバーレイ風）
- WhisperKit + `openai_whisper-large-v3_turbo` モデルでローカル文字起こし（音声データはこのMacから出ません）
- グローバルホットキー `⌘⇧R` で録音トグル
- 録音停止時に確定テキストを自動でクリップボードへコピー
- ホットキー `⌘⇧P` でパネル表示/非表示
- メニューバーアイコンから操作・終了

## なぜ作ったのか

- **長大なドキュメントをスクロールしながらレビューしたい**
  - キー入力だと、スクロール操作とキー入力の切り替えが面倒
  - フローティングのウィンドウで、自分が指摘した内容をプレビューしながら音声入力したい
- **ローカルで動作を完結させたい**（音声・文字起こしがこの Mac の外に出ない）
- **MacBook Pro の性能を活かしたい**

補足（設計に込めた狙い）:

- **作業を中断せず音声入力できる** — パネルは他アプリのフォーカスを奪わない設計（nonactivating / 全Space・フルスクリーン対応）。レビュー対象を表示したまま、ウィンドウを切り替えずに喋れる（手はスクロールに専念）。
- **「いま何が起きているか」が分かる** — 確定/未確定をテキスト色で、入力の有無を波形で表示。リアルタイムでも安心して話し続けられる。
- **そのまま貼れる** — 録音停止時に確定テキストを自動でクリップボードへコピーし、レビューコメント欄などへ即ペースト。

## 必要環境

- Apple Silicon Macbook（M1以降推奨）
- macOS 14 (Sonoma) 以上
- Xcode 16+
- 初回起動時に約 800MB のモデルダウンロードあり（ネットワーク必要）

## Spotlight（⌘Space）から起動する

アプリを `/Applications`（または `~/Applications`）へインストールすると、Spotlight で起動できます。
付属スクリプトが「プロジェクト生成 → Release ビルド → アプリ配置 → Spotlight 即時インデックス」を一括で行います。

```sh
./scripts/install.sh
```

- `/Applications` に書き込めない場合は自動で `~/Applications` に配置します（どちらも Spotlight 対象）。
- ビルドには `CC`/`CXX` を外す必要があるため、必ずこのスクリプト経由でビルドしてください（理由: `docs/knowledge/build-requires-unset-cc-cxx.md`）。

インストール後の起動手順:

1. `⌘Space` で Spotlight を開く
2. `sttLocalApp` と入力（大文字小文字は不問）
3. `Return` で起動

> アプリを更新したら、再度 `./scripts/install.sh` を実行すれば最新版に置き換わります。
> メニューバー常駐型（Dock非表示）ですが、Spotlight からは通常どおり起動できます。

## 使い方

1. アプリ起動 → 画面下部にダーク半透明パネルが出現（Dockには出ません）
2. 初回はパネル内に「音声認識モデルを準備中」とDL進捗が表示される
3. モデル準備完了後、`⌘⇧R` で録音開始 → 話す → もう一度 `⌘⇧R` で停止
4. 停止と同時にテキストがクリップボードへコピーされる → 他アプリで `⌘V`

## アーキテクチャ概要

```
STTLocalApp/
├── App/                # @main, AppDelegate, Info.plist, MenuBarExtra
├── Panel/              # NSPanel + VisualEffectView でフローティングUI
├── UI/                 # SwiftUI views (PanelRootView, TranscriptView, ...)
├── Speech/             # WhisperKit ラッパとストリーミング転写
├── Hotkey/             # KeyboardShortcuts ライブラリのショートカット定義
└── State/              # @Observable AppState, UserDefaults Settings
```

- 音声取得・リサンプリング・VADは `WhisperKit.AudioStreamTranscriber` 内部に任せ、自前のAVAudioEngine実装はしない
- `DecodingPresets.japanese` で日本語向けにチューニング (`language: "ja"`, `noSpeechThreshold: 0.6` 等) — 「ご視聴ありがとうございました」系ハルシネーションを抑制
- パネルは `becomesKeyOnlyIfNeeded = true` + `.nonactivatingPanel` + `.canJoinAllSpaces, .fullScreenAuxiliary` で、他アプリのフォーカスを奪わず、フルスクリーン/全Spaceに被さって表示

## モデルキャッシュ

初回DLされたモデルは下記配下にキャッシュされます。

```
~/Library/Application Support/STTLocalApp/models/
```

WhisperKit がこの配下にスナップショット用の内部ディレクトリを作ります。不要になったら `models/` ごと削除してOKです（次回起動時に再DL）。

## 落とし穴・チューニング

- **モデルDL中はホットキーが効きません** — `AppState.phase` が `.ready` でないとトグルが無効です
- 日本語以外を使いたい場合は `Settings.swift` の `language` を `"en"` 等に変更
- 雑音が多い環境で取りこぼしが多い場合、`Settings.noSpeechThreshold` を 0.6 → 0.4 に下げる
- ハルシネーション（無音時の幻聴）が出る場合は逆に 0.6 → 0.8 に上げる
- 連続録音中のメモリは 1〜2GB 程度。8GB機でも動くが、長時間運用は 16GB 以上推奨

## 依存

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) 0.18.x — Apple Silicon 最適化Whisper
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) 2.x — グローバルホットキー（Accessibility権限不要）
# stt-local
