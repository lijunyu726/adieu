#!/bin/zsh
# 编译 Release 版并打包成拖拽安装的 .dmg，输出到 scratch/
# 用法：scripts/make-dmg.sh（安装窗口的布局由 scripts/dmg/settings.py 决定，需要 uv）
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | sed -E 's/.*"(.*)".*/\1/')
xcodegen generate -q
# 每次打包用时间做构建号：系统的图标缓存按“标识符 + 版本”认，构建号不变的话替换安装后还显示旧图标
BUILD=$(date +%Y%m%d%H%M)
xcodebuild -project Adieu.xcodeproj -scheme Adieu -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath scratch/DerivedData build -quiet \
  CURRENT_PROJECT_VERSION="$BUILD"

APP=scratch/DerivedData/Build/Products/Release/Adieu.app
# Xcode 不更新 .app 文件夹的修改时间；不改的话替换安装后程序坞、访达继续用旧图标缓存
touch "$APP"
OUT=scratch/Adieu-$VERSION.dmg
rm -f "$OUT"
uvx --from dmgbuild==1.6.5 dmgbuild -s scripts/dmg/settings.py \
  -D app="$APP" -D background=scripts/dmg/background.tiff -D icon="$APP/Contents/Resources/AppIcon.icns" \
  "Adieu $VERSION" "$OUT"
echo "$OUT"
