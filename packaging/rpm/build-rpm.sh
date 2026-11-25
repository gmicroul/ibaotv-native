#!/bin/bash
# 打包 ibaotv-native 的 SailfishOS RPM。
# 用法: packaging/rpm/build-rpm.sh [输出目录]，默认输出到仓库 dist/
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
name=ibaotv-native
ver="$(grep -oP '^Version:\s*\K\S+' "$here/$name.spec")"
top="$name-$ver"
out="${1:-$repo/dist}"

mkdir -p "$out" "$HOME/rpmbuild/SOURCES" "$HOME/rpmbuild/SPECS" "$HOME/rpmbuild/BUILD" "$HOME/rpmbuild/RPMS" "$HOME/rpmbuild/SRPMS"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/$top"
cp -a "$repo/sailfish/." "$tmp/$top/"
rm -rf "$tmp/$top/build"

tar czf "$HOME/rpmbuild/SOURCES/$top.tar.gz" -C "$tmp" "$top"
cp "$here/$name.spec" "$HOME/rpmbuild/SPECS/"

rpmbuild -bb "$HOME/rpmbuild/SPECS/$name.spec"
cp -f "$HOME"/rpmbuild/RPMS/*/"$name-$ver"-*.rpm "$out"/
echo "RPM 输出: $out"
ls -la "$out"/"$name-$ver"-*.rpm
