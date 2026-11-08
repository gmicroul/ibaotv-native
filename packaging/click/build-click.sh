#!/bin/bash
# 打 ibaotv-native 的 click 包（装用户空间，不用解根分区只读）。
# 未受限模板：自带 node 跑数据层，站点为纯 HTTPS GET。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../.."
STAGE="$HERE/stage/ibaotv.utu"

echo "==> 重新构建二进制"
"$SRC/build.sh"

echo "==> 准备自带 node"
NODE="$SRC/node/bin/node"
if [ ! -x "$NODE" ]; then
    NODE="/home/phablet/huoguo/packaging/click/stage/hongguo.utu/node/bin/node"
fi
if [ ! -x "$NODE" ]; then
    echo "缺 node 二进制：请运行 packaging/fetch-node.sh" >&2
    exit 1
fi

echo "==> 铺 staging"
rm -rf "$STAGE"
mkdir -p "$STAGE/node/bin"
cp "$HERE/src/manifest.json" "$HERE/src/ibaotv.apparmor" "$HERE/src/ibaotv.desktop" "$STAGE/"
cp "$SRC/ibaotv-native.png" "$STAGE/ibaotv.png"
cp "$SRC/ibaotv-native" "$STAGE/ibaotv-native"
cp "$SRC/node/xbweb.js" "$STAGE/node/"
cp "$NODE" "$STAGE/node/bin/node"
chmod 755 "$STAGE/ibaotv-native" "$STAGE/node/bin/node"

echo "==> click build"
cd "$HERE/stage"
rm -f ibaotv.utu_*.click
click build ibaotv.utu
ls -l "$HERE"/stage/*.click
echo "安装：pkcon install-local <click>（或用 OpenStore 打开），装完在启动器搜“小宝”"
