cmake_minimum_required(VERSION 3.21)
project(ibaotv-native-luneos VERSION 0.2.2 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")

find_package(Qt6 6.4 REQUIRED COMPONENTS Core Gui Qml Quick QuickControls2 Network Multimedia)
find_package(Python3 REQUIRED COMPONENTS Interpreter)

set(SHARED_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/..")
set(GENERATED_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/generated")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    "${SHARED_DIRECTORY}/qml/Main.qml"
    "${SHARED_DIRECTORY}/sailfish/src/backend.cpp"
    "${SHARED_DIRECTORY}/sailfish/src/downloader.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/generate-sources.py")
execute_process(COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/generate-sources.py"
    "${SHARED_DIRECTORY}" "${GENERATED_DIRECTORY}" COMMAND_ERROR_IS_FATAL ANY)

qt_add_executable(ibaotv-native
    src/main.cpp src/downloadadapter.h
    "${GENERATED_DIRECTORY}/backend.cpp" "${SHARED_DIRECTORY}/sailfish/src/backend.h"
    "${GENERATED_DIRECTORY}/downloader.cpp" "${SHARED_DIRECTORY}/sailfish/src/downloader.h")
target_include_directories(ibaotv-native PRIVATE "${SHARED_DIRECTORY}/sailfish/src")
target_link_libraries(ibaotv-native PRIVATE
    Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::QuickControls2 Qt6::Network Qt6::Multimedia)
target_link_options(ibaotv-native PRIVATE "LINKER:--as-needed")
qt_add_resources(ibaotv-native ibaotv-qml PREFIX "/qml" BASE "${GENERATED_DIRECTORY}/qml"
    FILES "${GENERATED_DIRECTORY}/qml/Main.qml")
qt_add_resources(ibaotv-native ibaotv-video PREFIX "/qml" BASE "${CMAKE_CURRENT_SOURCE_DIR}/qml"
    FILES "${CMAKE_CURRENT_SOURCE_DIR}/qml/LuneVideo.qml")
set_target_properties(ibaotv-native PROPERTIES INSTALL_RPATH "")

set(IBAOTV_WEBP_PLUGIN "${CMAKE_CURRENT_SOURCE_DIR}/.sdk/plugins/imageformats/libqwebp.so"
    CACHE FILEPATH "Qt6 WebP image plugin for the target architecture")
if(NOT EXISTS "${IBAOTV_WEBP_PLUGIN}")
    message(FATAL_ERROR "Run python3 luneos/fetch-webp.py or set IBAOTV_WEBP_PLUGIN")
endif()
install(FILES "${IBAOTV_WEBP_PLUGIN}" DESTINATION plugins/imageformats)
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/.sdk/licenses/qt6-imageformats-copyright")
    install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/.sdk/licenses/qt6-imageformats-copyright" DESTINATION licenses)
endif()
install(TARGETS ibaotv-native RUNTIME DESTINATION bin)
install(PROGRAMS packaging/ibaotv-native packaging/luna-call DESTINATION .)
install(FILES packaging/appinfo.json DESTINATION .)
install(FILES "${SHARED_DIRECTORY}/ibaotv-native-256.png" DESTINATION . RENAME icon.png)
