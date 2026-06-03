# 新規 Swift ファイル追加時は generate_project.rb の再実行が必須

## 事実
`STTLocalApp.xcodeproj` は `generate_project.rb` が `STTLocalApp/` 配下のソースを
スキャンして生成する。新規 `.swift` ファイルを追加しただけではプロジェクトに登録されず、
ビルドが `error: cannot find '<Type>' in scope` で失敗する。

## 対処
新規ファイル追加後に必ず:
```sh
ruby generate_project.rb
```
を実行してから xcodebuild する。

## 出典
T-002（HallucinationFilter.swift 追加）で発生。ファイル追加 → ビルド失敗 → 再生成で解決。
Codex は workspace-write sandbox かつ既存ファイル編集前提のため、新規ファイルを伴うタスクでは
Claude 側でこの再生成＋ビルド確認を行う運用とする。
