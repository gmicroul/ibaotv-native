#!/bin/bash
set -euo pipefail
source_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
device="${1:-root@192.168.2.160}"
package="${2:-$source_directory/dist/ibaotv-native-luneos_0.2.2-1_aarch64.ipk}"
if [[ $# -gt 2 || ! -f "$package" ]]; then
    printf 'Usage: bash %s [root@device] [package.ipk]\nBuild the package with luneos/build.sh first.\n' "$0" >&2
    exit 2
fi
known_hosts="${IBAOTV_KNOWN_HOSTS:-${HOME}/.ssh/known_hosts}"
upload_directory=$(mktemp -d /tmp/ibaotv-luneos-upload.XXXXXX)
trap 'rm -rf -- "$upload_directory"' EXIT
cp -- "$package" "$upload_directory/ibaotv.ipk"
cp -- "$source_directory/install.py" "$source_directory/packaging/luna-call" "$upload_directory/"
remote_command=$(cat <<'REMOTE'
set -eu
temporary_directory=$(mktemp -d /tmp/ibaotv-luneos-deploy.XXXXXX)
trap 'rm -rf -- "$temporary_directory"' EXIT
tar -xf - -C "$temporary_directory"
chmod 755 "$temporary_directory/luna-call"
python3 "$temporary_directory/install.py" "$temporary_directory/ibaotv.ipk"
application_directory=/media/cryptofs/apps/usr/palm/applications/org.ibaotv.native
"$temporary_directory/luna-call" luna://com.webos.applicationManager/getAppInfo '{"id":"org.ibaotv.native"}'
PULSE_SERVER=unix:/run/pulse/native "$application_directory/bin/ibaotv-native" --smoke-test
"$application_directory/bin/ibaotv-native" --test-orientation
"$temporary_directory/luna-call" luna://com.webos.applicationManager/launch '{"id":"org.ibaotv.native"}'
sleep 2
python3 -c 'from pathlib import Path; import sys; executable = Path(sys.argv[1]).resolve(); running = any(entry.resolve() == executable for entry in Path("/proc").glob("[0-9]*/exe")); print("IBAOTV_RUNNING", running); sys.exit(0 if running else 1)' "$application_directory/bin/ibaotv-native"
REMOTE
)
tar -C "$upload_directory" -cf - ibaotv.ipk install.py luna-call | \
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=$known_hosts" -- "$device" "$remote_command"
