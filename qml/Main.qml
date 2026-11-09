import QtQuick 2.15
import QtQuick.Window 2.12
import QtQuick.Layouts 1.3
import QtQuick.Controls 2.5
import QtMultimedia 5.15

// ibaotv-native（Ubuntu Touch 本机版）
// 交互对照红果原生版：目录海报列表 / 搜索 / 详情选集 / 播放（上下滑切集、
// 左右拖快进、倍速、自动隐、小窗、断点续播、记录、设置）。
// 数据来自 ibaotv.com，播放走播放页里的 m3u8 直链，media-hub 直接解码。
ApplicationWindow {
    id: root
    width: 1080
    height: 2280
    visible: true
    color: "#121212"
    title: "小宝影院"
    Screen.orientationUpdateMask: Qt.PortraitOrientation

    readonly property color cPrimary: "#ffffff"
    readonly property color cSecondary: "#8d8d8d"
    readonly property color cHighlight: "#00b2ff"
    readonly property int pageMargin: 32

    palette.buttonText: cPrimary
    palette.windowText: cPrimary
    palette.text: cPrimary
    palette.highlight: cHighlight
    palette.highlightedText: "#ffffff"

    // ---- 分类（tid 对应站点分类） ----
    property var tabDefs: [
        { tid: "1", name: "电影" },
        { tid: "2", name: "连续剧" },
        { tid: "4", name: "动漫" },
        { tid: "3", name: "综艺" },
        { tid: "21", name: "纪录片" }
    ]
    property int tabIdx: 0
    function freshTab() {
        return { cards: [], page: 0, pagecount: 1, done: false, loading: false, kw: "" }
    }
    property var tabState: [freshTab(), freshTab(), freshTab(), freshTab(), freshTab()]
    property bool netBusy: false
    property var pendingLoad: null
    property string statusMsg: ""

    // ---- 详情 ----
    property string dSid: ""
    property string dTitle: ""
    property string dCover: ""
    property string dIntro: ""
    property string dMeta: ""
    property string dUpdated: ""
    property string dTotal: ""
    property var episodes: []
    property int curIdx: -1
    property int posRevision: 0

    // ---- 播放 ----
    property string curFile: ""
    property bool fetching: false
    property bool seekDragging: false
    property double lastSwitch: 0
    property bool headerVisible: true
    property double playRate: 1.0
    property bool showControls: true
    property var historyList: []
    property string lastResumeText: ""
    property int errRetry: 0
    property string retrySid: ""
    property int retryIdx: -1
    property var retryEps: null
    property bool autoRetried: false
    property bool fromAuto: false
    property double loadStartMs: 0
    property bool wantPlay: false
    property double lastPos: -1
    property double lastAdvanceMs: 0
    property bool loadStuck: false
    property double pendingSeek: -1
    property double lastSeekTarget: -1
    property bool miniVisible: curFile !== "" && !fetching
        && stack.currentItem && stack.currentItem.objectName !== "ibplayer"
    property bool playerActive: stack.currentItem && stack.currentItem.objectName === "ibplayer"
    property bool localPlaying: curFile !== "" && curFile.indexOf("http") !== 0
    property bool isPlaying: video.playbackState === MediaPlayer.PlayingState
    property bool isLoading: video.status === MediaPlayer.LoadingMedia
        || video.status === MediaPlayer.BufferingMedia
        || video.status === MediaPlayer.StalledMedia
    property bool hasLoadError: statusMsg.indexOf("播放出错") === 0
        || statusMsg.indexOf("取流失败") === 0

    Timer {
        id: autoRetryTimer
        interval: 2500
        repeat: false
        onTriggered: {
            if (retryIdx < 0 || dSid !== retrySid || episodes !== retryEps)
                return
            fromAuto = true
            playAt(retryIdx)
        }
    }

    function metaLine(c) {
        var s = ""
        if (c.year) s += c.year
        if (c.cls) s += (s !== "" ? " · " : "") + c.cls
        if (c.area) s += (s !== "" ? " · " : "") + c.area
        if (c.remarks) s += (s !== "" ? " · " : "") + c.remarks
        return s
    }
    function epText() {
        if (curIdx >= 0 && curIdx < episodes.length)
            return episodes[curIdx].label || ("第" + (curIdx + 1) + "集")
        return ""
    }
    function posKeyByIndex(i) {
        if (i < 0 || i >= episodes.length)
            return ""
        return dSid + "_" + episodes[i].nid
    }
    function curKey() { return posKeyByIndex(curIdx) }
    function curVid() {
        if (curIdx >= 0 && curIdx < episodes.length)
            return episodes[curIdx].nid
        return ""
    }
    function epLabel(ep) {
        var rev = posRevision
        var pos = backend.loadPos(dSid + "_" + ep.nid)
        void rev
        return ep.label + (pos > 5000 ? " · 已看" : "")
    }
    function fmt(ms) { return backend.durationText(ms) }
    function fileUrl() {
        if (root.curFile === "")
            return ""
        if (root.curFile.indexOf("http") === 0)
            return root.curFile
        return "file://" + encodeURI(root.curFile)
    }
    function activeVideo() { return video }

    // ---- 下载 ----
    function dlInfo(nid) {
        var list = downloader.tasks
        for (var i = 0; i < list.length; i++) {
            if (String(list[i].nid) === String(nid) && String(list[i].vod) === String(dSid))
                return list[i]
        }
        return null
    }
    function dlBtnText(d) {
        if (!d)
            return "下载"
        if (d.status === "已完成")
            return "已下"
        if (d.status === "失败" || d.status === "已取消" || d.status === "已中断")
            return "重试"
        if (d.percent > 0 && d.percent < 100)
            return d.percent + "%"
        return "…"
    }
    function downloadEpisode(i) {
        if (i < 0 || i >= episodes.length)
            return
        if (root.localPlaying) {
            statusMsg = "当前已是本地文件"
            return
        }
        var ep = episodes[i]
        var d = root.dlInfo(ep.nid)
        if (d && d.status && d.status !== "失败" && d.status !== "已取消" && d.status !== "已中断") {
            statusMsg = "已在下载列表：" + (ep.label || ("第" + (i + 1) + "集"))
            return
        }
        statusMsg = "取流中…"
        var url = backend.playUrl(dSid, ep.sid || "1", ep.nid)
        if (url === "") {
            statusMsg = "取流失败，无法下载"
            return
        }
        downloader.start(dSid, dTitle, dCover, ep.sid || "1", ep.nid,
                         ep.label || ("第" + (i + 1) + "集"), i, url)
        statusMsg = "已加入下载：" + (ep.label || ("第" + (i + 1) + "集"))
    }
    function playLocal(t) {
        if (!t || t.status !== "已完成" || !t.file)
            return
        try {
            if (curIdx >= 0 && curIdx < episodes.length && video.duration > 0)
                backend.savePos(root.curKey(), video.position)
        } catch (e) {}
        dSid = t.vod
        dTitle = t.title || t.vod
        dCover = t.cover || ""
        dIntro = ""
        dMeta = "已下载 · " + (t.label || "")
        dUpdated = ""
        dTotal = "1"
        episodes = [{ sid: t.sid || "1", nid: t.nid, label: t.label || "正片" }]
        curIdx = 0
        posRevision++
        wantPlay = true
        errRetry = 0
        autoRetried = false
        fromAuto = false
        showControls = true
        curFile = t.file
        if (!playerActive)
            stack.push(playerPage)
        kickTimer.restart()
    }
    function reloadAt(ms) {
        if (root.curFile === "")
            return
        try { video.seekDone = true } catch (e) {}
        root.pendingSeek = Math.max(0, ms)
        root.lastPos = -1
        root.loadStuck = false
        var f = root.curFile
        root.curFile = ""
        root.curFile = f
        wantPlay = true
        loadStartMs = Date.now()
        lastAdvanceMs = Date.now()
        pendingSeekTimer.restart()
        kickTimer.restart()
    }
    function doSeek(target) {
        if (root.curFile === "")
            return
        if (target < 0)
            target = 0
        if (video.duration > 0 && target > video.duration - 1000)
            target = Math.max(0, video.duration - 1000)
        if (video.seekable) {
            video.seek(target)
        } else {
            root.reloadAt(target)
        }
        root.showControls = true
        hideUITimer.restart()
    }
    function jumpBy(deltaMs) {
        if (root.curFile === "" || root.fetching)
            return
        var cur = root.seekDragging ? seekBar.value : video.position
        if (cur < 0)
            cur = 0
        root.doSeek(cur + deltaMs)
    }

    function onVideoError(who, code, estr) {
        if (root.curFile === "")
            return
        if (/open uri\s+because it can't be found/.test(estr))
            return
        backend.logLine("VIDEO-ERROR[" + who + "] code=" + code + " " + estr
            + " url=" + root.curFile + " rate=" + playRate)
        if (root.curFile !== "" && errRetry < 1) {
            errRetry++
            if (playRate !== 1.0) {
                playRate = 1.0
                backend.setPlaybackRate(1.0)
                video.playbackRate = 1.0
                statusMsg = "倍速不支持，已降回 1.0× 重试…"
            } else {
                statusMsg = "播放出错，重试中…"
            }
            var f = root.curFile
            root.curFile = ""
            root.curFile = f
            kickTimer.restart()
            return
        }
        statusMsg = "播放出错：" + estr
    }

    function setTab(i, st) {
        var a = tabState.slice()
        a[i] = st
        tabState = a
    }

    function loadTab(i, reset, kw) {
        var st = tabState[i]
        if (!st)
            return
        if (netBusy) {
            pendingLoad = { i: i, reset: reset, kw: kw }
            return
        }
        if (!reset && (st.loading || st.done))
            return
        var keyword = (kw === undefined) ? st.kw : kw
        var page = reset ? 1 : (st.page + 1)
        var keep = reset ? [] : st.cards
        setTab(i, { cards: keep, page: st.page, pagecount: st.pagecount,
                    done: false, loading: true, kw: keyword })
        netBusy = true
        if (i === tabIdx)
            statusMsg = keyword !== "" ? ("搜索“" + keyword + "”…") : ("加载" + tabDefs[i].name + "…")
        var res = keyword !== "" ? backend.searchList(keyword, page)
                                 : backend.rankList(tabDefs[i].tid, page)
        netBusy = false
        var cards = (res && res.cards) ? res.cards : []
        var pagecount = (res && res.pagecount) ? res.pagecount : 1
        var merged = keep.concat(cards)
        setTab(i, { cards: merged, page: page, pagecount: pagecount,
                    done: (page >= pagecount || cards.length === 0),
                    loading: false, kw: keyword })
        if (i === tabIdx) {
            if (merged.length === 0)
                statusMsg = keyword !== "" ? "没搜到，换个词试试" : "加载失败，点刷新重试"
            else
                statusMsg = ""
        }
        var p = pendingLoad
        pendingLoad = null
        if (p)
            loadTab(p.i, p.reset, p.kw)
    }

    function loadMore(i) {
        if (i !== tabIdx)
            return
        var st = tabState[i]
        if (!st || st.loading || st.done || st.cards.length === 0)
            return
        loadTab(i, false)
    }

    function refreshTab() {
        var st = tabState[tabIdx]
        loadTab(tabIdx, true, st ? st.kw : "")
    }

    function doSearch() {
        var kw = searchField.text.trim()
        if (kw === "") {
            loadTab(tabIdx, true, "")
            return
        }
        if (/^[0-9]{1,8}$/.test(kw)) {
            if (openDetail(kw))
                return
        }
        loadTab(tabIdx, true, kw)
    }

    function openDetail(sid) {
        sid = String(sid || "").trim()
        if (sid === "")
            return false
        statusMsg = "取详情…"
        var d = backend.detail(sid)
        if (!d || !d.title || !d.episodes || d.episodes.length === 0) {
            statusMsg = "详情失败，检查 ID 或网络"
            return false
        }
        dSid = String(d.sid || sid)
        dTitle = d.title || ""
        dCover = d.cover || ""
        dIntro = d.intro || ""
        var parts = []
        if (d.year) parts.push(d.year)
        if (d.cls) parts.push(d.cls)
        if (d.area) parts.push(d.area)
        dMeta = parts.join(" · ")
        dUpdated = d.updated || ""
        dTotal = String(d.total || (d.episodes || []).length)
        episodes = d.episodes || []
        statusMsg = ""
        var last = backend.loadLast()
        if (String(last.sid) === dSid) {
            for (var k = 0; k < episodes.length; k++) {
                if (String(episodes[k].nid) === String(last.vid)) {
                    statusMsg = "上次看到 " + (episodes[k].label || ("第 " + (k + 1) + " 集")) + "，可继续"
                    break
                }
            }
        }
        posRevision++
        if (stack.currentItem && stack.currentItem.objectName === "ibdetail")
            return true
        stack.push(detailPage)
        return true
    }

    function playAt(i) {
        if (i < 0 || i >= episodes.length)
            return
        var reuse = stack.currentItem && stack.currentItem.objectName === "ibplayer"
        var now = Date.now()
        if (reuse) {
            if (now - lastSwitch < 800)
                return
            if (fetching)
                return
        }
        lastSwitch = now
        if (!fromAuto) {
            autoRetried = false
            retryIdx = -1
        }
        fromAuto = false
        try {
            var av = root.activeVideo()
            if (curIdx >= 0 && curIdx < episodes.length && av && av.duration > 0) {
                backend.savePos(posKeyByIndex(curIdx), av.position)
                backend.saveHistory(dSid, dTitle, curIdx + 1, av.position, dCover)
            }
        } catch (e) {}
        curIdx = i
        var ep = episodes[i]
        if (!reuse) {
            curFile = ""
            stack.push(playerPage)
        }
        fetching = true
        showControls = true
        var url = backend.playUrl(dSid, ep.sid || "1", ep.nid)
        fetching = false
        if (url === "") {
            backend.logLine("playUrl FAIL sid=" + dSid + " nid=" + ep.nid)
            if (!autoRetried) {
                autoRetried = true
                retrySid = dSid
                retryIdx = i
                retryEps = episodes
                statusMsg = "取流失败，2 秒后自动重试…"
                autoRetryTimer.restart()
                return
            }
            statusMsg = "取流失败，换一集或重试"
            if (!reuse)
                stack.pop()
            return
        }
        statusMsg = ""
        backend.saveLast(dSid, ep.nid)
        backend.saveHistory(dSid, dTitle, i + 1, 0, dCover)
        refreshHistory()
        errRetry = 0
        if (url === curFile)
            curFile = ""
        curFile = url
        wantPlay = true
        loadStuck = false
        kickTimer.restart()
        backend.logLine("play nid=" + ep.nid + " url=" + url)
    }

    function switchEpisode(delta) {
        if (fetching)
            return
        if (curIdx + delta < 0 || curIdx + delta >= episodes.length) {
            statusMsg = delta > 0 ? "已是最后一集" : "已是第一集"
            return
        }
        playAt(curIdx + delta)
    }

    function minimizePlayer() {
        if (!stack.currentItem || stack.currentItem.objectName !== "ibplayer")
            return
        try {
            if (video.duration > 0)
                backend.savePos(root.curKey(), video.position)
        } catch (e) {}
        stack.pop()
    }

    function restorePlayer() {
        if (stack.busy)
            return
        if (!stack.currentItem || stack.currentItem.objectName !== "ibplayer") {
            wantPlay = true
            stack.push(playerPage)
            kickTimer.restart()
        }
    }

    function stopAndCloseMini() {
        wantPlay = false
        try { video.stop() } catch (e) {}
        if (curIdx >= 0 && curIdx < episodes.length) {
            backend.savePos(root.curKey(), 0)
            backend.saveHistory(dSid, dTitle, curIdx + 1, 0, dCover)
        }
        curFile = ""
        refreshHistory()
    }

    function refreshHistory() {
        historyList = backend.history()
        posRevision++
    }

    function refreshResume() {
        var last = backend.loadLast()
        lastResumeText = (last.sid && last.vid) ? "继续上次" : ""
    }

    function resumeLast() {
        var last = backend.loadLast()
        if (!last.sid)
            return
        if (!openDetail(last.sid))
            return
        for (var k = 0; k < episodes.length; k++) {
            if (String(episodes[k].nid) === String(last.vid)) {
                playAt(k)
                return
            }
        }
        statusMsg = "已打开上次剧集，选集继续"
    }

    function cycleSpeed() {
        var steps = [0.75, 1.0, 1.25, 1.5, 2.0]
        var idx = 0
        for (var i = 0; i < steps.length; i++) {
            if (Math.abs(steps[i] - playRate) < 0.01) { idx = i; break }
        }
        playRate = steps[(idx + 1) % steps.length]
        backend.setPlaybackRate(playRate)
        try { video.playbackRate = playRate } catch (e) {}
        showControls = true
        hideUITimer.restart()
    }

    Timer {
        id: hideUITimer
        interval: 3000
        repeat: false
        onTriggered: {
            if (searchField.activeFocus) {
                root.showControls = true
                return
            }
            var v = root.activeVideo()
            if (v && v.playbackState === MediaPlayer.PlayingState)
                root.showControls = false
        }
    }

    // ---- 常驻顶栏 ----
    header: ToolBar {
        visible: root.headerVisible && !root.playerActive
        background: Rectangle { color: "#121212" }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            spacing: 4
            Button {
                flat: true
                enabled: stack.depth > 1
                opacity: enabled ? 1.0 : 0.3
                Layout.preferredWidth: 96
                Layout.fillHeight: true
                background: Rectangle { color: "transparent" }
                contentItem: Label {
                    text: "<"
                    color: root.cPrimary
                    font.pixelSize: 48
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                onClicked: {
                    if (stack.currentItem && stack.currentItem.objectName === "ibplayer"
                            && stack.currentItem.stopAndSave)
                        stack.currentItem.stopAndSave()
                    stack.pop()
                }
            }
            TextField {
                id: searchField
                Layout.fillWidth: true
                placeholderText: "剧名或剧集 ID…"
                font.pixelSize: 36
                color: root.cPrimary
                placeholderTextColor: root.cSecondary
                background: Rectangle {
                    color: "#1e1e1e"
                    radius: 8
                }
                inputMethodHints: Qt.ImhNoPredictiveText
                onAccepted: root.doSearch()
            }
            Button {
                text: "搜"
                font.pixelSize: 34
                flat: true
                onClicked: root.doSearch()
            }
            Button {
                text: "记录"
                font.pixelSize: 32
                flat: true
                onClicked: {
                    root.refreshHistory()
                    if (!stack.currentItem || stack.currentItem.objectName !== "ibhistory")
                        stack.push(historyPage)
                }
            }
            Button {
                text: "设置"
                font.pixelSize: 32
                flat: true
                onClicked: {
                    if (!stack.currentItem || stack.currentItem.objectName !== "ibsettings")
                        stack.push(settingsPage)
                }
            }
        }
    }

    footer: Label {
        property bool playerBusy: stack.currentItem && stack.currentItem.objectName === "ibplayer"
            && (root.fetching || root.curFile === "")
        visible: (root.fetching ? backend.status : root.statusMsg) !== "" && !playerBusy
                 && !root.playerActive
        text: root.fetching ? backend.status : root.statusMsg
        color: root.cHighlight
        font.pixelSize: 30
        leftPadding: 16
        rightPadding: 16
        topPadding: 8
        bottomPadding: 8
        wrapMode: Text.Wrap
        background: Rectangle { color: "#121212" }
    }

    StackView {
        id: stack
        anchors.fill: parent
        initialItem: listPage
        onCurrentItemChanged: {
            if (!currentItem || currentItem.objectName !== "ibplayer")
                root.headerVisible = true
        }
    }

    // ---- 常驻 Video：全应用唯一解码 ----
    function syncVideoGeom() {
        if (root.curFile === "" || !video) {
            try { video.visible = false } catch (e) {}
            return
        }
        video.visible = true
        if (root.playerActive) {
            video.x = 0
            video.y = 0
            video.width = videoLayer.width
            video.height = videoLayer.height
        } else {
            var p = miniBox.mapToItem(videoLayer, 0, 0)
            video.x = p.x
            video.y = p.y + 72
            video.width = miniBox.width
            video.height = miniBox.height - 160
        }
    }
    onCurFileChanged: { syncVideoGeom(); geomTimer.restart(); if (root.curFile !== "") loadStartMs = Date.now() }
    onPlayerActiveChanged: { syncVideoGeom(); geomTimer.restart() }

    Timer {
        id: kickTimer
        interval: 800
        repeat: true
        onTriggered: {
            if (root.curFile === "" || root.fetching) {
                stop()
                return
            }
            if (video.playbackState === MediaPlayer.PlayingState) {
                if (video.duration > 0 && video.position === lastPos && wantPlay
                        && video.status !== MediaPlayer.BufferingMedia
                        && video.status !== MediaPlayer.StalledMedia
                        && Date.now() - lastAdvanceMs > 8000 && Date.now() - loadStartMs > 8000) {
                    var rp = video.position
                    backend.logLine("RELOAD-STALL pos=" + Math.round(rp))
                    loadStuck = true
                    if (rp > 1000) {
                        root.reloadAt(rp)
                    } else {
                        lastAdvanceMs = Date.now()
                        video.pause()
                        resumeTimer.restart()
                    }
                } else if (video.position !== lastPos) {
                    lastPos = video.position
                    lastAdvanceMs = Date.now()
                    loadStuck = false
                }
                return
            }
            if (video.playbackState === MediaPlayer.PausedState) {
                if (wantPlay && root.pendingSeek < 0)
                    video.play()
                else if (!wantPlay && root.pendingSeek < 0)
                    stop()
                return
            }
            if ((video.status === MediaPlayer.LoadedMedia || video.status === MediaPlayer.Buffered)
                    && video.playbackState === MediaPlayer.StoppedState) {
                video.play()
                return
            }
            if (Date.now() - loadStartMs > 25000
                    && video.playbackState === MediaPlayer.StoppedState
                    && video.status !== MediaPlayer.LoadingMedia
                    && video.status !== MediaPlayer.BufferingMedia
                    && video.status !== MediaPlayer.StalledMedia) {
                backend.logLine("WATCHDOG reload st=" + video.status + " url=" + root.curFile)
                root.loadStuck = true
                root.reloadAt(Math.max(0, video.position))
            }
        }
    }
    Timer {
        id: resumeTimer
        interval: 500
        repeat: false
        onTriggered: {
            if (wantPlay && root.curFile !== "" && !root.fetching
                    && video.playbackState === MediaPlayer.PausedState)
                video.play()
        }
    }
    Timer {
        id: pendingSeekTimer
        interval: 400
        repeat: true
        onTriggered: {
            if (root.pendingSeek < 0) {
                stop()
                return
            }
            var st = video.status
            if (st === MediaPlayer.LoadedMedia || st === MediaPlayer.Buffered
                    || st === MediaPlayer.EndOfMedia
                    || (video.duration > 0 && Date.now() - root.loadStartMs > 1500)) {
                var ps = root.pendingSeek
                root.pendingSeek = -1
                stop()
                if (ps > 0) {
                    video.seek(ps)
                    root.lastSeekTarget = ps
                    seekCheckTimer.restart()
                }
                kickTimer.restart()
            } else if (Date.now() - root.loadStartMs > 20000) {
                stop()
                root.pendingSeek = -1
                root.statusMsg = "定位失败，已从头播放"
            }
        }
    }
    Timer {
        id: seekCheckTimer
        interval: 3000
        repeat: false
        onTriggered: {
            if (root.lastSeekTarget < 0)
                return
            var t = root.lastSeekTarget
            root.lastSeekTarget = -1
            if (root.wantPlay && video.duration > 0
                    && Math.abs(video.position - t) > 8000) {
                backend.logLine("SEEK-RETRY target=" + Math.round(t)
                                + " pos=" + Math.round(video.position))
                video.position = t
            }
        }
    }
    Timer {
        id: geomTimer
        interval: 120
        repeat: false
        onTriggered: root.syncVideoGeom()
    }

    Item {
        id: videoLayer
        anchors.fill: parent
        z: 50
        visible: root.curFile !== ""
        Rectangle { anchors.fill: parent; color: "black"; visible: root.playerActive }
        onWidthChanged: root.syncVideoGeom()
        onHeightChanged: root.syncVideoGeom()
        Video {
            id: video
            autoLoad: true
            autoPlay: true
            fillMode: VideoOutput.PreserveAspectFit
            property bool seekDone: false
            onSourceChanged: seekDone = false
            source: root.fileUrl()
            onStatusChanged: {
                if ((status === MediaPlayer.LoadedMedia || status === MediaPlayer.Buffered)
                        && !seekDone && root.pendingSeek < 0) {
                    seekDone = true
                    if (playbackState === MediaPlayer.StoppedState) {
                        var sv = root.curKey()
                        if (sv !== "") {
                            var spos = backend.loadPos(sv)
                            if (spos > 5000 && spos < duration - 10000)
                                seek(spos)
                        }
                    }
                }
                if (status === MediaPlayer.EndOfMedia) {
                    var vv = root.curKey()
                    if (vv !== "")
                        backend.savePos(vv, 0)
                    if (backend.autoNext() && root.curIdx + 1 < root.episodes.length)
                        root.switchEpisode(1)
                }
            }
            onPlaybackStateChanged: {
                if (playbackState === MediaPlayer.PlayingState) {
                    hideUITimer.restart()
                    if (playbackRate !== root.playRate)
                        playbackRate = root.playRate
                }
            }
            onErrorChanged: {
                if (error !== MediaPlayer.NoError)
                    root.onVideoError("video", error, errorString)
            }
        }
    }

    // ---- 播放控制层 ----
    Item {
        id: playerOSD
        anchors.fill: stack
        z: 60
        visible: root.playerActive
        MouseArea {
            anchors.fill: parent
            z: 1
            property real pressX: 0
            property real pressY: 0
            property bool isVertical: false
            property bool dragging: false
            onPressed: {
                pressX = mouse.x; pressY = mouse.y
                isVertical = false; dragging = false
            }
            onPositionChanged: {
                if (!pressed || video.duration <= 0)
                    return
                var dx = mouse.x - pressX
                var dy = mouse.y - pressY
                if (!dragging && Math.abs(dy) > 40 && Math.abs(dy) > Math.abs(dx) * 1.4)
                    isVertical = true
                if (isVertical)
                    return
                if (Math.abs(dx) > 14) {
                    dragging = true
                    root.seekDragging = true
                    seekBar.value = Math.max(0, Math.min(video.duration,
                        video.position + dx / width * video.duration))
                }
            }
            onReleased: {
                var dx = mouse.x - pressX
                var dy = mouse.y - pressY
                if (isVertical) {
                    root.seekDragging = false
                    if (Math.abs(dy) > Math.max(70, height * 0.12) && Math.abs(dy) > Math.abs(dx) * 1.4) {
                        root.showControls = true
                        root.switchEpisode(dy < 0 ? 1 : -1)
                    }
                } else if (dragging) {
                    if (video.seekable)
                        video.seek(seekBar.value)
                    else
                        video.position = seekBar.value
                    root.seekDragging = false
                    root.showControls = true
                    hideUITimer.restart()
                } else {
                    root.showControls = !root.showControls
                    root.headerVisible = root.showControls
                    if (root.showControls)
                        hideUITimer.restart()
                }
            }
            onCanceled: root.seekDragging = false
        }
        Text {
            anchors.centerIn: parent
            z: 2
            visible: root.fetching
            text: backend.status
            color: "#cccccc"
            font.pixelSize: 40
        }
        Rectangle {
            z: 3
            visible: root.showControls
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 150
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0.65) }
                GradientStop { position: 1; color: "transparent" }
            }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: root.pageMargin
                anchors.rightMargin: root.pageMargin
                spacing: 8
                Label {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    text: root.dTitle + (root.epText() !== "" ? " · " + root.epText() : "")
                    color: "white"
                    font.pixelSize: 32
                    elide: Text.ElideRight
                }
                Button {
                    text: "小窗"
                    flat: true
                    font.pixelSize: 30
                    onClicked: root.minimizePlayer()
                }
                Button {
                    text: "选集"
                    flat: true
                    font.pixelSize: 30
                    onClicked: {
                        if (stack.currentItem.stopAndSave)
                            stack.currentItem.stopAndSave()
                        stack.pop()
                    }
                }
            }
        }
        Rectangle {
            z: 3
            visible: root.showControls
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 400
            gradient: Gradient {
                GradientStop { position: 0; color: "transparent" }
                GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.8) }
            }
            ColumnLayout {
                anchors.fill: parent
                anchors.leftMargin: root.pageMargin
                anchors.rightMargin: root.pageMargin
                anchors.topMargin: 8
                anchors.bottomMargin: 16
                spacing: 4
                Label {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: "上滑下一集 · 下滑上一集"
                    color: root.cSecondary
                    font.pixelSize: 28
                }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 64
                    spacing: 12
                    Label {
                        text: root.fmt(root.seekDragging ? seekBar.value : video.position)
                        color: "#d8d8d8"
                        font.pixelSize: 30
                        Layout.preferredWidth: 170
                        horizontalAlignment: Text.AlignHCenter
                    }
                    Slider {
                        id: seekBar
                        Layout.fillWidth: true
                        Layout.preferredHeight: 64
                        from: 0
                        to: Math.max(video.duration, 1)
                        enabled: video.duration > 0
                        onPressedChanged: {
                            if (pressed) {
                                root.seekDragging = true
                            } else {
                                root.seekDragging = false
                                root.doSeek(value)
                            }
                        }
                    }
                    Label {
                        text: root.fmt(video.duration)
                        color: "#d8d8d8"
                        font.pixelSize: 30
                        Layout.preferredWidth: 170
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
                Row {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 40
                    Button {
                        text: "快退10秒"
                        flat: true
                        font.pixelSize: 30
                        enabled: root.curFile !== "" && video.duration > 0
                        onClicked: root.jumpBy(-10000)
                    }
                    Button {
                        text: "快进10秒"
                        flat: true
                        font.pixelSize: 30
                        enabled: root.curFile !== "" && video.duration > 0
                        onClicked: root.jumpBy(10000)
                    }
                }
                Row {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 24
                    Button {
                        text: "上集"
                        flat: true
                        font.pixelSize: 32
                        enabled: root.curIdx > 0 && !root.fetching
                        onClicked: {
                            backend.savePos(root.curKey(), video.position)
                            root.switchEpisode(-1)
                        }
                    }
                    Button {
                        text: video.playbackState === MediaPlayer.PlayingState ? "暂停" : "播放"
                        flat: true
                        font.bold: true
                        font.pixelSize: 32
                        enabled: !root.fetching && root.curFile !== ""
                        onClicked: {
                            if (video.playbackState === MediaPlayer.PlayingState) {
                                wantPlay = false
                                video.pause()
                                backend.savePos(root.curKey(), video.position)
                            } else {
                                wantPlay = true
                                video.play()
                            }
                            root.showControls = true
                            hideUITimer.restart()
                        }
                    }
                    Button {
                        text: root.playRate.toFixed(2).replace(/0+$/, "").replace(/\.$/, "") + "×"
                        flat: true
                        font.pixelSize: 32
                        enabled: !root.fetching
                        onClicked: root.cycleSpeed()
                    }
                    Button {
                        text: root.localPlaying ? "本地" : root.dlBtnText(root.dlInfo(root.curVid()))
                        flat: true
                        font.pixelSize: 32
                        enabled: !root.fetching && !root.localPlaying
                        onClicked: root.downloadEpisode(root.curIdx)
                    }
                    Button {
                        text: "下集"
                        flat: true
                        font.pixelSize: 32
                        enabled: root.curIdx + 1 < root.episodes.length && !root.fetching
                        onClicked: {
                            backend.savePos(root.curKey(), video.position)
                            root.switchEpisode(1)
                        }
                    }
                }
                Item { Layout.preferredHeight: 8; Layout.fillWidth: true }
            }
        }
        Column {
            anchors.centerIn: parent
            z: 4
            width: parent.width - 80
            spacing: 16
            visible: root.fetching
                || (!root.isPlaying && (root.isLoading || root.hasLoadError))
                || (root.isPlaying && root.loadStuck)
            BusyIndicator {
                anchors.horizontalCenter: parent.horizontalCenter
                running: root.fetching || root.isLoading
                visible: running
            }
            Label {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: root.fetching ? backend.status
                    : (root.statusMsg !== "" ? root.statusMsg
                       : "正在准备 " + (root.epText() !== "" ? root.epText() : "视频") + "…")
                color: "white"
                font.pixelSize: 34
            }
            Button {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: !root.fetching && (root.hasLoadError || root.loadStuck)
                text: "重试"
                flat: true
                font.pixelSize: 34
                onClicked: root.playAt(root.curIdx)
            }
        }
        Timer {
            interval: 300
            running: true
            repeat: true
            onTriggered: {
                if (!root.seekDragging && video.duration > 0)
                    seekBar.value = video.position
            }
        }
        Timer {
            interval: 10000
            running: video.playbackState === MediaPlayer.PlayingState
            repeat: true
            onTriggered: backend.savePos(root.curKey(), video.position)
        }
    }

    // ============ 目录 ============
    Component {
        id: listPage
        Item {
            ColumnLayout {
                anchors.fill: parent
                spacing: 0
                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: root.pageMargin
                    Layout.rightMargin: root.pageMargin
                    Layout.preferredHeight: 92
                    spacing: 8
                    Label {
                        text: "小宝影院"
                        color: root.cPrimary
                        font.pixelSize: 40
                        font.bold: true
                    }
                    Label {
                        text: "ibaotv.com"
                        color: root.cSecondary
                        font.pixelSize: 26
                        Layout.alignment: Qt.AlignVCenter
                    }
                    Item { Layout.fillWidth: true }
                    Button {
                        text: "刷新"
                        flat: true
                        font.pixelSize: 30
                        onClicked: root.refreshTab()
                    }
                }
                // 分类签
                Item {
                    id: tabs
                    Layout.fillWidth: true
                    Layout.preferredHeight: 110
                    Row {
                        anchors.fill: parent
                        Repeater {
                            model: root.tabDefs
                            Item {
                                width: tabs.width / root.tabDefs.length
                                height: tabs.height
                                Label {
                                    anchors.centerIn: parent
                                    text: modelData.name
                                    font.pixelSize: 36
                                    color: swipeView.currentIndex === index ? root.cHighlight : root.cSecondary
                                }
                                Rectangle {
                                    height: 5
                                    width: 110
                                    anchors.bottom: parent.bottom
                                    anchors.bottomMargin: 8
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    color: root.cHighlight
                                    visible: swipeView.currentIndex === index
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: swipeView.currentIndex = index
                                }
                            }
                        }
                    }
                }
                // 继续上次
                Label {
                    Layout.fillWidth: true
                    Layout.leftMargin: root.pageMargin
                    Layout.rightMargin: root.pageMargin
                    visible: root.lastResumeText !== ""
                    text: root.lastResumeText !== "" ? "发现好剧 · " + root.lastResumeText : ""
                    color: root.cSecondary
                    font.pixelSize: 30
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.resumeLast()
                    }
                }
                Component {
                    id: feedPageComp
                    Item {
                        property int ti: 0
                        ListView {
                            anchors.fill: parent
                            clip: true
                            model: root.tabState[ti].cards
                            delegate: feedDelegate
                            footer: Item {
                                width: ListView.view.width
                                height: root.tabState[ti].loading ? 140
                                    : (root.tabState[ti].done && root.tabState[ti].cards.length > 0 ? 90 : 0)
                                BusyIndicator {
                                    anchors.centerIn: parent
                                    running: root.tabState[ti].loading
                                    visible: running
                                }
                                Label {
                                    anchors.centerIn: parent
                                    visible: root.tabState[ti].done && root.tabState[ti].cards.length > 0
                                    text: "没有更多了"
                                    color: root.cSecondary
                                    font.pixelSize: 28
                                }
                            }
                            onContentYChanged: {
                                if (contentY > 0 && contentY + height > contentHeight - 800)
                                    root.loadMore(ti)
                            }
                            ScrollIndicator.vertical: ScrollIndicator {}
                        }
                        Column {
                            anchors.centerIn: parent
                            spacing: 16
                            visible: root.tabState[ti].cards.length === 0
                                && !root.tabState[ti].loading && root.tabIdx === ti
                            Label {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: root.statusMsg !== "" ? root.statusMsg : "加载中…"
                                color: root.cHighlight
                                font.pixelSize: 30
                            }
                            Button {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "刷新"
                                flat: true
                                font.pixelSize: 32
                                onClicked: root.loadTab(ti, true, root.tabState[ti].kw)
                            }
                        }
                        Component {
                            id: feedDelegate
                            Item {
                                width: ListView.view.width
                                height: 300
                                Rectangle {
                                    x: root.pageMargin
                                    y: 12
                                    width: 208
                                    height: 276
                                    color: "#1e1e1e"
                                    radius: 6
                                }
                                Image {
                                    id: poster
                                    x: root.pageMargin
                                    y: 12
                                    width: 208
                                    height: 276
                                    source: modelData.cover || ""
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    cache: true
                                    sourceSize.width: 320
                                    sourceSize.height: 440
                                }
                                Column {
                                    anchors.left: poster.right
                                    anchors.leftMargin: 28
                                    anchors.right: parent.right
                                    anchors.rightMargin: root.pageMargin
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 10
                                    Label {
                                        width: parent.width
                                        text: modelData.title || ""
                                        color: root.cPrimary
                                        font.pixelSize: 38
                                        wrapMode: Text.Wrap
                                        maximumLineCount: 2
                                        elide: Text.ElideRight
                                    }
                                    Label {
                                        width: parent.width
                                        text: root.metaLine(modelData)
                                        color: root.cSecondary
                                        font.pixelSize: 29
                                        wrapMode: Text.Wrap
                                        maximumLineCount: 2
                                        elide: Text.ElideRight
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: root.openDetail(modelData.sid)
                                }
                            }
                        }
                    }
                }
                SwipeView {
                    id: swipeView
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    Component.onCompleted: currentIndex = root.tabIdx
                    onCurrentIndexChanged: {
                        root.tabIdx = currentIndex
                        var st = root.tabState[currentIndex]
                        if (st && st.cards.length === 0 && !st.loading)
                            root.loadTab(currentIndex, true, st.kw)
                    }
                    Loader { sourceComponent: feedPageComp; onLoaded: item.ti = 0 }
                    Loader { sourceComponent: feedPageComp; onLoaded: item.ti = 1 }
                    Loader { sourceComponent: feedPageComp; onLoaded: item.ti = 2 }
                    Loader { sourceComponent: feedPageComp; onLoaded: item.ti = 3 }
                    Loader { sourceComponent: feedPageComp; onLoaded: item.ti = 4 }
                }
            }
        }
    }

    // ============ 详情 ============
    Component {
        id: detailPage
        Item {
            objectName: "ibdetail"
            ListView {
                id: detailList
                anchors.fill: parent
                clip: true
                model: root.episodes
                header: Column {
                    width: detailList.width
                    spacing: 12
                    Item {
                        width: parent.width
                        height: 420
                        Rectangle {
                            x: root.pageMargin
                            y: 20
                            width: 260
                            height: 364
                            color: "#1e1e1e"
                            radius: 6
                        }
                        Image {
                            x: root.pageMargin
                            y: 20
                            width: 260
                            height: 364
                            source: root.dCover
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                        }
                        Column {
                            x: root.pageMargin + 260 + 28
                            y: 20
                            width: parent.width - x - root.pageMargin
                            spacing: 10
                            Label {
                                width: parent.width
                                text: root.dTitle
                                color: root.cPrimary
                                font.pixelSize: 44
                                font.bold: true
                                wrapMode: Text.Wrap
                            }
                            Label {
                                width: parent.width
                                visible: root.dMeta !== ""
                                text: root.dMeta
                                color: root.cSecondary
                                font.pixelSize: 30
                                wrapMode: Text.Wrap
                            }
                            Label {
                                width: parent.width
                                visible: text !== ""
                                text: (root.dTotal > 1 ? "共 " + root.dTotal + " 集" : "")
                                    + (root.dUpdated !== ""
                                       ? (root.dTotal > 1 ? " · " : "") + root.dUpdated : "")
                                color: root.cSecondary
                                font.pixelSize: 30
                                wrapMode: Text.Wrap
                            }
                            Label {
                                width: parent.width
                                visible: root.episodes.length > 0
                                text: "点选集播放 · 右侧按钮下载"
                                color: root.cSecondary
                                font.pixelSize: 26
                            }
                            Label {
                                width: parent.width
                                text: root.dIntro
                                color: "#c8c8c8"
                                font.pixelSize: 30
                                wrapMode: Text.WordWrap
                                maximumLineCount: 5
                                elide: Text.ElideRight
                            }
                        }
                    }
                    Label {
                        x: root.pageMargin
                        text: "选集"
                        color: root.cSecondary
                        font.pixelSize: 32
                    }
                }
                delegate: ItemDelegate {
                    width: ListView.view.width
                    height: 128
                    highlighted: index === root.curIdx
                    property var dlinfo: root.dlInfo(modelData.nid)
                    background: Rectangle {
                        color: (index === root.curIdx) ? Qt.rgba(0, 0.55, 0.9, 0.22) : "#121212"
                    }
                    Label {
                        x: root.pageMargin
                        width: parent.width - 2 * root.pageMargin - 130
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.epLabel(modelData)
                        color: (index === root.curIdx) ? root.cHighlight : root.cPrimary
                        font.pixelSize: 34
                        elide: Text.ElideRight
                    }
                    Button {
                        anchors.right: parent.right
                        anchors.rightMargin: root.pageMargin
                        anchors.verticalCenter: parent.verticalCenter
                        width: 116
                        height: 84
                        flat: true
                        font.pixelSize: 28
                        text: root.dlBtnText(dlinfo)
                        onClicked: root.downloadEpisode(index)
                    }
                    onClicked: root.playAt(index)
                }
                ScrollIndicator.vertical: ScrollIndicator {}
            }
        }
    }

    // ============ 下载 ============
    Component {
        id: downloadsPage
        Item {
            objectName: "ibdownloads"
            ColumnLayout {
                anchors.fill: parent
                spacing: 0
                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: root.pageMargin
                    Layout.rightMargin: root.pageMargin
                    Layout.topMargin: 12
                    Label {
                        Layout.fillWidth: true
                        text: "下载"
                        color: root.cPrimary
                        font.pixelSize: 44
                    }
                    Button {
                        text: "打开文件夹"
                        flat: true
                        font.pixelSize: 30
                        onClicked: downloader.openFolder()
                    }
                }
                Label {
                    Layout.leftMargin: root.pageMargin
                    Layout.rightMargin: root.pageMargin
                    Layout.fillWidth: true
                    text: "保存在 " + downloader.dir + "（任务里点“导出”可复制到 Videos）"
                    color: root.cSecondary
                    font.pixelSize: 26
                    wrapMode: Text.Wrap
                }
                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: downloader.tasks
                    delegate: ItemDelegate {
                        width: ListView.view.width
                        height: 220
                        background: Rectangle { color: "#121212" }
                        ColumnLayout {
                            x: root.pageMargin
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 2 * x
                            spacing: 4
                            Label {
                                Layout.fillWidth: true
                                text: (modelData.title || modelData.vod) + " · " + (modelData.label || "")
                                color: root.cPrimary
                                font.pixelSize: 34
                                elide: Text.ElideRight
                            }
                            ProgressBar {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 16
                                from: 0
                                to: 100
                                value: modelData.percent
                                visible: modelData.status !== "已完成"
                            }
                            Label {
                                Layout.fillWidth: true
                                text: {
                                    var s = modelData.status
                                    if (modelData.status === "下载中" || modelData.status === "合并中")
                                        s += " " + modelData.percent + "%"
                                    if (modelData.bytes > 0)
                                        s += " · " + (modelData.bytes / 1048576).toFixed(1) + "MB"
                                    if (modelData.speed > 0 && modelData.status === "下载中")
                                        s += " · " + (modelData.speed / 1048576).toFixed(1) + "MB/s"
                                    if (modelData.error)
                                        s += " · " + modelData.error
                                    return s
                                }
                                color: modelData.status === "失败" ? "#ff8080" : root.cSecondary
                                font.pixelSize: 26
                                elide: Text.ElideRight
                            }
                            RowLayout {
                                spacing: 16
                                Button {
                                    text: "播放"
                                    flat: true
                                    font.pixelSize: 28
                                    visible: modelData.status === "已完成"
                                    onClicked: root.playLocal(modelData)
                                }
                                Button {
                                    text: "导出"
                                    flat: true
                                    font.pixelSize: 28
                                    visible: modelData.status === "已完成"
                                    onClicked: downloader.exportTask(modelData.key)
                                }
                                Button {
                                    text: "重试"
                                    flat: true
                                    font.pixelSize: 28
                                    visible: modelData.status === "失败" || modelData.status === "已取消"
                                        || modelData.status === "已中断"
                                    onClicked: downloader.retry(modelData.key)
                                }
                                Button {
                                    text: "取消"
                                    flat: true
                                    font.pixelSize: 28
                                    visible: modelData.status === "排队中" || modelData.status === "获取列表"
                                        || modelData.status === "下载中" || modelData.status === "合并中"
                                        || modelData.status.indexOf("重试中") === 0
                                    onClicked: downloader.cancel(modelData.key)
                                }
                                Button {
                                    text: "删除"
                                    flat: true
                                    font.pixelSize: 28
                                    onClicked: downloader.remove(modelData.key)
                                }
                            }
                        }
                    }
                    Label {
                        anchors.centerIn: parent
                        visible: downloader.tasks.length === 0
                        text: "还没有下载任务\n详情页选集右侧点“下载”即可"
                        color: root.cSecondary
                        font.pixelSize: 32
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }
        }
    }

    // ============ 观看记录 ============
    Component {
        id: historyPage
        Item {
            objectName: "ibhistory"
            ColumnLayout {
                anchors.fill: parent
                spacing: 0
                Label {
                    Layout.fillWidth: true
                    Layout.leftMargin: root.pageMargin
                    Layout.topMargin: 20
                    text: "观看记录"
                    color: root.cPrimary
                    font.pixelSize: 44
                }
                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: root.historyList
                    delegate: ItemDelegate {
                        width: ListView.view.width
                        height: 150
                        background: Rectangle { color: "#121212" }
                        Column {
                            x: root.pageMargin
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 2 * x
                            spacing: 6
                            Label {
                                width: parent.width
                                text: modelData.title || modelData.id
                                color: root.cPrimary
                                font.pixelSize: 36
                                elide: Text.ElideRight
                            }
                            Label {
                                text: "第 " + (modelData.episode || 1) + " 集"
                                    + (modelData.position > 0
                                       ? " · " + root.fmt(modelData.position) : "")
                                color: root.cSecondary
                                font.pixelSize: 30
                            }
                        }
                        onClicked: root.openDetail(modelData.id)
                    }
                    Label {
                        anchors.centerIn: parent
                        visible: root.historyList.length === 0
                        text: "还没有观看记录"
                        color: root.cSecondary
                        font.pixelSize: 34
                    }
                }
                Button {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.bottomMargin: 24
                    Layout.preferredHeight: 104
                    Layout.preferredWidth: 380
                    text: "清空记录"
                    flat: true
                    font.pixelSize: 34
                    enabled: root.historyList.length > 0
                    onClicked: {
                        backend.clearHistory()
                        root.refreshHistory()
                    }
                }
            }
        }
    }

    // ============ 设置 ============
    Component {
        id: settingsPage
        Item {
            objectName: "ibsettings"
            Flickable {
                anchors.fill: parent
                contentHeight: col.height + 48
                clip: true
                ColumnLayout {
                    id: col
                    width: parent.width
                    spacing: 6
                    Label {
                        Layout.leftMargin: root.pageMargin
                        Layout.topMargin: 20
                        text: "设置"
                        color: root.cPrimary
                        font.pixelSize: 44
                    }
                    Button {
                        Layout.leftMargin: root.pageMargin
                        Layout.topMargin: 12
                        flat: true
                        font.pixelSize: 34
                        text: "下载管理"
                        onClicked: {
                            if (!stack.currentItem || stack.currentItem.objectName !== "ibdownloads")
                                stack.push(downloadsPage)
                        }
                    }
                    Switch {
                        Layout.leftMargin: root.pageMargin
                        text: "后台继续播放"
                        checked: backend.backgroundPlayback()
                        onClicked: backend.setBackgroundPlayback(checked)
                    }
                    Label {
                        Layout.leftMargin: root.pageMargin
                        text: "离开应用后继续播声音（UT 无悬浮窗，画面只在应用内）"
                        color: root.cSecondary
                        font.pixelSize: 30
                    }
                    Switch {
                        Layout.leftMargin: root.pageMargin
                        text: "启动后自动续看"
                        checked: backend.resumeOnLaunch()
                        onClicked: backend.setResumeOnLaunch(checked)
                    }
                    Label {
                        Layout.leftMargin: root.pageMargin
                        text: "从上次的剧集和进度接着播放"
                        color: root.cSecondary
                        font.pixelSize: 30
                    }
                    Switch {
                        Layout.leftMargin: root.pageMargin
                        text: "自动连播"
                        checked: backend.autoNext()
                        onClicked: backend.setAutoNext(checked)
                    }
                    Label {
                        Layout.leftMargin: root.pageMargin
                        text: "播完后自动切换下一集"
                        color: root.cSecondary
                        font.pixelSize: 30
                    }
                    Label {
                        Layout.leftMargin: root.pageMargin
                        Layout.topMargin: 20
                        Layout.rightMargin: root.pageMargin
                        Layout.fillWidth: true
                        text: "说明"
                        color: root.cSecondary
                        font.pixelSize: 32
                    }
                    Label {
                        Layout.leftMargin: root.pageMargin
                        Layout.rightMargin: root.pageMargin
                        Layout.fillWidth: true
                        text: "片源来自 ibaotv.com 的公开页面，播放地址为站点提供的 m3u8；"
                            + "本应用只做聚合与播放，版权归原权利人所有，仅供个人学习研究。"
                        color: root.cSecondary
                        font.pixelSize: 30
                        wrapMode: Text.Wrap
                    }
                    Label {
                        Layout.leftMargin: root.pageMargin
                        Layout.rightMargin: root.pageMargin
                        Layout.fillWidth: true
                        Layout.topMargin: 16
                        text: "小宝影院 · 本机原生版 v" + Qt.application.version
                        color: root.cSecondary
                        font.pixelSize: 30
                        wrapMode: Text.Wrap
                    }
                }
            }
        }
    }

    // ============ 小窗 ============
    Rectangle {
        id: miniBox
        visible: root.miniVisible
        color: "transparent"
        border.color: "#2a2a2a"
        border.width: 2
        radius: 12
        clip: true
        width: Math.min(parent.width, parent.height) * 0.38
        height: width * 16 / 9
        x: parent.width - width - 24
        y: parent.height - height - 160
        z: 90
        onXChanged: { root.syncVideoGeom(); geomTimer.restart() }
        onYChanged: { root.syncVideoGeom(); geomTimer.restart() }
        onVisibleChanged: { root.syncVideoGeom(); geomTimer.restart() }
        MouseArea {
            anchors.fill: parent
            z: 0
            drag.target: miniBox
            drag.minimumX: 0
            drag.maximumX: root.width - miniBox.width
            drag.minimumY: 0
            drag.maximumY: root.height - miniBox.height
            onClicked: root.restorePlayer()
        }
        Rectangle {
            anchors.top: parent.top
            width: parent.width
            height: 72
            z: 2
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0.7) }
                GradientStop { position: 1; color: "transparent" }
            }
            Label {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                verticalAlignment: Text.AlignVCenter
                text: root.dTitle + (root.epText() !== "" ? " · " + root.epText() : "")
                color: "white"
                font.pixelSize: 28
                elide: Text.ElideRight
            }
        }
        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 88
            z: 2
            color: Qt.rgba(0, 0, 0, 0.55)
            Row {
                anchors.centerIn: parent
                spacing: 8
                Button {
                    text: "回放"
                    flat: true
                    font.pixelSize: 28
                    onClicked: root.restorePlayer()
                }
                Button {
                    text: video.playbackState === MediaPlayer.PlayingState ? "暂停" : "播放"
                    flat: true
                    font.bold: true
                    font.pixelSize: 28
                    onClicked: {
                        if (video.playbackState === MediaPlayer.PlayingState) {
                            wantPlay = false
                            video.pause()
                        } else {
                            wantPlay = true
                            video.play()
                        }
                    }
                }
                Button {
                    text: "关"
                    flat: true
                    font.pixelSize: 28
                    onClicked: root.stopAndCloseMini()
                }
            }
        }
    }

    Connections {
        target: Qt.application
        onActiveChanged: {
            if (!Qt.application.active && !backend.backgroundPlayback()) {
                try {
                    if (video.playbackState === MediaPlayer.PlayingState) {
                        var v = root.curKey()
                        if (v !== "")
                            backend.savePos(v, video.position)
                        wantPlay = false
                        video.pause()
                    }
                } catch (e) {}
            } else if (Qt.application.active) {
                syncVideoGeom()
                geomTimer.restart()
                kickTimer.restart()
            }
        }
    }

    // ============ 播放页空壳 ============
    Component {
        id: playerPage
        Item {
            objectName: "ibplayer"
            function stopAndSave() {
                if (root.curIdx >= 0 && root.curIdx < root.episodes.length) {
                    try { backend.savePos(root.curKey(), video.position) } catch (e) {}
                    try { backend.saveHistory(root.dSid, root.dTitle, root.curIdx + 1, video.position, root.dCover) } catch (e) {}
                }
            }
            Component.onCompleted: {
                root.headerVisible = false
                root.showControls = true
            }
            Component.onDestruction: {
                root.headerVisible = true
            }
        }
    }

    Component.onCompleted: {
        playRate = backend.playbackRate()
        if (playRate < 0.5 || playRate > 3.0)
            playRate = 1.0
        refreshHistory()
        refreshResume()
        loadTab(0, true, "")
    }
}
