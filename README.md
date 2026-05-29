# STTLocalApp

このMacのローカル環境で動作する、日本語向けリアルタイム音声文字起こしアプリ。

- 画面下部フローティングパネル UI（Claudeデスクトップのオーバーレイ風）
- WhisperKit + `openai_whisper-large-v3_turbo` モデルでローカル文字起こし（音声データはこのMacから出ません）
- グローバルホットキー `⌘⇧R` で録音トグル
- 録音停止時に確定テキストを自動でクリップボードへコピー
- ホットキー `⌘⇧P` でパネル表示/非表示
- メニューバーアイコンから操作・終了

## 必要環境

- Apple Silicon Macbook（M1以降推奨）
- macOS 14 (Sonoma) 以上
- Xcode 16+
- 初回起動時に約 800MB のモデルダウンロードあり（ネットワーク必要）

## セットアップ

```sh
# プロジェクト直下で
ruby generate_project.rb           # STTLocalApp.xcodeproj を生成
open STTLocalApp.xcodeproj         # Xcodeで開く
```

Xcode で `⌘R` でビルド・実行。初回はSPM依存（WhisperKit, KeyboardShortcuts ほか）の解決に数十秒、モデルDLにさらに数分かかります。

CLI でビルドする場合（Homebrew clangが優先されないように注意）:

```sh
env -u CC PATH="$(xcode-select -p)/usr/bin:$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/bin:/usr/bin:/bin" \
  xcodebuild -project STTLocalApp.xcodeproj -scheme STTLocalApp \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath ./build CC="$(xcrun --find clang)" build

open build/Build/Products/Debug/STTLocalApp.app
```

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

## 配布（後日、必要になったら）

- Developer ID 署名 → `xcrun notarytool submit --wait` → `xcrun stapler staple`
- 現状は ad-hoc 署名（このMacでのみ起動可能）

## 依存

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) 0.18.x — Apple Silicon 最適化Whisper
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) 2.x — グローバルホットキー（Accessibility権限不要）
# stt-local
