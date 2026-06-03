# ビルド時は CC/CXX を外す（Homebrew LLVM との衝突）

## 症状
`xcodebuild build`/`test` が C 依存（`yyjson` 等）のコンパイルで失敗する:
```
clang: error: unknown argument: '-index-store-path'
```

## 原因
ユーザーのシェル環境に以下が設定されている:
```
CC=/opt/homebrew/opt/llvm/bin/clang
CXX=/opt/homebrew/opt/llvm/bin/clang++
```
Homebrew の LLVM clang は Xcode 固有の `-index-store-path` を解さない。SwiftPM 経由の
C ターゲット（yyjson 等）がこの `CC` を拾い、コンパイルが落ちる。

## 対処
ビルド/テスト時に `CC`/`CXX` を外す:
```sh
env -u CC -u CXX xcodebuild build -project STTLocalApp.xcodeproj -scheme STTLocalApp \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO
```

## 補足
- Codex の sandbox 下では SwiftPM の package resolution 一時ファイル作成にも失敗しうるため、
  ビルド検証は Claude 側（非 sandbox）で `env -u CC -u CXX` を付けて行う運用が確実。
