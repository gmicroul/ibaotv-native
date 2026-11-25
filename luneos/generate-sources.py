import argparse
from pathlib import Path
import re


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise RuntimeError("Expected exactly one source fragment: " + old)
    return source.replace(old, new, 1)


def generate(source_directory, output_directory):
    output_directory.mkdir(parents=True, exist_ok=True)
    for name in ("backend.cpp", "downloader.cpp"):
        source = (source_directory / "sailfish/src" / name).read_text(encoding="utf-8")
        source = replace_once(
            source,
            "req.setAttribute(QNetworkRequest::FollowRedirectsAttribute, true);",
            "req.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);",
        )
        (output_directory / name).write_text(source, encoding="utf-8")

    source = (source_directory / "qml/Main.qml").read_text(encoding="utf-8")
    source = "\n".join((
        "import QtQuick", "import QtQuick.Window", "import QtQuick.Layouts",
        "import QtQuick.Controls", "import QtMultimedia", "import QtSensors", "",
    )) + "\nApplicationWindow {" + source.split("ApplicationWindow {", 1)[1]
    source = replace_once(source, "    visible: true\n", "    visible: false\n")
    source = replace_once(source, "    Screen.orientationUpdateMask: Qt.PortraitOrientation\n", "")
    source = replace_once(source, "        Video {\n", "        LuneVideo {\n")
    source = re.sub(r"MediaPlayer\.Buffered\b", "MediaPlayer.BufferedMedia", source)
    source = replace_once(source, "var merged = keep.concat(cards)", "var merged = keep.concat(Array.from(cards))")
    source = replace_once(source, "episodes = d.episodes || []", "episodes = Array.from(d.episodes || [])")
    source = replace_once(source, "                    onClicked: root.playAt(index)",
                          "                    onClicked: Qt.callLater(root.playAt, index)")
    source = replace_once(source, "        onActiveChanged: {", "        function onActiveChanged() {")
    source, visual_count = re.subn(
        r"^(    (?:StackView|Item|Rectangle) \{\n)",
        r"\1        parent: landscapeSurface\n", source, flags=re.MULTILINE,
    )
    if visual_count != 4:
        raise RuntimeError("The player surface layout changed")
    orientation = '''
    property int playerOrient: 0
    property int sensedPlayerAngle: 0
    readonly property int playerAngle: !playerActive ? 0
        : playerOrient === 1 ? 90 : playerOrient === 2 ? 0 : sensedPlayerAngle

    function orientLabel() {
        return playerOrient === 1 ? "横屏" : playerOrient === 2 ? "竖屏" : "自动"
    }
    function cyclePlayerOrient() {
        playerOrient = (playerOrient + 1) % 3
        backend.setPlayerOrient(playerOrient)
        showControls = true
        hideUITimer.restart()
    }

    OrientationSensor {
        active: root.playerActive && root.playerOrient === 0 && !startupOffline
        onReadingChanged: {
            if (!reading)
                return
            if (reading.orientation === OrientationReading.LeftUp)
                root.sensedPlayerAngle = -90
            else if (reading.orientation === OrientationReading.RightUp)
                root.sensedPlayerAngle = 90
            else if (reading.orientation === OrientationReading.TopUp)
                root.sensedPlayerAngle = 0
            else if (reading.orientation === OrientationReading.TopDown)
                root.sensedPlayerAngle = 180
        }
    }

    Item {
        id: landscapeSurface
        objectName: "ibaotvSurface"
        anchors.centerIn: parent
        width: Math.abs(root.playerAngle) % 180 === 90 ? parent.height : parent.width
        height: Math.abs(root.playerAngle) % 180 === 90 ? parent.width : parent.height
        rotation: root.playerAngle
    }
'''
    source = replace_once(source, "    Timer {\n        id: autoRetryTimer",
                          orientation + "\n    Timer {\n        id: autoRetryTimer")
    source = replace_once(source, "        id: videoLayer\n", '        id: videoLayer\n        objectName: "ibaotvVideoLayer"\n')
    source = replace_once(source, "        id: playerOSD\n", '        id: playerOSD\n        objectName: "ibaotvControls"\n')
    source = replace_once(source, '                Button {\n                    text: "小窗"',
                          '''                Button {
                    objectName: "ibaotvOrientationButton"
                    text: root.orientLabel()
                    flat: true
                    font.pixelSize: 30
                    onClicked: root.cyclePlayerOrient()
                }
                Button {
                    text: "小窗"''')
    source = replace_once(source, '                    Switch {\n                        Layout.leftMargin: root.pageMargin\n                        text: "后台继续播放"',
                          '''                    Button {
                        Layout.leftMargin: root.pageMargin
                        flat: true
                        font.pixelSize: 34
                        text: "播放方向：" + root.orientLabel()
                        onClicked: root.cyclePlayerOrient()
                    }
                    Switch {
                        Layout.leftMargin: root.pageMargin
                        text: "后台继续播放"''')
    source = source.replace("（UT 无悬浮窗，画面只在应用内）", "（画面只在应用卡片内）")
    source = replace_once(source, "                            model: root.tabState[ti].cards\n",
                          '                            objectName: "ibaotvFeed" + ti\n                            model: root.tabState[ti].cards\n')
    source = replace_once(source, '        loadTab(0, true, "")\n',
                          '        if (!startupOffline)\n            loadTab(0, true, "")\n')
    source = replace_once(source, '            objectName: "ibdetail"\n',
                          '            objectName: "ibdetail"\n            property alias episodeList: detailList\n')
    diagnostics = '''
    function smokePages() {
        var pages = [detailPage, downloadsPage, historyPage, settingsPage, playerPage]
        for (var pageIndex = 0; pageIndex < pages.length; pageIndex++) {
            stack.push(pages[pageIndex], StackView.Immediate)
            if (!stack.currentItem)
                return false
            stack.pop(StackView.Immediate)
        }
        return true
    }

    function testList(tid) {
        var categoryIndex = 0
        for (var tabIndex = 0; tabIndex < tabDefs.length; tabIndex++) {
            if (tabDefs[tabIndex].tid === tid)
                categoryIndex = tabIndex
        }
        tabIdx = categoryIndex
        loadTab(categoryIndex, true, "")
        return tabState[categoryIndex].cards.length
    }

    function testSearch(keyword) {
        tabIdx = 0
        searchField.text = keyword
        doSearch()
        return tabState[0].cards.length
    }

    function playDirect(url) {
        dSid = ""
        dTitle = "播放自检"
        episodes = []
        curIdx = -1
        wantPlay = true
        pendingSeek = -1
        stack.push(playerPage, StackView.Immediate)
        curFile = url
        kickTimer.restart()
    }

    function prepareEpisodeTest(seriesId, episodeNumber) {
        if (!openDetail(seriesId))
            return false
        var episodeIndex = Number(episodeNumber) - 1
        if (episodeIndex < 0 || episodeIndex >= episodes.length)
            return false
        var episodeList = stack.currentItem.episodeList
        episodeList.currentIndex = episodeIndex
        episodeList.forceLayout()
        episodeList.positionViewAtIndex(episodeIndex, ListView.Center)
        return true
    }

    function clickEpisodeTest() {
        var episodeList = stack.currentItem && stack.currentItem.episodeList
        if (!episodeList || !episodeList.currentItem)
            return false
        var episodeDelegate = episodeList.currentItem
        episodeList.currentIndex = -1
        episodeDelegate.clicked()
        return true
    }

    function testOrientation(orientation) {
        playerOrient = orientation
        if (!playerActive)
            stack.push(playerPage, StackView.Immediate)
        return true
    }
'''
    source = replace_once(source, "    Component.onCompleted: {\n        playRate = backend.playbackRate()",
                          diagnostics + "\n    Component.onCompleted: {\n        playerOrient = backend.playerOrient()\n        playRate = backend.playbackRate()")
    qml_directory = output_directory / "qml"
    qml_directory.mkdir(exist_ok=True)
    (qml_directory / "Main.qml").write_text(source, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description="Generate LuneOS Qt6 variants without changing Qt5 sources")
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    arguments = parser.parse_args()
    generate(arguments.source.resolve(), arguments.output.resolve())


if __name__ == "__main__":
    main()
