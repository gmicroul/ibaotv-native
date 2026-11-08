#!/bin/bash
# 构建 ibaotv-native（Qt Quick + QtMultimedia，Lomiri/mirclient 平台）
# 复用 ~/opt/qtdev 的 Qt5 工具链，不需要 root、不需要 clickable。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QT_PREFIX="$HOME/opt/qtdev"
QT_INC="$QT_PREFIX/usr/include/aarch64-linux-gnu/qt5"
QT_LIB="$QT_PREFIX/usr/lib/aarch64-linux-gnu"
QT_BIN="$QT_PREFIX/usr/lib/qt5/bin"
BUILD="$HERE/build"
OUT="$HERE/ibaotv-native"

[ -d "$QT_INC" ] || { echo "Qt5 头文件缺失: $QT_INC" >&2; exit 1; }
[ -x "$QT_BIN/moc" ] || { echo "moc 缺失: $QT_BIN/moc" >&2; exit 1; }

mkdir -p "$BUILD"
cd "$HERE"

INCLUDES="-I$QT_PREFIX/usr/include -I$QT_INC -I$QT_INC/QtCore -I$QT_INC/QtGui \
-I$QT_INC/QtQml -I$QT_INC/QtQuick -I$QT_INC/QtMultimedia -I$QT_INC/QtNetwork"
CXXFLAGS="-fPIC -std=c++14 -O2 -DQT_NO_DEBUG $INCLUDES"
LDFLAGS="-L$QT_LIB -L/usr/lib/aarch64-linux-gnu -pie -rdynamic"
LIBS="-lQt5Multimedia -lQt5Quick -lQt5Qml -lQt5Gui -lQt5Core -lQt5Network"

echo "==> moc"
"$QT_BIN/moc" main.cpp -o "$BUILD/main.moc"

echo "==> rcc"
"$QT_BIN/rcc" qml.qrc -o "$BUILD/qrc_qml.cpp"

echo "==> compile"
g++ $CXXFLAGS -I"$BUILD" -c main.cpp -o "$BUILD/main.o"
g++ $CXXFLAGS -c "$BUILD/qrc_qml.cpp" -o "$BUILD/qrc_qml.o"

echo "==> link"
g++ $LDFLAGS "$BUILD/main.o" "$BUILD/qrc_qml.o" $LIBS -o "$OUT"

echo "built $OUT"
