#!/bin/sh
# ibaotv-native 启动脚本（Lomiri 原生 mirclient 平台）
HOME_DIR=/home/phablet
APP_DIR="$HOME_DIR/ibaotv"
LOG=/tmp/ibaotv-native.log

for pid in $(pgrep -f "$APP_DIR/ibaotv-native" 2>/dev/null); do
    [ "$pid" = "$$" ] && continue
    kill "$pid" 2>/dev/null
done
sleep 0.4

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export QT_QPA_PLATFORM=ubuntumirclient
export XDG_SESSION_TYPE="${XDG_SESSION_TYPE:-mir}"
[ -S /run/user/$(id -u)/bus ] || sleep 1

echo "=== 启动 $(date '+%H:%M:%S') pid=$$ ===" >> "$LOG"
exec "$APP_DIR/ibaotv-native" "$@" >> "$LOG" 2>&1
