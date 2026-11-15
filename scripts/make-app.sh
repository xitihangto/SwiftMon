#!/bin/sh
# 把 SPM 产物打成正经的 SwiftMon.app（含 Info.plist 与图标）。
# 默认同时安装到 /Applications（方便 Finder 里找到）；--no-install 只留在 build/；
# --open 会先退出正在运行的实例，再从 /Applications 启动刚生成的这一版。
set -eu

cd "$(dirname "$0")/.."
ROOT=$(pwd)
APP="$ROOT/build/SwiftMon.app"

INSTALL=1
OPEN_AFTER=0
for arg in "$@"; do
    case "$arg" in
        --no-install) INSTALL=0 ;;
        --open)       OPEN_AFTER=1 ;;
        --install)    INSTALL=1 ;;   # 兼容旧用法
        *) ;;
    esac
done
SYSTEM_APP="/Applications/SwiftMon.app"

echo "==> 1/5 release 构建"
swift build -c release

echo "==> 2/5 生成图标"
ICONDIR=$(mktemp -d)
swift "$ROOT/scripts/make-icon.swift" "$ICONDIR" >/dev/null
ICONSET="$ICONDIR/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" "512:512x512" "1024:512x512@2x"; do
    px=${spec%%:*}
    name=${spec#*:}
    sips -z "$px" "$px" "$ICONDIR/icon_1024.png" --out "$ICONSET/icon_${name}.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ICONDIR/AppIcon.icns"

echo "==> 3/5 组装 bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/SwiftMon" "$APP/Contents/MacOS/SwiftMon"
cp "$ICONDIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>SwiftMon</string>
    <key>CFBundleDisplayName</key>       <string>SwiftMon</string>
    <key>CFBundleExecutable</key>        <string>SwiftMon</string>
    <key>CFBundleIdentifier</key>        <string>local.swiftmon.app</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <!-- 默认以菜单栏形态运行（无 Dock 图标）。应用内可用 ⌘⇧D 或
         「SwiftMon ▸ 在 Dock 中显示图标」切回来。 -->
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string>Local build. Layout inspired by macmon (MIT).</string>
</dict>
</plist>
PLIST

echo "==> 4/5 校验"
plutil -lint "$APP/Contents/Info.plist"
iconutil -c iconset "$APP/Contents/Resources/AppIcon.icns" -o "$ICONDIR/verify.iconset"
echo "    iconset 尺寸: $(ls "$ICONDIR/verify.iconset" | wc -l | tr -d ' ') 个"

echo "==> 5/5 完成"
echo "    $APP"

if [ "$INSTALL" -eq 1 ]; then
    # 覆盖前先退掉正在运行的实例（否则旧进程还占着旧二进制）
    pkill -f "SwiftMon.app/Contents/MacOS/SwiftMon" 2>/dev/null || true
    sleep 1
    rm -rf "$SYSTEM_APP"
    cp -R "$APP" "$SYSTEM_APP"
    echo "    已安装到 $SYSTEM_APP"
fi

if [ "$OPEN_AFTER" -eq 1 ]; then
    pkill -f "SwiftMon.app/Contents/MacOS/SwiftMon" 2>/dev/null || true
    sleep 1
    if [ "$INSTALL" -eq 1 ]; then
        open "$SYSTEM_APP"
        echo "    已从 $SYSTEM_APP 启动"
    else
        open "$APP"
        echo "    已从 $APP 启动"
    fi
fi
