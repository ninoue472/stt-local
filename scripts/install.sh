#!/usr/bin/env bash
#
# STTLocalApp をビルドして /Applications（または ~/Applications）へ配置し、
# Spotlight（⌘Space）→ "sttLocalApp" で起動できるようにする。
#
# 使い方:  ./scripts/install.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

APP_NAME="STTLocalApp"
BUNDLE_ID="com.local.STTLocalApp"   # generate_project.rb の BUNDLE_ID と一致させること
CONFIG="Release"
DERIVED="$PROJECT_DIR/build/DerivedData"
LOG="$DERIVED/install-build.log"

echo "▶ Xcode プロジェクトを生成 (generate_project.rb)…"
ruby generate_project.rb >/dev/null

echo "▶ ビルド ($CONFIG)… ログ: $LOG"
mkdir -p "$DERIVED"
# Homebrew の clang (CC/CXX) は Xcode の -index-store-path を解せず、C依存 (yyjson) の
# コンパイルが失敗する。そのため CC/CXX を環境から外してビルドする。
# 参照: docs/knowledge/build-requires-unset-cc-cxx.md
if ! env -u CC -u CXX xcodebuild build \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration "$CONFIG" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    > "$LOG" 2>&1; then
  echo "✗ ビルドに失敗しました。ログ末尾:"
  tail -30 "$LOG"
  exit 1
fi

BUILT_APP="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
if [ ! -d "$BUILT_APP" ]; then
  echo "✗ ビルド成果物が見つかりません: $BUILT_APP"
  exit 1
fi

# 配置先: /Applications を優先。書き込めなければ ~/Applications（どちらも Spotlight 対象）。
if [ -w /Applications ]; then
  DEST_DIR="/Applications"
else
  DEST_DIR="$HOME/Applications"
  mkdir -p "$DEST_DIR"
  echo "ℹ /Applications に書き込めないため $DEST_DIR に配置します。"
fi
DEST_APP="$DEST_DIR/$APP_NAME.app"

# 起動中の旧インスタンスを終了。STTLocalApp は単一インスタンスの常駐(.accessory)
# アプリのため、起動済みだと open しても旧プロセスが再活性化されるだけになる。
echo "▶ 起動中の旧インスタンスを終了…"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1

echo "▶ 配置: $DEST_APP"
rm -rf "$DEST_APP"
cp -R "$BUILT_APP" "$DEST_APP"

# entitlements を付けて ad-hoc 署名し直す。
# 上の build は CODE_SIGNING_ALLOWED=NO のため linker-signed となり、
# STTLocalApp.entitlements（マイク=audio-input 等）が埋め込まれない。
# その状態だと TCC(プライバシー許可) が安定せず、マイク許可ダイアログが
# 繰り返し出る原因になる。配置後に明示 ad-hoc 署名して entitlements を埋め込む。
# 参照: docs/knowledge/launchservices-duplicate-bundle-id.md
echo "▶ entitlements 付きで ad-hoc 署名…"
codesign --force --sign - \
  --entitlements "$PROJECT_DIR/STTLocalApp/STTLocalApp.entitlements" \
  --timestamp=none "$DEST_APP" 2>/dev/null || \
  echo "  ⚠ 署名に失敗（マイク許可が繰り返し出る場合は手動で codesign を確認）"

# LaunchServices を /Applications の版に正規化する。
# Xcode/xcodebuild が DerivedData 等へ同一バンドルIDの .app を作り登録するため、
# 放置すると Spotlight(⌘Space) が古いコピーを起動してしまう（最新版が反映されない真因）。
# 他コピーを登録解除し、配置先を強制登録・再インデックスする。
# 参照: docs/knowledge/launchservices-duplicate-bundle-id.md
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
echo "▶ LaunchServices を $DEST_APP に正規化…"
mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null \
  | grep -vx "$DEST_APP" \
  | while IFS= read -r other; do
      [ -n "$other" ] && "$LSREGISTER" -u "$other" 2>/dev/null || true
    done
"$LSREGISTER" -f "$DEST_APP" 2>/dev/null || true
mdimport "$DEST_APP" 2>/dev/null || true

echo "▶ 最新版を起動…"
# 明示パスで起動し、バンドルID解決のブレ（古いコピー起動）を避ける。
open "$DEST_APP"

echo ""
echo "✓ インストール完了 — 最新版を起動しました"
echo "  以降は ⌘Space → 'sttLocalApp' → Return でも最新版が起動します。"
echo "  （初回起動時のみモデルのダウンロードがあります）"
