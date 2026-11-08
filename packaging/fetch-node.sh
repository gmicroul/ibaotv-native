#!/bin/bash
# 取官方 node（arm64，自包含，供 click 自带；deb 走系统 nodejs 不用它）。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../.."
NODE_VER="v22.20.0"
NODE_SHA="06907b9c088ce62305bc1530e5c1ae1510245114645768f7750c349c5b6fe667"
OUT="$SRC/node/bin/node"

if [ -x "$OUT" ]; then
  echo "bundled node 已存在：$OUT"
  "$OUT" --version
  exit 0
fi

echo "==> 下载 node $NODE_VER（arm64）"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
URL="https://nodejs.org/dist/$NODE_VER/node-$NODE_VER-linux-arm64.tar.xz"
curl -sSL -o "$TMP/node.tar.xz" "$URL"
echo "$NODE_SHA  $TMP/node.tar.xz" | sha256sum -c -

echo "==> 解包 bin/node（本机 GNU tar 有 bug，走 python）"
mkdir -p "$SRC/node/bin"
python3 - "$TMP/node.tar.xz" "$OUT" <<'PY'
import sys, tarfile, os
src, dst = sys.argv[1], sys.argv[2]
with tarfile.open(src, "r:xz") as tf:
    for m in tf.getmembers():
        if m.name.endswith("/bin/node"):
            with tf.extractfile(m) as fin, open(dst, "wb") as fout:
                fout.write(fin.read())
            break
os.chmod(dst, 0o755)
PY
"$OUT" --version
ls -l "$OUT"
