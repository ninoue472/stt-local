# 同一バンドルIDの重複登録で「最新版が起動しない」

## 症状
`scripts/install.sh` でビルド＆ /Applications へ配置し、アプリを終了して再起動しても、
**コードの変更が反映されない**（古いUI/挙動のまま）。install.sh のビルド・コピー自体は成功している。

## 真因
LaunchServices に **同一バンドルID `com.local.STTLocalApp` の .app が複数登録**されていた。
Xcode / `xcodebuild` でビルドするたびに、成果物が下記のような複数パスに生成・登録される:

- `/Applications/STTLocalApp.app`（install.sh の配置先＝最新）
- `~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/STTLocalApp.app`
- `<repo>/build/Build/Products/Debug|Release/STTLocalApp.app`
- `<repo>/build/DerivedData/Build/Products/Debug|Release/STTLocalApp.app`

STTLocalApp は単一インスタンスの常駐(.accessory)アプリ。Spotlight(⌘Space) や `open -b <bundleid>` は
**バンドルIDで解決**するため、複数登録があると LaunchServices が **/Applications ではなく古いコピー
（特に Xcode の DerivedData/Debug）を起動**してしまう。結果、最新版が「有効にならない」ように見える。

## 切り分け方法
```sh
# 索引されている全コピー
mdfind 'kMDItemCFBundleIdentifier=="com.local.STTLocalApp"'

# ⌘Space 相当（バンドルID起動）が実際どこを起動するか
pkill -x STTLocalApp; sleep 1
open -b com.local.STTLocalApp; sleep 2
pgrep -x STTLocalApp | xargs -I{} ps -o command= -p {}

# バイナリに最新ソース固有の文字列が含まれるかで版を判定（例: 機能追加時の systemImage 名）
grep -qa "chevron.up.chevron.down" "<app>/Contents/MacOS/STTLocalApp" && echo 最新 || echo 旧
```

## 対策（install.sh に実装済み）
配置後に LaunchServices を /Applications に正規化する:
1. 旧プロセスを終了（`osascript ... to quit` ＋ `pkill -x`）。起動済みだと `open` しても旧プロセスが再活性化されるだけ。
2. 同一バンドルIDの他コピーを登録解除（`lsregister -u <path>`）。
3. **最後に** `lsregister -f "$DEST_APP"` で /Applications を強制登録（最後に登録した版が優先解決される）。
4. `mdimport` で再インデックス。
5. **明示パス**で `open "$DEST_APP"`（バンドルID解決のブレを避ける）。

`lsregister`:
`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister`

## 注意 / 残課題
- `lsregister -u` は登録解除のみで、`mdfind` の索引には**ファイルが存在する限り残って見える**（=索引と起動解決は別物）。
  起動解決が /Applications になっていれば実害なし。
- install.sh を通さず **Xcode で直接 Run** すると Debug コピーが再登録され、再発しうる。
  恒久的に断ちたい場合は generate_project.rb で Debug ビルドのバンドルIDを `.dev` 等へ分離する案がある（未実施）。

---

# 関連: マイク許可ダイアログが繰り返し出る（TCC × ad-hoc 署名）

## 症状
起動のたび／録音のたびに "STTLocalApp would like to access the Microphone" が出続ける（無限ループ的）。

## 原因
1. **複数コピーが各自マイク許可を要求**（上記の重複バンドルID問題と同根）。コピーごとに別アプリ扱いで個別に要求が出る。
2. **install ビルドが `CODE_SIGNING_ALLOWED=NO`** のため、成果物が `adhoc, linker-signed` となり
   `STTLocalApp.entitlements`（`com.apple.security.device.audio-input` 等）が**埋め込まれない**。
   TCC(プライバシー許可) はアプリのコード署名に紐づくため、entitlements 欠落＋不安定な署名だと許可が記憶されず再要求される。

## 切り分け
```sh
codesign -dvv /Applications/STTLocalApp.app          # flags に linker-signed が出ていないか
codesign -d --entitlements - /Applications/STTLocalApp.app  # audio-input があるか
```

## 対処（install.sh に実装済み）
1. 配置後に **entitlements 付きで ad-hoc 署名し直す**:
   `codesign --force --sign - --entitlements STTLocalApp/STTLocalApp.entitlements --timestamp=none "$DEST_APP"`
   → `flags=0x2(adhoc)`（linker-signed が消える）、audio-input が埋め込まれる。
2. 重複コピーの登録解除＋ /Applications 正規化（上記）で、要求するアプリを1つに収束。
3. 状態が壊れている場合は一度リセット: `tccutil reset Microphone com.local.STTLocalApp`。
   その後 /Applications 版を起動して**1回だけ許可**すれば以後は記憶される。

## 残課題
- ad-hoc 署名は cdhash がビルドごとに変わるため、**コード変更を伴う再インストール後は1回だけ再要求**されうる
  （無限ループではない）。完全に無くすには安定した署名（Apple Development / Developer ID + Team）が必要。
