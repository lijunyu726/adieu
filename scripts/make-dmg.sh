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
# 用本机钥匙串里的固定证书重签（先组件、后主程序，权限原样保留）。临时签名每次编译都变，
# 系统按签名认应用，每次更新都要重新允许完全磁盘访问、自动化等权限；固定证书签出来的“指定要求”不变
SIGN_ID="Adieu Self Signing"
if security find-identity -p codesigning | grep -q "\"$SIGN_ID\""; then
  codesign -f -s "$SIGN_ID" --preserve-metadata=identifier,entitlements "$APP/Contents/PlugIns/AdieuWidget.appex"
  codesign -f -s "$SIGN_ID" --preserve-metadata=identifier,entitlements "$APP"
  codesign --verify --deep --strict "$APP"
else
  echo "没有找到“$SIGN_ID”证书，保持临时签名：装上后要重新允许权限（证书怎么建见 AGENTS.md）" >&2
fi
# Xcode 不更新 .app 文件夹的修改时间；不改的话替换安装后程序坞、访达继续用旧图标缓存
touch "$APP"
OUT=scratch/Adieu-$VERSION.dmg
rm -f "$OUT"
uvx --from dmgbuild==1.6.5 dmgbuild -s scripts/dmg/settings.py \
  -D app="$APP" -D background=scripts/dmg/background.tiff -D icon="$APP/Contents/Resources/AppIcon.icns" \
  "Adieu $VERSION" "$OUT"
echo "$OUT"
