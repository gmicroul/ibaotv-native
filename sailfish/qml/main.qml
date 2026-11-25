import QtQuick 2.6
import Sailfish.Silica 1.0
import QtMultimedia 5.6
import Nemo.KeepAlive 1.2

// ibaotv-native（Sailfish OS 原生版）
// 数据链：C++ Backend 直接解析 ibaotv.com（等价 node xbweb.js）
// 播放：QtMultimedia + GStreamer 直接喂 m3u8
// 交互：目录 / 搜索 / 详情选集 / 播放（上下滑切集、横拖快进、倍速、
//       自动隐、小窗、断点续播、记录、下载、设置）
ApplicationWindow {
    id: root
    initialPage: catalogPage
    cover: coverComponent

    property string appVersion: "0.2.2"

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
    property bool reloadBusy: false
    property int playerOrient: 0

    function cyclePlayerOrient() {
        playerOrient = (playerOrient + 1) % 3
        backend.setPlayerOrient(playerOrient)
    }
    function orientLabel() {
        if (playerOrient === 1)
            return "横屏"
        if (playerOrient === 2)
            return "竖屏"
        return "自动"
    }
    function setPlayerOrientTest(v) {
        playerOrient = parseInt(v)
        if (playerOrient !== 0 && playerOrient !== 1 && playerOrient !== 2)
            playerOrient = 0
        backend.setPlayerOrient(playerOrient)
    }
    function testOrientLog() {
        return "" + root.orientation + "/" + root.deviceOrientation
    }

    Connections {
        target: root
        onOrientationChanged: backend.logLine("WINDOW-ORIENT=" + root.orientation
                                              + " device=" + root.deviceOrientation)
    }

    property bool playerActive: pageStack.currentPage !== null
        && pageStack.currentPage.objectName === "ibplayer"
    property bool miniVisible: curFile !== "" && !fetching && !playerActive
        && pageStack.currentPage !== null && pageStack.busy === false
    property bool localPlaying: curFile !== "" && curFile.indexOf("http") !== 0
    property bool isPlaying: video.playbackState === MediaPlayer.PlayingState
    property bool isLoading: video.status === MediaPlayer.Loading
        || video.status === MediaPlayer.Buffering
        || video.status === MediaPlayer.Stalled
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

    Timer {
        id: pushTimer
        interval: 150
        repeat: true
        running: pendingPush !== null
        onTriggered: {
            if (pendingPush && !pageStack.busy) {
                var comp = pendingPush
                pendingPush = null
                pageStack.push(comp)
            }
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
    function testDetail(sid) {
        if (openDetail(sid))
            playAt(0)
    }
    function testSearch(kw) {
        doSearch(kw)
    }
    function playDirect(url, title) {
        if (!url)
            return
        dSid = "test"
        dTitle = title || "测试"
        dCover = ""
        dIntro = ""
        dMeta = "测试播放"
        dUpdated = ""
        dTotal = "1"
        episodes = [{ sid: "1", nid: "1", label: "测试" }]
        curIdx = 0
        wantPlay = true
        errRetry = 0
        autoRetried = false
        fromAuto = false
        showControls = true
        curFile = url
        if (!playerActive)
            pageStack.push(playerPage)
        kickTimer.restart()
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
        reloadBusy = false
        pendingSeek = -1
        lastSeekTarget = -1
        curFile = t.file
        if (!playerActive)
            pushPage(playerPage)
        kickTimer.restart()
    }
    function reloadAt(ms) {
        if (root.curFile === "")
            return
        root.pendingSeek = Math.max(0, ms)
        if (root.reloadBusy)
            return
        root.reloadBusy = true
        try { video.seekDone = true } catch (e) {}
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
        if (root.curFile === "" || root.seekDragging)
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

    property var pendingPush: null

    function pushPage(comp) {
        if (!comp)
            return
        pendingPush = comp
        if (!pageStack.busy) {
            var c = pendingPush
            pendingPush = null
            pageStack.push(c)
        }
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
                statusMsg = keyword !== "" ? "没搜到，换个词试试" : "加载失败，下拉刷新重试"
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

    function doSearch(text) {
        var kw = (text === undefined ? "" : String(text)).trim()
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
        if (pageStack.currentPage && pageStack.currentPage.objectName === "ibdetail")
            return true
        pushPage(detailPage)
        return true
    }

    function playAt(i) {
        if (i < 0 || i >= episodes.length)
            return
        var reuse = pageStack.currentPage && pageStack.currentPage.objectName === "ibplayer"
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
            pushPage(playerPage)
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
                pageStack.pop()
            return
        }
        statusMsg = ""
        backend.saveLast(dSid, ep.nid)
        backend.saveHistory(dSid, dTitle, i + 1, 0, dCover)
        refreshHistory()
        errRetry = 0
        reloadBusy = false
        pendingSeek = -1
        lastSeekTarget = -1
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
        if (!playerActive)
            return
        try {
            if (video.duration > 0)
                backend.savePos(root.curKey(), video.position)
        } catch (e) {}
        pageStack.pop()
    }

    function restorePlayer() {
        if (!playerActive) {
            wantPlay = true
            pushPage(playerPage)
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
        var h = backend.history()
        historyList = h && h.length ? h : []
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
            var v = root.activeVideo()
            if (v && v.playbackState === MediaPlayer.PlayingState)
                root.showControls = false
        }
    }

    // ---- 全局状态条 ----
    Label {
        id: globalStatus
        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
            margins: Theme.paddingMedium
        }
        z: 95
        visible: text !== "" && !root.playerActive
        text: root.fetching ? backend.status : root.statusMsg
        color: Theme.highlightColor
        font.pixelSize: Theme.fontSizeSmall
        wrapMode: Text.Wrap
        horizontalAlignment: Text.AlignHCenter
    }

    // ---- 全局唯一解码器 ----
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
        } else if (miniBox) {
            var p = miniBox.mapToItem(videoLayer, 0, 0)
            video.x = p.x
            video.y = p.y
            video.width = miniBox.width
            video.height = miniBox.height
        }
    }
    onCurFileChanged: {
        syncVideoGeom()
        geomTimer.restart()
        if (root.curFile !== "")
            loadStartMs = Date.now()
    }
    onPlayerActiveChanged: { syncVideoGeom(); geomTimer.restart() }

    // ---- 跟随当前页旋转的层（全屏视频与播放控件） ----
    Item {
        id: pageAligned
        anchors.centerIn: parent
        width: pageStack.currentPage ? pageStack.currentPage.width : parent.width
        height: pageStack.currentPage ? pageStack.currentPage.height : parent.height
        rotation: pageStack.currentPage ? pageStack.currentPage.rotation : 0
        anchors.verticalCenterOffset: (pageStack.currentPage && pageStack.currentPage.width > pageStack.currentPage.height)
            ? (parent.height - pageStack.currentPage.width) / 2 : 0
        z: 50
        Behavior on rotation { NumberAnimation { duration: 200; easing.type: Easing.InOutQuad } }

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
                backend.logLine("STATUS=" + status + " state=" + playbackState
                                + " dur=" + Math.round(duration) + " err=" + error)
                if ((status === MediaPlayer.Loaded || status === MediaPlayer.Buffered)
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
                backend.logLine("STATE=" + playbackState + " pos=" + Math.round(position)
                                + " dur=" + Math.round(duration))
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
                if (!root.seekDragging && !root.reloadBusy
                        && video.duration > 0 && video.position === lastPos && wantPlay
                        && video.status !== MediaPlayer.Buffering
                        && video.status !== MediaPlayer.Stalled
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
            if ((video.status === MediaPlayer.Loaded || video.status === MediaPlayer.Buffered)
                    && video.playbackState === MediaPlayer.StoppedState) {
                video.play()
                return
            }
            if (Date.now() - loadStartMs > 25000
                    && video.playbackState === MediaPlayer.StoppedState
                    && video.status !== MediaPlayer.Loading
                    && video.status !== MediaPlayer.Buffering
                    && video.status !== MediaPlayer.Stalled) {
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
                root.reloadBusy = false
                stop()
                return
            }
            var st = video.status
            if (st === MediaPlayer.Loaded || st === MediaPlayer.Buffered
                    || st === MediaPlayer.EndOfMedia
                    || (video.duration > 0 && Date.now() - root.loadStartMs > 1500)) {
                var ps = root.pendingSeek
                root.pendingSeek = -1
                root.reloadBusy = false
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
                root.reloadBusy = false
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

    // ---- 播放控制层 ----
    Item {
        id: playerOSD
        anchors.fill: parent
        z: 60
        visible: root.playerActive
        DisplayBlanking {
            preventBlanking: Qt.application.active && root.playerActive
                && video.playbackState === MediaPlayer.PlayingState
        }
        MouseArea {
            anchors.fill: parent
            z: 1
            property real pressX: 0
            property real pressY: 0
            property bool isVertical: false
            property bool dragging: false
            function screenX(dx, dy) {
                if (pageAligned.rotation === 90)
                    return -dy
                if (pageAligned.rotation === 270)
                    return dy
                if (pageAligned.rotation === 180)
                    return -dx
                return dx
            }
            function screenY(dx, dy) {
                if (pageAligned.rotation === 90)
                    return dx
                if (pageAligned.rotation === 270)
                    return -dx
                if (pageAligned.rotation === 180)
                    return -dy
                return dy
            }
            onPressed: {
                pressX = mouse.x; pressY = mouse.y
                isVertical = false; dragging = false
            }
            onPositionChanged: {
                if (!pressed || video.duration <= 0)
                    return
                var dx = screenX(mouse.x - pressX, mouse.y - pressY)
                var dy = screenY(mouse.x - pressX, mouse.y - pressY)
                if (!dragging && Math.abs(dy) > Theme.paddingLarge * 2
                        && Math.abs(dy) > Math.abs(dx) * 1.4)
                    isVertical = true
                if (isVertical)
                    return
                if (Math.abs(dx) > Theme.paddingLarge) {
                    dragging = true
                    root.seekDragging = true
                    seekBar.value = Math.max(0, Math.min(video.duration,
                        video.position + dx / width * video.duration))
                }
            }
            onReleased: {
                var dx = screenX(mouse.x - pressX, mouse.y - pressY)
                var dy = screenY(mouse.x - pressX, mouse.y - pressY)
                if (isVertical) {
                    root.seekDragging = false
                    if (Math.abs(dy) > Math.max(Theme.itemSizeSmall,
                            height * 0.12) && Math.abs(dy) > Math.abs(dx) * 1.4) {
                        root.showControls = true
                        root.switchEpisode(dy < 0 ? 1 : -1)
                    }
                } else if (dragging) {
                    root.doSeek(seekBar.value)
                    root.seekDragging = false
                    root.showControls = true
                    hideUITimer.restart()
                } else {
                    root.showControls = !root.showControls
                    if (root.showControls)
                        hideUITimer.restart()
                }
            }
            onCanceled: root.seekDragging = false
        }
        Column {
            anchors.centerIn: parent
            z: 4
            width: parent.width - Theme.paddingLarge * 4
            spacing: Theme.paddingLarge
            visible: root.fetching
                || (!root.isPlaying && (root.isLoading || root.hasLoadError))
                || (root.isPlaying && root.loadStuck)
            BusyIndicator {
                anchors.horizontalCenter: parent.horizontalCenter
                running: root.fetching || root.isLoading
                visible: running
                size: BusyIndicatorSize.Large
            }
            Label {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: root.fetching ? backend.status
                    : (root.statusMsg !== "" ? root.statusMsg
                       : "正在准备 " + (root.epText() !== "" ? root.epText() : "视频") + "…")
                color: "white"
                font.pixelSize: Theme.fontSizeMedium
            }
            Button {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: !root.fetching && (root.hasLoadError || root.loadStuck)
                text: "重试"
                onClicked: root.playAt(root.curIdx)
            }
        }
        Rectangle {
            z: 3
            visible: root.showControls
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: headerRow.height + Theme.paddingLarge * 2
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0.65) }
                GradientStop { position: 1; color: "transparent" }
            }
            Row {
                id: headerRow
                anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    leftMargin: Theme.horizontalPageMargin
                    rightMargin: Theme.horizontalPageMargin
                }
                spacing: Theme.paddingSmall
                Label {
                    width: parent.width - 2 * Theme.itemSizeMedium - Theme.buttonWidthSmall
                        - parent.spacing * 3
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.dTitle + (root.epText() !== "" ? " · " + root.epText() : "")
                    color: "white"
                    font.pixelSize: Theme.fontSizeSmall
                    truncationMode: TruncationMode.Fade
                }
                Button {
                    id: orientBtn
                    anchors.verticalCenter: parent.verticalCenter
                    preferredWidth: Theme.buttonWidthSmall
                    text: root.orientLabel()
                    onClicked: root.cyclePlayerOrient()
                }
                IconButton {
                    width: Theme.itemSizeMedium
                    icon.source: "image://theme/icon-m-media"
                    onClicked: root.minimizePlayer()
                }
                IconButton {
                    width: Theme.itemSizeMedium
                    icon.source: "image://theme/icon-m-menu"
                    onClicked: {
                        try {
                            if (video.duration > 0)
                                backend.savePos(root.curKey(), video.position)
                        } catch (e) {}
                        pageStack.pop()
                    }
                }
            }
        }
        Rectangle {
            z: 3
            visible: root.showControls
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: controlsColumn.height + Theme.paddingLarge * 2
            gradient: Gradient {
                GradientStop { position: 0; color: "transparent" }
                GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.8) }
            }
            Column {
                id: controlsColumn
                anchors {
                    left: parent.left
                    right: parent.right
                    bottom: parent.bottom
                    leftMargin: Theme.horizontalPageMargin
                    rightMargin: Theme.horizontalPageMargin
                    bottomMargin: Theme.paddingMedium
                }
                spacing: Theme.paddingSmall
                Label {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: "上滑下一集 · 下滑上一集"
                    color: Theme.secondaryColor
                    font.pixelSize: Theme.fontSizeExtraSmall
                }
                Slider {
                    id: seekBar
                    width: parent.width
                    minimumValue: 0
                    maximumValue: Math.max(video.duration, 1)
                    value: 0
                    enabled: video.duration > 0
                    label: root.fmt(value) + " / " + root.fmt(video.duration)
                    onPressedChanged: {
                        if (pressed) {
                            root.seekDragging = true
                        } else {
                            root.seekDragging = false
                            root.doSeek(value)
                        }
                    }
                }
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Theme.paddingMedium
                    IconButton {
                        icon.source: "image://theme/icon-m-media-rewind"
                        enabled: root.curFile !== "" && video.duration > 0
                        onClicked: root.jumpBy(-10000)
                    }
                    IconButton {
                        icon.source: "image://theme/icon-m-previous"
                        enabled: root.curIdx > 0 && !root.fetching
                        onClicked: {
                            backend.savePos(root.curKey(), video.position)
                            root.switchEpisode(-1)
                        }
                    }
                    IconButton {
                        icon.source: video.playbackState === MediaPlayer.PlayingState
                            ? "image://theme/icon-m-pause" : "image://theme/icon-m-play"
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
                    IconButton {
                        icon.source: "image://theme/icon-m-next"
                        enabled: root.curIdx + 1 < root.episodes.length && !root.fetching
                        onClicked: {
                            backend.savePos(root.curKey(), video.position)
                            root.switchEpisode(1)
                        }
                    }
                    IconButton {
                        icon.source: "image://theme/icon-m-media-forward"
                        enabled: root.curFile !== "" && video.duration > 0
                        onClicked: root.jumpBy(10000)
                    }
                }
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Theme.paddingMedium
                    Button {
                        text: root.playRate.toFixed(2).replace(/0+$/, "").replace(/\.$/, "") + "×"
                        preferredWidth: Theme.buttonWidthExtraSmall
                        enabled: !root.fetching
                        onClicked: root.cycleSpeed()
                    }
                    Button {
                        text: root.localPlaying ? "本地" : root.dlBtnText(root.dlInfo(root.curVid()))
                        preferredWidth: Theme.buttonWidthSmall
                        enabled: !root.fetching && !root.localPlaying
                        onClicked: root.downloadEpisode(root.curIdx)
                    }
                }
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

    }

    // ---- 小窗 ----
    Rectangle {
        id: miniBox
        visible: root.miniVisible
        color: "transparent"
        border.color: Theme.rgba("white", 0.25)
        border.width: 2
        radius: 8
        clip: true
        width: Math.min(parent.width, parent.height) * 0.45
        height: width * 9 / 16
        x: parent.width - width - Theme.paddingLarge
        y: parent.height - height - Theme.itemSizeLarge
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
            height: miniTitle.height + Theme.paddingSmall * 2
            z: 2
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0.7) }
                GradientStop { position: 1; color: "transparent" }
            }
            Label {
                id: miniTitle
                anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    leftMargin: Theme.paddingSmall
                    rightMargin: Theme.paddingSmall
                }
                text: root.dTitle + (root.epText() !== "" ? " · " + root.epText() : "")
                color: "white"
                font.pixelSize: Theme.fontSizeTiny
                truncationMode: TruncationMode.Fade
            }
        }
        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: miniControls.height + Theme.paddingSmall
            z: 2
            color: Qt.rgba(0, 0, 0, 0.55)
            Row {
                id: miniControls
                anchors.centerIn: parent
                spacing: Theme.paddingSmall
                IconButton {
                    icon.source: "image://theme/icon-m-media"
                    onClicked: root.restorePlayer()
                }
                IconButton {
                    icon.source: video.playbackState === MediaPlayer.PlayingState
                        ? "image://theme/icon-m-pause" : "image://theme/icon-m-play"
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
                IconButton {
                    icon.source: "image://theme/icon-m-close"
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

    // ============ 播放页空壳（视频由全局层绘制） ============
    Component {
        id: playerPage
        Page {
            objectName: "ibplayer"
            allowedOrientations: root.playerOrient === 1 ? Orientation.Landscape
                : root.playerOrient === 2 ? Orientation.Portrait : Orientation.All
            cutoutMode: CutoutMode.FullScreen
            backNavigation: true
            onAllowedOrientationsChanged: backend.logLine("PLAYER allowed=" + allowedOrientations
                                                          + " win=" + root.orientation
                                                          + " device=" + root.deviceOrientation)
            onStatusChanged: {
                backend.logLine("PLAYER status=" + status + " allowed=" + allowedOrientations
                                + " win=" + root.orientation
                                + " device=" + root.deviceOrientation)
                if (status === PageStatus.Inactive) {
                    if (root.curIdx >= 0 && root.curIdx < root.episodes.length) {
                        try {
                            backend.savePos(root.curKey(), video.position)
                            backend.saveHistory(root.dSid, root.dTitle,
                                                root.curIdx + 1, video.position, root.dCover)
                        } catch (e) {}
                    }
                }
            }
            Component.onCompleted: root.showControls = true
        }
    }

    // ============ 目录 ============
    Component {
        id: catalogPage
        Page {
            id: catalogPageItem
            SilicaListView {
                id: catalogList
                anchors.fill: parent
                clip: true
                model: root.tabState[root.tabIdx].cards
                header: Column {
                    width: catalogList.width
                    PageHeader {
                        title: "小宝影院"
                        description: "ibaotv.com"
                    }
                    Row {
                        x: Theme.horizontalPageMargin
                        width: parent.width - Theme.horizontalPageMargin * 2
                        spacing: Theme.paddingSmall
                        SearchField {
                            id: searchField
                            width: parent.width - searchBtn.width - menuBtn.width
                                - parent.spacing * 2
                            placeholderText: "剧名或剧集 ID…"
                            EnterKey.enabled: text.trim().length > 0
                            EnterKey.onClicked: root.doSearch(searchField.text)
                        }
                        IconButton {
                            id: searchBtn
                            icon.source: "image://theme/icon-m-search"
                            onClicked: root.doSearch(searchField.text)
                        }
                        IconButton {
                            id: menuBtn
                            icon.source: "image://theme/icon-m-menu"
                            onClicked: moreMenu.open(menuBtn)
                        }
                    }
                    Item {
                        id: tabs
                        width: parent.width
                        height: Theme.itemSizeSmall
                        Row {
                            anchors.fill: parent
                            Repeater {
                                model: root.tabDefs
                                BackgroundItem {
                                    width: tabs.width / root.tabDefs.length
                                    height: tabs.height
                                    Label {
                                        anchors.centerIn: parent
                                        text: modelData.name
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: root.tabIdx === index
                                            ? Theme.highlightColor : Theme.secondaryColor
                                    }
                                    Rectangle {
                                        height: 3
                                        width: parent.width * 0.6
                                        anchors.bottom: parent.bottom
                                        anchors.bottomMargin: Theme.paddingSmall
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        color: Theme.highlightColor
                                        visible: root.tabIdx === index
                                    }
                                    onClicked: {
                                        root.tabIdx = index
                                        var st = root.tabState[index]
                                        if (st && st.cards.length === 0 && !st.loading)
                                            root.loadTab(index, true, st.kw)
                                        catalogList.positionViewAtBeginning()
                                    }
                                }
                            }
                        }
                    }
                    BackgroundItem {
                        width: parent.width
                        height: root.lastResumeText !== "" ? Theme.itemSizeSmall : 0
                        visible: root.lastResumeText !== ""
                        Label {
                            anchors {
                                left: parent.left
                                leftMargin: Theme.horizontalPageMargin
                                verticalCenter: parent.verticalCenter
                            }
                            text: "发现好剧 · " + root.lastResumeText
                            color: Theme.highlightColor
                            font.pixelSize: Theme.fontSizeSmall
                        }
                        onClicked: root.resumeLast()
                    }
                }
                delegate: BackgroundItem {
                    id: feedRow
                    width: catalogList.width
                    height: Theme.itemSizeLarge * 1.45
                    Image {
                        id: poster
                        anchors {
                            left: parent.left
                            leftMargin: Theme.horizontalPageMargin
                            verticalCenter: parent.verticalCenter
                        }
                        width: Theme.itemSizeLarge
                        height: Theme.itemSizeLarge * 1.4
                        source: modelData.cover || ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: true
                        sourceSize.width: Math.round(width * 1.6)
                        sourceSize.height: Math.round(height * 1.6)
                    }
                    Column {
                        anchors {
                            left: poster.right
                            leftMargin: Theme.paddingLarge
                            right: parent.right
                            rightMargin: Theme.horizontalPageMargin
                            verticalCenter: parent.verticalCenter
                        }
                        spacing: Theme.paddingSmall
                        Label {
                            width: parent.width
                            text: modelData.title || ""
                            color: Theme.primaryColor
                            font.pixelSize: Theme.fontSizeMedium
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                        }
                        Label {
                            width: parent.width
                            text: root.metaLine(modelData)
                            color: Theme.secondaryColor
                            font.pixelSize: Theme.fontSizeExtraSmall
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                        }
                    }
                    onClicked: root.openDetail(modelData.sid)
                }
                footer: Item {
                    width: catalogList.width
                    height: root.tabState[root.tabIdx].loading ? Theme.itemSizeLarge
                        : (root.tabState[root.tabIdx].done
                           && root.tabState[root.tabIdx].cards.length > 0 ? Theme.itemSizeSmall : 0)
                    BusyIndicator {
                        anchors.centerIn: parent
                        running: root.tabState[root.tabIdx].loading
                        visible: running
                    }
                    Label {
                        anchors.centerIn: parent
                        visible: root.tabState[root.tabIdx].done
                            && root.tabState[root.tabIdx].cards.length > 0
                        text: "没有更多了"
                        color: Theme.secondaryColor
                        font.pixelSize: Theme.fontSizeExtraSmall
                    }
                }
                ViewPlaceholder {
                    enabled: root.tabState[root.tabIdx].cards.length === 0
                        && !root.tabState[root.tabIdx].loading
                    text: root.statusMsg !== "" ? root.statusMsg : "下拉刷新"
                    hintText: "下拉可刷新 · 顶部可搜索"
                }
                onContentYChanged: {
                    if (contentY > 0 && contentY + height > contentHeight - Theme.itemSizeLarge * 6)
                        root.loadMore(root.tabIdx)
                }
                ContextMenu {
                    id: moreMenu
                    MenuItem {
                        text: "刷新当前分类"
                        onClicked: root.refreshTab()
                    }
                    MenuItem {
                        text: "观看记录"
                        onClicked: pushPage(historyPage)
                    }
                    MenuItem {
                        text: "下载管理"
                        onClicked: pushPage(downloadsPage)
                    }
                    MenuItem {
                        text: "设置"
                        onClicked: pushPage(settingsPage)
                    }
                }
                PullDownMenu {
                    MenuItem {
                        text: "刷新当前分类"
                        onClicked: root.refreshTab()
                    }
                    MenuItem {
                        text: "观看记录"
                        onClicked: pushPage(historyPage)
                    }
                    MenuItem {
                        text: "下载管理"
                        onClicked: pushPage(downloadsPage)
                    }
                    MenuItem {
                        text: "设置"
                        onClicked: pushPage(settingsPage)
                    }
                }
            }
        }
    }

    // ============ 详情 ============
    Component {
        id: detailPage
        Page {
            id: detailPageItem
            objectName: "ibdetail"
            SilicaListView {
                id: detailList
                anchors.fill: parent
                clip: true
                model: root.episodes
                header: Column {
                    width: detailList.width
                    PageHeader {
                        title: root.dTitle
                        description: root.dMeta
                    }
                    Row {
                        x: Theme.horizontalPageMargin
                        width: parent.width - Theme.horizontalPageMargin * 2
                        spacing: Theme.paddingLarge
                        Rectangle {
                            width: Theme.itemSizeLarge * 1.4
                            height: Theme.itemSizeLarge * 2
                            color: Theme.rgba("white", 0.05)
                            Image {
                                anchors.fill: parent
                                source: root.dCover
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: true
                            }
                        }
                        Column {
                            width: parent.width - Theme.itemSizeLarge * 1.4 - Theme.paddingLarge
                            spacing: Theme.paddingSmall
                            Label {
                                width: parent.width
                                visible: text !== ""
                                text: (root.dTotal > 1 ? "共 " + root.dTotal + " 集" : "")
                                    + (root.dUpdated !== ""
                                       ? (root.dTotal > 1 ? " · " : "") + root.dUpdated : "")
                                color: Theme.secondaryColor
                                font.pixelSize: Theme.fontSizeExtraSmall
                                wrapMode: Text.Wrap
                            }
                            Label {
                                width: parent.width
                                visible: root.episodes.length > 0
                                text: "点选集播放 · 右侧按钮下载"
                                color: Theme.secondaryColor
                                font.pixelSize: Theme.fontSizeExtraSmall
                            }
                            Label {
                                width: parent.width
                                text: root.dIntro
                                color: Theme.primaryColor
                                font.pixelSize: Theme.fontSizeExtraSmall
                                wrapMode: Text.WordWrap
                                maximumLineCount: 6
                                elide: Text.ElideRight
                            }
                        }
                    }
                    SectionHeader { text: "选集" }
                }
                delegate: BackgroundItem {
                    id: epRow
                    width: detailList.width
                    height: Theme.itemSizeMedium
                    highlighted: index === root.curIdx
                    Label {
                        x: Theme.horizontalPageMargin
                        width: parent.width - Theme.horizontalPageMargin * 2
                            - dlBtn.width - Theme.paddingMedium
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.epLabel(modelData)
                        color: index === root.curIdx ? Theme.highlightColor : Theme.primaryColor
                        font.pixelSize: Theme.fontSizeSmall
                        elide: Text.ElideRight
                    }
                    Button {
                        id: dlBtn
                        anchors {
                            right: parent.right
                            rightMargin: Theme.horizontalPageMargin
                            verticalCenter: parent.verticalCenter
                        }
                        preferredWidth: Theme.buttonWidthSmall
                        text: root.dlBtnText(root.dlInfo(modelData.nid))
                        onClicked: root.downloadEpisode(index)
                    }
                    onClicked: root.playAt(index)
                }
                PullDownMenu {
                    MenuItem {
                        text: "下载本集"
                        enabled: root.curIdx >= 0
                        onClicked: root.downloadEpisode(root.curIdx)
                    }
                }
            }
        }
    }

    // ============ 下载 ============
    Component {
        id: downloadsPage
        Page {
            id: downloadsPageItem
            objectName: "ibdownloads"
            SilicaListView {
                id: downloadsList
                anchors.fill: parent
                clip: true
                model: downloader.tasks
                header: Column {
                    width: downloadsList.width
                    PageHeader {
                        title: "下载"
                        description: "保存在 " + downloader.dir
                    }
                    Label {
                        x: Theme.horizontalPageMargin
                        width: parent.width - Theme.horizontalPageMargin * 2
                        text: "点“导出”可复制到 ~/Downloads/小宝影院"
                        color: Theme.secondaryColor
                        font.pixelSize: Theme.fontSizeExtraSmall
                        wrapMode: Text.Wrap
                    }
                }
                delegate: BackgroundItem {
                    id: dlRow
                    width: downloadsList.width
                    height: Theme.itemSizeLarge * 2.4
                    Column {
                        anchors {
                            left: parent.left
                            right: parent.right
                            leftMargin: Theme.horizontalPageMargin
                            rightMargin: Theme.horizontalPageMargin
                            verticalCenter: parent.verticalCenter
                        }
                        spacing: Theme.paddingSmall
                        Label {
                            width: parent.width
                            text: (modelData.title || modelData.vod) + " · " + (modelData.label || "")
                            color: Theme.primaryColor
                            font.pixelSize: Theme.fontSizeSmall
                            elide: Text.ElideRight
                        }
                        ProgressBar {
                            width: parent.width
                            minimumValue: 0
                            maximumValue: 100
                            value: modelData.percent
                            visible: modelData.status !== "已完成"
                        }
                        Label {
                            width: parent.width
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
                            color: modelData.status === "失败" ? "#ff8080" : Theme.secondaryColor
                            font.pixelSize: Theme.fontSizeExtraSmall
                            elide: Text.ElideRight
                        }
                        Row {
                            spacing: Theme.paddingMedium
                            Button {
                                text: "播放"
                                preferredWidth: Theme.buttonWidthExtraSmall
                                visible: modelData.status === "已完成"
                                onClicked: root.playLocal(modelData)
                            }
                            Button {
                                text: "导出"
                                preferredWidth: Theme.buttonWidthExtraSmall
                                visible: modelData.status === "已完成"
                                onClicked: downloader.exportTask(modelData.key)
                            }
                            Button {
                                text: "重试"
                                preferredWidth: Theme.buttonWidthExtraSmall
                                visible: modelData.status === "失败"
                                    || modelData.status === "已取消"
                                    || modelData.status === "已中断"
                                onClicked: downloader.retry(modelData.key)
                            }
                            Button {
                                text: "取消"
                                preferredWidth: Theme.buttonWidthExtraSmall
                                visible: modelData.status === "排队中"
                                    || modelData.status === "获取列表"
                                    || modelData.status === "下载中"
                                    || modelData.status === "合并中"
                                    || modelData.status.indexOf("重试中") === 0
                                onClicked: downloader.cancel(modelData.key)
                            }
                            Button {
                                text: "删除"
                                preferredWidth: Theme.buttonWidthExtraSmall
                                onClicked: downloader.remove(modelData.key)
                            }
                        }
                    }
                }
                ViewPlaceholder {
                    enabled: downloader.tasks.length === 0
                    text: "还没有下载任务"
                    hintText: "详情页选集右侧点“下载”即可"
                }
            }
        }
    }

    // ============ 观看记录 ============
    Component {
        id: historyPage
        Page {
            id: historyPageItem
            objectName: "ibhistory"
            SilicaListView {
                id: historyList
                anchors.fill: parent
                clip: true
                model: root.historyList
                header: PageHeader { title: "观看记录" }
                delegate: BackgroundItem {
                    width: historyList.width
                    height: Theme.itemSizeMedium
                    Column {
                        anchors {
                            left: parent.left
                            leftMargin: Theme.horizontalPageMargin
                            verticalCenter: parent.verticalCenter
                        }
                        width: parent.width - Theme.horizontalPageMargin * 2
                        spacing: Theme.paddingSmall
                        Label {
                            width: parent.width
                            text: modelData.title || modelData.id
                            color: Theme.primaryColor
                            font.pixelSize: Theme.fontSizeSmall
                            elide: Text.ElideRight
                        }
                        Label {
                            text: "第 " + (modelData.episode || 1) + " 集"
                                + (modelData.position > 0
                                   ? " · " + root.fmt(modelData.position) : "")
                            color: Theme.secondaryColor
                            font.pixelSize: Theme.fontSizeExtraSmall
                        }
                    }
                    onClicked: root.openDetail(modelData.id)
                }
                ViewPlaceholder {
                    enabled: root.historyList.length === 0
                    text: "还没有观看记录"
                }
                PushUpMenu {
                    MenuItem {
                        text: "清空记录"
                        enabled: root.historyList.length > 0
                        onClicked: {
                            backend.clearHistory()
                            root.historyList = []
                            root.refreshHistory()
                            root.refreshResume()
                        }
                    }
                }
            }
        }
    }

    // ============ 设置 ============
    Component {
        id: settingsPage
        Page {
            id: settingsPageItem
            objectName: "ibsettings"
            SilicaFlickable {
                anchors.fill: parent
                contentHeight: settingsColumn.height + Theme.paddingLarge * 2
                Column {
                    id: settingsColumn
                    width: parent.width
                    PageHeader { title: "设置" }
                    TextSwitch {
                        text: "启动后自动续看"
                        description: "从上次的剧集和进度接着播放"
                        checked: backend.resumeOnLaunch()
                        onClicked: backend.setResumeOnLaunch(checked)
                    }
                    TextSwitch {
                        text: "自动连播"
                        description: "播完后自动切换下一集"
                        checked: backend.autoNext()
                        onClicked: backend.setAutoNext(checked)
                    }
                    TextSwitch {
                        text: "后台继续播放"
                        description: "离开应用后继续播声音（画面只在应用内）"
                        checked: backend.backgroundPlayback()
                        onClicked: backend.setBackgroundPlayback(checked)
                    }
                    BackgroundItem {
                        width: parent.width
                        height: Theme.itemSizeMedium
                        Label {
                            anchors {
                                left: parent.left
                                leftMargin: Theme.horizontalPageMargin
                                verticalCenter: parent.verticalCenter
                            }
                            text: "下载管理"
                            color: Theme.highlightColor
                            font.pixelSize: Theme.fontSizeSmall
                        }
                        onClicked: pushPage(downloadsPage)
                    }
                    SectionHeader { text: "说明" }
                    Label {
                        x: Theme.horizontalPageMargin
                        width: parent.width - Theme.horizontalPageMargin * 2
                        text: "片源来自 ibaotv.com 的公开页面，播放地址为站点提供的 m3u8；"
                            + "本应用只做聚合与播放，版权归原权利人所有，仅供个人学习研究。"
                        color: Theme.secondaryColor
                        font.pixelSize: Theme.fontSizeExtraSmall
                        wrapMode: Text.Wrap
                    }
                    Label {
                        x: Theme.horizontalPageMargin
                        width: parent.width - Theme.horizontalPageMargin * 2
                        text: "小宝影院 · Sailfish 原生版 v" + root.appVersion
                        color: Theme.secondaryColor
                        font.pixelSize: Theme.fontSizeExtraSmall
                        wrapMode: Text.Wrap
                    }
                }
            }
        }
    }

    // ============ 封面 ============
    Component {
        id: coverComponent
        CoverBackground {
            Label {
                anchors {
                    top: parent.top
                    topMargin: Theme.paddingLarge
                    horizontalCenter: parent.horizontalCenter
                }
                text: "小宝影院"
                color: Theme.primaryColor
                font.pixelSize: Theme.fontSizeLarge
            }
            Label {
                anchors {
                    bottom: parent.bottom
                    bottomMargin: Theme.paddingLarge
                    horizontalCenter: parent.horizontalCenter
                }
                text: root.playerActive ? "播放中" : (root.curFile !== "" ? "小窗播放中" : "ibaotv.com")
                color: Theme.secondaryColor
                font.pixelSize: Theme.fontSizeExtraSmall
            }
        }
    }

    Component.onCompleted: {
        playerOrient = backend.playerOrient()
        playRate = backend.playbackRate()
        if (playRate < 0.5 || playRate > 3.0)
            playRate = 1.0
        refreshHistory()
        refreshResume()
        loadTab(0, true, "")
    }
}
