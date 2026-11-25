ibaotv_qt6_environment() {
    qt6_prefix="$1"
    library_directory="$qt6_prefix/lib"
    for directory in "$qt6_prefix"/lib/*-linux-gnu; do
        if [[ -d "$directory" ]]; then
            library_directory="$directory"
            break
        fi
    done
    sdk_base_library_directory="$qt6_prefix/../lib"
    export LD_LIBRARY_PATH="/usr/lib64:/lib64:$library_directory:$library_directory/pulseaudio:$qt6_prefix/lib:$sdk_base_library_directory/${library_directory##*/}:$sdk_base_library_directory${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export QT_PLUGIN_PATH="$library_directory/qt6/plugins:$qt6_prefix/plugins"
    export QML_IMPORT_PATH="$library_directory/qt6/qml:$qt6_prefix/qml"
    export QML2_IMPORT_PATH="$QML_IMPORT_PATH"
    unset QMLSCENE_DEVICE QT_GSTREAMER_PLAYBIN_FLAGS QT_GSTREAMER_CAMERABIN_FLAGS QT_GSTREAMER_CAMERABIN_SRC
}
