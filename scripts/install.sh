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

echo "▶ 配置: $DEST_APP"
rm -rf "$DEST_APP"
cp -R "$BUILT_APP" "$DEST_APP"

# Spotlight に即時インデックスさせ、すぐ ⌘Space で見つかるようにする。
mdimport "$DEST_APP" 2>/dev/null || true

echo ""
echo "✓ インストール完了"
echo "  ⌘Space → 'sttLocalApp' と入力 → Return で起動できます。"
echo "  （初回起動時のみモデルのダウンロードがあります）"
