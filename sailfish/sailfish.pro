TARGET = ibaotv-native
TEMPLATE = app

CONFIG += sailfishapp sailfishapp_no_deploy_qml c++11
QT += quick qml network multimedia

SOURCES += \
    src/main.cpp \
    src/backend.cpp \
    src/downloader.cpp

HEADERS += \
    src/backend.h \
    src/downloader.h

RESOURCES += qml.qrc

SAILFISHAPP_ICONS = 86x86 128x128 172x172 256x256

DEFINES += QT_NO_CAST_FROM_ASCII

target.path = /usr/bin
INSTALLS += target
