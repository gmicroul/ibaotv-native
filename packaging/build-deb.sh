#!/bin/bash
# 打 ibaotv-native 的 deb（arm64）：
#   /opt/ibaotv-native/（二进制 + node 数据层）+ /usr/bin 软链 +
#   /usr/share/{applications,icons}。nodeDir 由 applicationDirPath 自适应。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/.."
VER="0.2.1-1"
STAGE="$HERE/root"
DEB="$SRC/ibaotv-native_0.2.1-1_arm64.deb"

echo "==> 重新构建二进制"
"$SRC/build.sh"

echo "==> 铺 staging"
rm -rf "$STAGE"
mkdir -p "$STAGE/opt/ibaotv-native/node" \
         "$STAGE/usr/bin" \
         "$STAGE/usr/share/applications" \
         "$STAGE/usr/share/icons/hicolor/512x512/apps" \
         "$STAGE/usr/share/icons/hicolor/256x256/apps" \
         "$STAGE/usr/share/icons/hicolor/172x172/apps" \
         "$STAGE/usr/share/icons/hicolor/128x128/apps" \
         "$STAGE/usr/share/icons/hicolor/scalable/apps" \
         "$STAGE/DEBIAN"

cp "$SRC/ibaotv-native" "$STAGE/opt/ibaotv-native/"
cp "$SRC/node/xbweb.js" "$STAGE/opt/ibaotv-native/node/"
sed 's|^APP_DIR=.*|APP_DIR="/opt/ibaotv-native"|' "$SRC/ibaotv-launcher.sh" \
    > "$STAGE/opt/ibaotv-native/ibaotv-launcher.sh"
sed 's|^Exec=.*|Exec=/opt/ibaotv-native/ibaotv-launcher.sh|' "$SRC/ibaotv-native.desktop" \
    > "$STAGE/usr/share/applications/ibaotv-native.desktop"
cp "$SRC/ibaotv-native.png" "$STAGE/usr/share/icons/hicolor/512x512/apps/ibaotv-native.png"
cp "$SRC/ibaotv-native-256.png" "$STAGE/usr/share/icons/hicolor/256x256/apps/ibaotv-native.png"
cp "$SRC/ibaotv-native-172.png" "$STAGE/usr/share/icons/hicolor/172x172/apps/ibaotv-native.png"
cp "$SRC/ibaotv-native-128.png" "$STAGE/usr/share/icons/hicolor/128x128/apps/ibaotv-native.png"
cp "$SRC/ibaotv-native.svg" "$STAGE/usr/share/icons/hicolor/scalable/apps/ibaotv-native.svg"
ln -s /opt/ibaotv-native/ibaotv-native "$STAGE/usr/bin/ibaotv-native"

cat > "$STAGE/DEBIAN/control" <<'EOF'
Package: ibaotv-native
Version: 0.2.1-1
Section: video
Priority: optional
Architecture: arm64
Maintainer: ibaotv-native contributors
Depends: nodejs, libqt5core5t64, libqt5gui5-gles, libqt5qml5, libqt5quick5-gles, libqt5multimedia5, libqt5network5t64, qml-module-qtquick2, qml-module-qtquick-layouts, qml-module-qtquick-window2, qml-module-qtquick-controls2, qml-module-qtmultimedia
Description: Xiaobao Cinema native client for Ubuntu Touch
 Native client for ibaotv.com: category browsing, search, episode
 picker and HLS (m3u8) playback via media-hub. Native Qt Quick UI
 with resume, autoplay-next, speed, mini window and history.
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst"

chmod 755 "$STAGE/opt/ibaotv-native/ibaotv-native" \
          "$STAGE/opt/ibaotv-native/ibaotv-launcher.sh"
chmod 644 "$STAGE/opt/ibaotv-native/node/xbweb.js"

echo "==> 组装 deb（本机 GNU tar 有 bug，走 python+ar）"
python3 "$HERE/mkdeb.py" "$STAGE" "$DEB"
ls -l "$DEB"
