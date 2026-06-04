# WhisperKit のモデルキャッシュ検出と tokenizer のオフライン解決

## 症状
「初回のみ800MBダウンロード」のはずのモデル準備画面が**毎回起動時に出る**（再DLが走る）。

## 原因
`WhisperKitConfig(downloadBase: modelsRoot, download: true)` で DL すると、WhisperKit は
**`modelsRoot/models/argmaxinc/whisperkit-coreml/<model>/`** にモデルを保存する
（HuggingFace repo `argmaxinc/whisperkit-coreml` のローカルレイアウト）。
一方、自前のキャッシュ検出 `existingLocalModelFolder` が見ていたのは
`modelsRoot/<model>` と `modelsRoot` だけ → **キャッシュを発見できず毎回 DL 経路**へ。

## 修正（`Speech/WhisperEngine.swift`）
1. 検出候補に WhisperKit の標準保存先を追加:
   `modelsRoot/models/argmaxinc/whisperkit-coreml/<model>`（最優先）。
2. ローカル経路（`modelFolder` + `download:false`）でも **`downloadBase: modelsRoot` を渡す**。
   WhisperKit は `tokenizerFolder = config.tokenizerFolder ?? config.downloadBase`（WhisperKit.swift:70）
   とし、`ModelUtilities.loadTokenizer` が `downloadBase/models/openai/whisper-large-v3/tokenizer.json`
   を探す。これを渡さないと tokenizer がローカルで見つからず毎回 Hub から取得しに行く。
3. UI: `AppDelegate.prewarmWhisper` でロード前に `engine.isModelCached()` を確認し、
   キャッシュ済みなら `.loadingModel`（準備中スピナーのみ）、未キャッシュのみ `.downloadingModel`
   （「初回のみ800MB DL」文言）を表示。従来は無条件で `.downloadingModel(0.05)` を出していた。

## 検証手順（再現＆確認）
- 実モデルの所在: `find "~/Library/Application Support/STTLocalApp/models" -name "*.mlmodelc"`
- tokenizer: 同 models 配下 `models/openai/whisper-large-v3/tokenizer.json`
- 再DL有無: 起動して `…/whisperkit-coreml` 配下に**新規書き込みが無ければ**キャッシュ読込成功:
  `find "<dir>" -type f -newermt "-20 seconds"` が空。

## 関連
- `ModelUtilities.detectModelURL(inFolder:named:)` は `<folder>/<name>.mlmodelc`（無ければ `.mlpackage`）を返す。
- `hasRequiredModelFiles` は MelSpectrogram / AudioEncoder / TextDecoder の存在で判定。
