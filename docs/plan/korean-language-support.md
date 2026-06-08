# 設計: 韓国語対応（言語切替）

仕様: `docs/spec/korean-language-support.md`

## アーキテクチャ方針

「言語は録音セッション境界で確定する設定値」として扱う。モデルは多言語のまま使い回し、
デコード時の `DecodingOptions.language` だけを切り替える。データフロー:

```
PanelRootView(言語トグル)
   └─ AppState.language (@Observable, .ready時のみ操作可)
        └─ Settings.language (UserDefaults 永続化)
             └─ StreamingTranscriber.start() が言語をスナップショット
                  └─ DecodingPresets.options(language:) で options 構築
                  └─ HallucinationFilter は language=="ja" のときのみ適用
```

ポイント:
- **モデル再ロード不要**。`AppDelegate.prewarmWhisper()` は変更しない。
- 言語スナップショットは `start()` で1回。`transcribeStep` 内では保持済みの値を使い、
  録音中の Settings 変更に影響されない（mixed-language window の防止）。

## 各レイヤの変更

### 1. Settings.swift（変更ほぼ不要）
- `language` get/set は既存のまま利用。値の許容は `ja` / `ko`。
- （任意）`ko` 以外の不正値が入った場合に `ja` へフォールバックする正規化は不要（UIが2択を保証するため）。

### 2. DecodingPresets.swift（パラメータ化）
- 現状 `japanese(noSpeechThreshold:)` は `language: "ja"` 固定。
- 言語を引数化する。日本語/韓国語でデコード設定（temperature, sampleLength, prefill 等）は共通でよい。
- 案: `static func streaming(language: String, noSpeechThreshold: Float) -> DecodingOptions`
  - 既存呼び出し箇所は1つ（`StreamingTranscriber:133`）のみなのでリネーム可。
  - `japanese(...)` を残すかは実装者判断（薄いラッパとして残してもよいが、呼び出し1箇所なので置換が簡潔）。

### 3. StreamingTranscriber.swift
- フィールド追加: `private var language: String = "ja"`。
- `start()` 内（`resetState()` 付近）で `self.language = Settings.shared.language` をスナップショット。
- `transcribeStep`:
  - `DecodingPresets.streaming(language: language, noSpeechThreshold: ...)` を使う。
  - フィルタ適用を言語条件で分岐:
    ```swift
    let raw = results.flatMap(\.segments)
    let segments = (language == "ja") ? HallucinationFilter.filter(raw) : raw
    ```

### 4. AppState.swift
- `var language: String` を追加。初期値は `Settings.shared.language`。
- 変更時に `Settings.shared.language` へ書き戻す（UIから set されたら永続化）。
  - `@Observable` では didSet を使える。`didSet { Settings.shared.language = language }` でよい。
  - もしくはトグルのアクション側で両方更新。実装者が単純な方を選択。
- 操作可否の判定用に既存 `phase` を利用（UI側で `.ready` 判定）。

### 5. PanelRootView.swift（UI）
- `MainBar` 内（録音操作群と競合しない位置、例: 上部ヒント行付近や操作ボタン左）に言語トグルを追加。
- コンパクトUI: `Menu` もしくは2値セグメント。表示は "日本語 / 한국어"（省スペースなら "JA / KO"）。
- バインド: `appState.language`。
- 無効化: `appState.phase` が `.ready` 以外（特に `.recording`/`.processing`）のとき disabled。
- HUD のダークテーマに馴染むスタイル（既存ボタン群のトーンに合わせる）。

## 言語切替時の表示リセット
- 言語は次回 `start()` から適用。`start()` 冒頭で `resetState()` が走るため、
  セッションをまたいだ表示の持ち越しは発生しない。追加のリセット処理は不要。

## テスト方針
- 既存 `HallucinationFilterTests` は不変（日本語フィルタのロジックは変更しない）。
- 言語条件分岐の単体テストは費用対効果が低い（実機確認で代替）。必要なら
  「`language!="ja"` のとき raw が素通しされる」薄いテストを追加可（任意）。
- 実機確認: ja→ko→ja の切替で表示言語が切り替わること、再起動後の保持、録音中の無効化。

## タスク分割
- **T-022（バックエンド）**: DecodingPresets パラメータ化 + StreamingTranscriber 言語スナップショット&フィルタ条件分岐 + AppState.language 追加&永続化。UIなし。
- **T-023（フロントエンド）**: パネル内 言語トグルUI（AppState.language バインド、.ready 以外で無効）。T-022 に依存。

## リスク・留意
- 低リスク。タイミング/並行性（過去のリグレッション領域）には触れない純粋な設定追加。
- `start()` でのスナップショットを忘れて `transcribeStep` で毎回 `Settings.shared` を読むと、
  録音中切替で window が混ざる。**必ず start() スナップショット**にすること（T-022 受け入れ条件）。
