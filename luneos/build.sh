#!/bin/bash
set -euo pipefail
source_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
build_directory="${IBAOTV_BUILD_DIR:-$source_directory/build}"
qt6_prefix="${IBAOTV_QT6_PREFIX:-$source_directory/.sdk/usr}"
if [[ $# != 0 || ! -d "$qt6_prefix" ]]; then
    printf 'Set IBAOTV_QT6_PREFIX to a native Qt6 >= 6.4 development prefix.\nUsage: bash %s\n' "$0" >&2
    exit 2
fi
source "$source_directory/environment.sh"
ibaotv_qt6_environment "$qt6_prefix"
cmake -S "$source_directory" -B "$build_directory" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$qt6_prefix" \
    -DQt6_DIR="$library_directory/cmake/Qt6" \
    -DPython3_EXECUTABLE="$(command -v python3)" \
    -DCMAKE_LIBRARY_PATH="$library_directory" \
    -DCMAKE_INCLUDE_PATH="$qt6_prefix/include" \
    -DCMAKE_BUILD_RPATH="$library_directory;$qt6_prefix/lib" \
    -DIBAOTV_WEBP_PLUGIN="${IBAOTV_WEBP_PLUGIN:-$source_directory/.sdk/plugins/imageformats/libqwebp.so}" \
    -DCMAKE_INSTALL_PREFIX=/usr/palm/applications/org.ibaotv.native
cmake --build "$build_directory" --parallel "${IBAOTV_BUILD_JOBS:-4}"
stage_directory="$build_directory/stage"
mkdir -p "$stage_directory"
DESTDIR="$stage_directory" cmake --install "$build_directory" --strip
python3 "$source_directory/package.py" "$stage_directory" "$source_directory/dist"
