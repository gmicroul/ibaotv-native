/*
 * ibaotv-native —— 小宝影院（ibaotv.com）本机原生壳
 *
 * 数据链：node xbweb.js 解析站点 HTML/JSON（分类列表、搜索、详情、播放页）
 *         播放页 player_aaaa 里的 url 是免签 m3u8 直链。
 * 播放：QtMultimedia + media-hub 直接喂 m3u8（本机已实测可解析 HLS），
 *       播放页/选集/搜索/记录/设置沿用红果原生版的交互。
 *
 * 仅供个人学习研究。站点内容版权归原权利人所有。
 */
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlError>
#include <QTextStream>
#include <QEventLoop>
#include <QElapsedTimer>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QProcess>
#include <QCoreApplication>
#include <QDateTime>
#include <QSettings>
#include <QStandardPaths>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QUrl>
#include <QHash>
#include <QDebug>
#include <QNetworkAccessManager>
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QDesktopServices>
#include <QRegularExpression>
#include <QTimer>
#include <unistd.h>

class Backend : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    Q_PROPERTY(QString cacheDir READ cacheDir CONSTANT)
    Q_PROPERTY(QString nodeDir READ nodeDir CONSTANT)

public:
    explicit Backend(QObject *parent = nullptr)
        : QObject(parent)
    {
        // click 包名 ibaotv.utu；media-hub 只放行 ~/.cache/<包名>/，日志也放这里
        m_cache = QDir::homePath() + QStringLiteral("/.cache/ibaotv.utu/ibaotv-native");
        QDir().mkpath(m_cache);
        m_nodeDir = QCoreApplication::applicationDirPath() + QStringLiteral("/node");
    }

    QString status() const { return m_status; }
    QString cacheDir() const { return m_cache; }
    QString nodeDir() const { return m_nodeDir; }

    QString nodeBin() const
    {
        const QString bundled = m_nodeDir + QStringLiteral("/bin/node");
        if (QFileInfo(bundled).isExecutable())
            return bundled;
        QString s = QStandardPaths::findExecutable(QStringLiteral("node"));
        if (!s.isEmpty())
            return s;
        return QStandardPaths::findExecutable(QStringLiteral("nodejs"));
    }

    // ---- 分类列表 / 搜索：node xbweb.js ----
    Q_INVOKABLE QVariantMap rankList(const QString &tid, int page)
    {
        QVariantMap out;
        bool ok = false;
        setStatus(QStringLiteral("加载列表…"));
        const QString s = runNode({m_nodeDir + QStringLiteral("/xbweb.js"),
                                   QStringLiteral("list"), tid, QString::number(page)}, 30000, &ok);
        setStatus(QString());
        if (!ok)
            return out;
        out = QJsonDocument::fromJson(s.toUtf8()).object().toVariantMap();
        qInfo() << "ibaotv: 列表 tid" << tid << "页" << page
                << "共" << out.value(QStringLiteral("pagecount")).toInt() << "页"
                << out.value(QStringLiteral("cards")).toList().size() << "条";
        return out;
    }

    Q_INVOKABLE QVariantMap searchList(const QString &keyword, int page)
    {
        QVariantMap out;
        if (keyword.trimmed().isEmpty())
            return out;
        bool ok = false;
        setStatus(QStringLiteral("搜索中…"));
        const QString s = runNode({m_nodeDir + QStringLiteral("/xbweb.js"),
                                   QStringLiteral("search"), keyword.trimmed(),
                                   QString::number(page)}, 30000, &ok);
        setStatus(QString());
        if (!ok)
            return out;
        out = QJsonDocument::fromJson(s.toUtf8()).object().toVariantMap();
        qInfo() << "ibaotv: 搜索" << keyword << "页" << page
                << out.value(QStringLiteral("cards")).toList().size() << "条";
        return out;
    }

    // ---- 详情（含选集） ----
    Q_INVOKABLE QVariantMap detail(const QString &id)
    {
        QVariantMap d;
        bool ok = false;
        setStatus(QStringLiteral("取详情…"));
        const QString s = runNode({m_nodeDir + QStringLiteral("/xbweb.js"),
                                   QStringLiteral("detail"), id}, 35000, &ok);
        setStatus(QString());
        if (ok)
            d = QJsonDocument::fromJson(s.toUtf8()).object().toVariantMap();
        qInfo() << "ibaotv: 详情" << id << d.value(QStringLiteral("title")).toString()
                << "共" << d.value(QStringLiteral("episodes")).toList().size() << "集";
        return d;
    }

    // ---- 播放页 → m3u8 直链（内存缓存，切回同集不再请求） ----
    Q_INVOKABLE QString playUrl(const QString &id, const QString &sid, const QString &nid)
    {
        const QString key = id + QLatin1Char('/') + sid + QLatin1Char('/') + nid;
        if (m_urlCache.contains(key))
            return m_urlCache.value(key);
        bool ok = false;
        setStatus(QStringLiteral("取播放地址…"));
        const QString s = runNode({m_nodeDir + QStringLiteral("/xbweb.js"),
                                   QStringLiteral("playurl"), id, sid, nid}, 25000, &ok);
        setStatus(QString());
        if (!ok) {
            logLine(QStringLiteral("playUrl FAIL id=") + id + QStringLiteral(" sid=") + sid
                    + QStringLiteral(" nid=") + nid);
            return QString();
        }
        const QString url = QJsonDocument::fromJson(s.toUtf8()).object()
                                .value(QStringLiteral("url")).toString();
        if (!url.isEmpty())
            m_urlCache.insert(key, url);
        qInfo() << "ibaotv: 播放地址" << id << sid << nid << url.left(90);
        return url;
    }

    // ---- 播放进度（按 vod id + 选集 nid 存） ----
    Q_INVOKABLE void savePos(const QString &key, qint64 ms)
    {
        if (key.isEmpty())
            return;
        QSettings().setValue(QStringLiteral("pos/") + key, ms);
    }

    Q_INVOKABLE qint64 loadPos(const QString &key)
    {
        if (key.isEmpty())
            return 0;
        return QSettings().value(QStringLiteral("pos/") + key, 0).toLongLong();
    }

    Q_INVOKABLE void saveLast(const QString &sid, const QString &vid)
    {
        QSettings s;
        s.setValue(QStringLiteral("last/sid"), sid);
        s.setValue(QStringLiteral("last/vid"), vid);
    }

    Q_INVOKABLE QVariantMap loadLast()
    {
        QSettings s;
        QVariantMap m;
        m.insert(QStringLiteral("sid"), s.value(QStringLiteral("last/sid")).toString());
        m.insert(QStringLiteral("vid"), s.value(QStringLiteral("last/vid")).toString());
        return m;
    }

    Q_INVOKABLE QString durationText(qint64 ms) const
    {
        if (ms < 0 || ms > 360000000)
            return QStringLiteral("--:--");
        const qint64 sec = ms / 1000;
        const qint64 h = sec / 3600;
        const qint64 m = (sec % 3600) / 60;
        const qint64 s = sec % 60;
        if (h > 0)
            return QStringLiteral("%1:%2:%3").arg(h).arg(m, 2, 10, QLatin1Char('0')).arg(s, 2, 10, QLatin1Char('0'));
        return QStringLiteral("%1:%2").arg(m, 2, 10, QLatin1Char('0')).arg(s, 2, 10, QLatin1Char('0'));
    }

    // ---- 观看记录（QSettings 存 50 条） ----
    Q_INVOKABLE QVariantList history() const
    {
        return QSettings().value(QStringLiteral("history/list")).toList();
    }

    Q_INVOKABLE void saveHistory(const QString &sid, const QString &title, int episode, qint64 pos, const QString &cover)
    {
        if (sid.isEmpty())
            return;
        QSettings s;
        QVariantList list = s.value(QStringLiteral("history/list")).toList();
        QVariantList kept;
        for (const QVariant &v : list) {
            if (v.toMap().value(QStringLiteral("id")).toString() != sid)
                kept.append(v);
        }
        QVariantMap e;
        e.insert(QStringLiteral("id"), sid);
        e.insert(QStringLiteral("title"), title);
        e.insert(QStringLiteral("episode"), episode);
        e.insert(QStringLiteral("position"), pos);
        e.insert(QStringLiteral("cover"), cover);
        e.insert(QStringLiteral("updated"), QDateTime::currentMSecsSinceEpoch());
        kept.prepend(e);
        while (kept.size() > 50)
            kept.removeLast();
        s.setValue(QStringLiteral("history/list"), kept);
    }

    Q_INVOKABLE void clearHistory()
    {
        QSettings().remove(QStringLiteral("history/list"));
    }

    // ---- 设置 ----
    Q_INVOKABLE bool resumeOnLaunch() const { return QSettings().value(QStringLiteral("pref/resumeOnLaunch"), true).toBool(); }
    Q_INVOKABLE void setResumeOnLaunch(bool v) { QSettings().setValue(QStringLiteral("pref/resumeOnLaunch"), v); }
    Q_INVOKABLE bool autoNext() const { return QSettings().value(QStringLiteral("pref/autoNext"), true).toBool(); }
    Q_INVOKABLE void setAutoNext(bool v) { QSettings().setValue(QStringLiteral("pref/autoNext"), v); }
    Q_INVOKABLE bool backgroundPlayback() const { return QSettings().value(QStringLiteral("pref/backgroundPlayback"), false).toBool(); }
    Q_INVOKABLE void setBackgroundPlayback(bool v) { QSettings().setValue(QStringLiteral("pref/backgroundPlayback"), v); }
    Q_INVOKABLE double playbackRate() const { return QSettings().value(QStringLiteral("pref/playbackRate"), 1.0).toDouble(); }
    Q_INVOKABLE void setPlaybackRate(double v)
    {
        if (v < 0.5) v = 0.5;
        if (v > 3.0) v = 3.0;
        QSettings().setValue(QStringLiteral("pref/playbackRate"), v);
    }

    Q_INVOKABLE void logLine(const QString &text)
    {
        const QString p = m_cache + QStringLiteral("/playback.log");
        QFile f(p);
        if (f.exists() && f.size() > 262144)
            f.remove();
        if (f.open(QIODevice::Append | QIODevice::Text)) {
            QTextStream ts(&f);
            ts << QDateTime::currentDateTime().toString(QStringLiteral("MM-dd hh:mm:ss "))
               << text << QStringLiteral("\n");
        }
    }

signals:
    void statusChanged();

private:
    QString runNode(const QStringList &args, int timeoutMs, bool *ok = nullptr)
    {
        const QString nb = nodeBin();
        if (nb.isEmpty()) {
            qWarning() << "ibaotv: 找不到 node（自带/系统均无）";
            setStatus(QStringLiteral("缺 node 运行环境"));
            if (ok)
                *ok = false;
            return QString();
        }
        QProcess p;
        p.setProgram(nb);
        p.setArguments(args);
        p.setProcessChannelMode(QProcess::SeparateChannels);
        p.start();
        if (!p.waitForStarted(10000)) {
            if (ok)
                *ok = false;
            return QString();
        }
        QByteArray out;
        QElapsedTimer t;
        t.start();
        while (!p.waitForFinished(300)) {
            QCoreApplication::processEvents(QEventLoop::AllEvents, 100);
            out += p.readAllStandardOutput();
            if (t.elapsed() > timeoutMs) {
                p.kill();
                qWarning() << "ibaotv: node 超时" << args;
                setStatus(QStringLiteral("网络超时"));
                if (ok)
                    *ok = false;
                return QString();
            }
        }
        out += p.readAllStandardOutput();
        const QByteArray err = p.readAllStandardError();
        if (!err.trimmed().isEmpty())
            qWarning() << "ibaotv: node stderr" << err.left(300);
        if (ok)
            *ok = (p.exitCode() == 0);
        return QString::fromUtf8(out).trimmed();
    }

    void setStatus(const QString &s)
    {
        if (m_status == s)
            return;
        m_status = s;
        emit statusChanged();
    }

    QString m_status;
    QString m_cache;
    QString m_nodeDir;
    QHash<QString, QString> m_urlCache;
};

// ============ HLS 下载器 ============
// 取流地址是免签 m3u8（VOD），逐段下载 TS 后直接拼接，
// 有 ffmpeg 就 remux 成 mp4（不转码），否则保留 .ts。
// 落盘到 ~/Videos/小宝影院/（media-hub 放行且文件管理器可见）。
class DownloadManager : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QVariantList tasks READ tasks NOTIFY tasksChanged)
    Q_PROPERTY(QString dir READ dir CONSTANT)

public:
    explicit DownloadManager(QObject *parent = nullptr)
        : QObject(parent)
    {
        m_dir = QDir::homePath() + QStringLiteral("/Videos/小宝影院");
        QDir().mkpath(m_dir);
        m_uiTimer.setSingleShot(true);
        m_uiTimer.setInterval(500);
        connect(&m_uiTimer, &QTimer::timeout, this, [this]() { rebuild(); });
        load();
    }
    ~DownloadManager() override
    {
        if (m_reply) {
            m_reply->disconnect(this);
            m_reply->abort();
            m_reply->deleteLater();
            m_reply = nullptr;
        }
        if (m_ff) {
            m_ff->kill();
            m_ff->deleteLater();
            m_ff = nullptr;
        }
        qDeleteAll(m_tasks);
        m_tasks.clear();
    }

    QString dir() const { return m_dir; }
    QVariantList tasks() const { return m_view; }

    Q_INVOKABLE QVariantMap info(const QString &vod, const QString &nid)
    {
        Task *t = find(vod + QLatin1Char('/') + nid);
        return t ? t->toMap() : QVariantMap();
    }

    Q_INVOKABLE void start(const QString &vod, const QString &title, const QString &cover,
                           const QString &sid, const QString &nid, const QString &label,
                           int index, const QString &url)
    {
        if (vod.isEmpty() || nid.isEmpty() || url.isEmpty())
            return;
        const QString key = vod + QLatin1Char('/') + nid;
        Task *old = find(key);
        if (old) {
            if (old->status == QStringLiteral("已完成") || isActive(old->status))
                return;
            old->title = title; old->cover = cover; old->sid = sid; old->label = label;
            old->index = index; old->url = url;
            old->status = QStringLiteral("排队中");
            old->error.clear();
            old->percent = 0; old->segDone = 0; old->segTotal = 0; old->segIdx = 0;
            old->bytes = 0; old->speed = 0; old->retries = 0; old->depth = 0;
            rebuild();
            schedule();
            return;
        }
        Task *t = new Task;
        t->key = key; t->vod = vod; t->title = title; t->cover = cover;
        t->sid = sid.isEmpty() ? QStringLiteral("1") : sid;
        t->nid = nid; t->label = label; t->index = index; t->url = url;
        t->status = QStringLiteral("排队中");
        m_tasks.prepend(t);
        rebuild();
        schedule();
    }

    Q_INVOKABLE void cancel(const QString &key)
    {
        Task *t = find(key);
        if (!t)
            return;
        if (m_active == t) {
            if (m_reply) {
                m_reply->disconnect(this);
                m_reply->abort();
                m_reply->deleteLater();
                m_reply = nullptr;
            }
            if (m_ff) {
                m_ff->kill();
                m_ff->deleteLater();
                m_ff = nullptr;
            }
            closeOut(t);
            if (!t->tmp.isEmpty())
                QFile::remove(t->tmp);
            t->status = QStringLiteral("已取消");
            t->percent = 0; t->speed = 0;
            m_active = nullptr;
        } else if (isActive(t->status)) {
            t->status = QStringLiteral("已取消");
        }
        rebuild();
        schedule();
    }

    Q_INVOKABLE void retry(const QString &key)
    {
        Task *t = find(key);
        if (!t || isActive(t->status) || t->status == QStringLiteral("已完成"))
            return;
        t->status = QStringLiteral("排队中");
        t->error.clear();
        t->percent = 0; t->segDone = 0; t->segTotal = 0; t->segIdx = 0;
        t->bytes = 0; t->speed = 0; t->retries = 0; t->depth = 0;
        rebuild();
        schedule();
    }

    Q_INVOKABLE void remove(const QString &key)
    {
        Task *t = find(key);
        if (!t)
            return;
        if (m_active == t)
            cancel(key);
        t = find(key);
        if (!t)
            return;
        if (!t->file.isEmpty() && t->file.startsWith(m_dir) && QFileInfo::exists(t->file))
            QFile::remove(t->file);
        if (!t->tmp.isEmpty() && t->tmp.startsWith(m_dir))
            QFile::remove(t->tmp);
        m_tasks.removeAll(t);
        delete t;
        rebuild();
        schedule();
    }

    Q_INVOKABLE void openFolder()
    {
        QDesktopServices::openUrl(QUrl::fromLocalFile(m_dir));
    }

signals:
    void tasksChanged();

private:
    struct Task {
        QString key, vod, title, cover, sid, nid, label, url;
        QString status, error, file, tmp;
        int index = 0, percent = 0, segDone = 0, segTotal = 0, segIdx = 0;
        int retries = 0, depth = 0;
        qint64 bytes = 0, lastBytes = 0, lastMs = 0;
        double speed = 0;
        QList<QUrl> segments;
        QFile *out = nullptr;
        ~Task()
        {
            if (out) {
                out->close();
                delete out;
            }
        }
        QVariantMap toMap() const
        {
            QVariantMap m;
            m.insert(QStringLiteral("key"), key);
            m.insert(QStringLiteral("vod"), vod);
            m.insert(QStringLiteral("title"), title);
            m.insert(QStringLiteral("cover"), cover);
            m.insert(QStringLiteral("sid"), sid);
            m.insert(QStringLiteral("nid"), nid);
            m.insert(QStringLiteral("label"), label);
            m.insert(QStringLiteral("index"), index);
            m.insert(QStringLiteral("status"), status);
            m.insert(QStringLiteral("percent"), percent);
            m.insert(QStringLiteral("segDone"), segDone);
            m.insert(QStringLiteral("segTotal"), segTotal);
            m.insert(QStringLiteral("bytes"), bytes);
            m.insert(QStringLiteral("speed"), speed);
            m.insert(QStringLiteral("file"), file);
            m.insert(QStringLiteral("error"), error);
            return m;
        }
    };

    static bool isActive(const QString &s)
    {
        return s == QStringLiteral("排队中") || s == QStringLiteral("获取列表")
            || s == QStringLiteral("下载中") || s == QStringLiteral("合并中")
            || s.startsWith(QStringLiteral("重试中"));
    }

    Task *find(const QString &key) const
    {
        for (Task *t : m_tasks) {
            if (t->key == key)
                return t;
        }
        return nullptr;
    }

    static QString sanitize(const QString &in)
    {
        QString s = in.trimmed();
        s.replace(QRegularExpression(QStringLiteral("[\\\\/:*?\"<>|\\r\\n\\t]")), QStringLiteral("_"));
        if (s.isEmpty())
            s = QStringLiteral("未命名");
        return s.left(60);
    }

    void schedule()
    {
        if (m_active || m_ff)
            return;
        for (Task *t : m_tasks) {
            if (t->status == QStringLiteral("排队中")) {
                begin(t);
                return;
            }
        }
    }

    void begin(Task *t)
    {
        m_active = t;
        t->depth = 0;
        t->segments.clear();
        t->status = QStringLiteral("获取列表");
        rebuild();
        fetchPlaylist(t, QUrl(t->url));
    }

    void fetchPlaylist(Task *t, const QUrl &u)
    {
        QNetworkRequest req(u);
        req.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
        req.setRawHeader("User-Agent", "Mozilla/5.0 (Linux; Ubuntu Touch)");
        m_reply = m_nam.get(req);
        connect(m_reply, &QNetworkReply::finished, this, [this, t, u]() { onPlaylist(t, u); });
    }

    void onPlaylist(Task *t, const QUrl &base)
    {
        QNetworkReply *r = m_reply;
        m_reply = nullptr;
        if (!r || m_active != t)
            return;
        r->deleteLater();
        if (r->error() != QNetworkReply::NoError) {
            fail(t, QStringLiteral("获取列表失败：") + r->errorString());
            return;
        }
        const QString text = QString::fromUtf8(r->readAll());
        const QStringList lines = text.split(QLatin1Char('\n'));
        double bestBw = -1;
        QUrl best;
        for (int i = 0; i < lines.size(); ++i) {
            const QString ln = lines[i].trimmed();
            if (!ln.startsWith(QStringLiteral("#EXT-X-STREAM-INF")))
                continue;
            double bw = 0;
            const int bi = ln.indexOf(QStringLiteral("BANDWIDTH="));
            if (bi >= 0) {
                int e = bi + 10;
                while (e < ln.size() && (ln.at(e).isDigit() || ln.at(e) == QLatin1Char('.')))
                    ++e;
                bw = ln.mid(bi + 10, e - bi - 10).toDouble();
            }
            for (int j = i + 1; j < lines.size(); ++j) {
                const QString u = lines[j].trimmed();
                if (u.isEmpty() || u.startsWith(QLatin1Char('#')))
                    continue;
                if (bw >= bestBw) {
                    bestBw = bw;
                    best = base.resolved(QUrl(u));
                }
                break;
            }
        }
        if (best.isValid()) {
            if (t->depth >= 2) {
                fail(t, QStringLiteral("播放列表嵌套过深"));
                return;
            }
            t->depth++;
            fetchPlaylist(t, best);
            return;
        }
        if (text.contains(QStringLiteral("#EXT-X-KEY"))) {
            fail(t, QStringLiteral("加密流暂不支持下载"));
            return;
        }
        QList<QUrl> segs;
        for (const QString &raw : lines) {
            const QString ln = raw.trimmed();
            if (ln.isEmpty() || ln.startsWith(QLatin1Char('#')))
                continue;
            segs.append(base.resolved(QUrl(ln)));
        }
        if (segs.isEmpty()) {
            fail(t, QStringLiteral("播放列表为空"));
            return;
        }
        t->segments = segs;
        t->segTotal = segs.size();
        t->segIdx = 0;
        t->segDone = 0;
        t->percent = 0;
        t->bytes = 0;
        t->lastBytes = 0;
        t->lastMs = QDateTime::currentMSecsSinceEpoch();
        const QString titleDir = m_dir + QLatin1Char('/')
            + sanitize(t->title.isEmpty() ? t->vod : t->title);
        QDir().mkpath(titleDir);
        const QString stem = QStringLiteral("%1 %2")
            .arg(t->index + 1, 3, 10, QLatin1Char('0'))
            .arg(sanitize(t->label));
        t->tmp = titleDir + QLatin1Char('/') + stem + QStringLiteral(".ts.part");
        t->file = titleDir + QLatin1Char('/') + stem + QStringLiteral(".mp4");
        closeOut(t);
        t->out = new QFile(t->tmp);
        if (!t->out->open(QIODevice::WriteOnly | QIODevice::Truncate)) {
            const QString err = t->out->errorString();
            closeOut(t);
            fail(t, QStringLiteral("无法写入：") + err);
            return;
        }
        t->status = QStringLiteral("下载中");
        rebuild();
        nextSegment(t);
    }

    void nextSegment(Task *t)
    {
        if (m_active != t)
            return;
        if (t->segIdx >= t->segTotal) {
            finalize(t);
            return;
        }
        QNetworkRequest req(t->segments[t->segIdx]);
        req.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
        req.setRawHeader("User-Agent", "Mozilla/5.0 (Linux; Ubuntu Touch)");
        req.setTransferTimeout(30000);
        m_reply = m_nam.get(req);
        connect(m_reply, &QNetworkReply::readyRead, this, [this, t]() {
            if (!m_reply || !t->out)
                return;
            const QByteArray chunk = m_reply->readAll();
            t->out->write(chunk);
            t->bytes += chunk.size();
            const qint64 now = QDateTime::currentMSecsSinceEpoch();
            if (now - t->lastMs >= 1000) {
                t->speed = double(t->bytes - t->lastBytes) * 1000.0 / double(now - t->lastMs);
                t->lastBytes = t->bytes;
                t->lastMs = now;
                touch();
            }
        });
        connect(m_reply, &QNetworkReply::finished, this, [this, t]() { onSegment(t); });
    }

    void onSegment(Task *t)
    {
        QNetworkReply *r = m_reply;
        m_reply = nullptr;
        if (!r || m_active != t)
            return;
        r->deleteLater();
        if (r->error() != QNetworkReply::NoError) {
            if (++t->retries <= 3) {
                t->status = QStringLiteral("重试中(%1/3)").arg(t->retries);
                rebuild();
                QTimer::singleShot(1200, this, [this, t]() {
                    if (m_active == t && m_tasks.contains(t))
                        nextSegment(t);
                });
                return;
            }
            fail(t, QStringLiteral("下载失败：") + r->errorString());
            return;
        }
        if (t->out) {
            const QByteArray chunk = r->readAll();
            t->out->write(chunk);
            t->bytes += chunk.size();
        }
        t->retries = 0;
        t->segIdx++;
        t->segDone++;
        t->percent = t->segTotal > 0 ? int(qint64(t->segDone) * 100 / t->segTotal) : 0;
        touch();
        nextSegment(t);
    }

    void finalize(Task *t)
    {
        closeOut(t);
        const QString ts = t->tmp;
        const QString ff = QStandardPaths::findExecutable(QStringLiteral("ffmpeg"));
        if (ff.isEmpty()) {
            const QString plain = ts.left(ts.size() - 5);
            QFile::remove(plain);
            if (QFile::rename(ts, plain))
                t->file = plain;
            else {
                fail(t, QStringLiteral("保存文件失败"));
                return;
            }
            t->tmp.clear();
            t->status = QStringLiteral("已完成");
            t->percent = 100;
            t->speed = 0;
            m_active = nullptr;
            rebuild();
            schedule();
            return;
        }
        t->status = QStringLiteral("合并中");
        t->percent = 100;
        t->speed = 0;
        rebuild();
        m_ff = new QProcess(this);
        const QString outFile = t->file;
        QStringList args;
        args << QStringLiteral("-y") << QStringLiteral("-v") << QStringLiteral("error")
             << QStringLiteral("-i") << ts
             << QStringLiteral("-c") << QStringLiteral("copy")
             << QStringLiteral("-bsf:a") << QStringLiteral("aac_adtstoasc")
             << outFile;
        connect(m_ff, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this,
                [this, t, ts, outFile](int code, QProcess::ExitStatus) {
            QProcess *p = m_ff;
            m_ff = nullptr;
            if (p)
                p->deleteLater();
            if (code == 0 && QFileInfo::exists(outFile)) {
                QFile::remove(ts);
                t->status = QStringLiteral("已完成");
                t->error.clear();
                t->tmp.clear();
            } else {
                const QString plain = ts.left(ts.size() - 5);
                QFile::remove(plain);
                if (QFile::rename(ts, plain)) {
                    t->file = plain;
                    t->tmp.clear();
                    t->status = QStringLiteral("已完成");
                    t->error = QStringLiteral("已保存为 .ts");
                } else {
                    t->status = QStringLiteral("失败");
                    t->error = QStringLiteral("合并失败");
                }
            }
            t->percent = 100;
            m_active = nullptr;
            rebuild();
            schedule();
        });
        m_ff->start(ff, args);
    }

    void fail(Task *t, const QString &msg)
    {
        closeOut(t);
        if (!t->tmp.isEmpty())
            QFile::remove(t->tmp);
        t->status = QStringLiteral("失败");
        t->error = msg;
        t->speed = 0;
        if (m_active == t)
            m_active = nullptr;
        rebuild();
        QTimer::singleShot(0, this, [this]() { schedule(); });
    }

    void closeOut(Task *t)
    {
        if (t->out) {
            t->out->close();
            delete t->out;
            t->out = nullptr;
        }
    }

    void touch()
    {
        if (!m_uiTimer.isActive())
            m_uiTimer.start();
    }

    void rebuild()
    {
        QVariantList v;
        for (Task *t : m_tasks)
            v.append(t->toMap());
        m_view = v;
        save();
        emit tasksChanged();
    }

    void save()
    {
        QSettings s;
        QVariantList list;
        for (Task *t : m_tasks)
            list.append(t->toMap());
        s.setValue(QStringLiteral("downloads/list"), list);
    }

    void load()
    {
        QSettings s;
        const QVariantList list = s.value(QStringLiteral("downloads/list")).toList();
        for (const QVariant &v : list) {
            const QVariantMap m = v.toMap();
            Task *t = new Task;
            t->key = m.value(QStringLiteral("key")).toString();
            t->vod = m.value(QStringLiteral("vod")).toString();
            t->title = m.value(QStringLiteral("title")).toString();
            t->cover = m.value(QStringLiteral("cover")).toString();
            t->sid = m.value(QStringLiteral("sid")).toString();
            t->nid = m.value(QStringLiteral("nid")).toString();
            t->label = m.value(QStringLiteral("label")).toString();
            t->index = m.value(QStringLiteral("index")).toInt();
            t->status = m.value(QStringLiteral("status")).toString();
            t->percent = m.value(QStringLiteral("percent")).toInt();
            t->segDone = m.value(QStringLiteral("segDone")).toInt();
            t->segTotal = m.value(QStringLiteral("segTotal")).toInt();
            t->bytes = m.value(QStringLiteral("bytes")).toLongLong();
            t->file = m.value(QStringLiteral("file")).toString();
            t->error = m.value(QStringLiteral("error")).toString();
            if (isActive(t->status)) {
                t->status = QStringLiteral("已中断");
                t->error = QStringLiteral("上次未完成，可重试");
                t->percent = 0;
                t->speed = 0;
            } else if (t->status == QStringLiteral("已完成") && !t->file.isEmpty()
                       && !QFileInfo::exists(t->file)) {
                t->status = QStringLiteral("失败");
                t->error = QStringLiteral("文件不存在");
            }
            m_tasks.append(t);
        }
        m_view.clear();
        for (Task *t : m_tasks)
            m_view.append(t->toMap());
    }

    QString m_dir;
    QVariantList m_view;
    QList<Task *> m_tasks;
    QNetworkAccessManager m_nam;
    QNetworkReply *m_reply = nullptr;
    QProcess *m_ff = nullptr;
    Task *m_active = nullptr;
    QTimer m_uiTimer;
};

int main(int argc, char *argv[])
{
    if (qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM")) {
        const QString plugDir = QStringLiteral("/usr/lib/aarch64-linux-gnu/qt5/plugins/platforms");
        const QList<QPair<QString, QString>> cands = {
            {QStringLiteral("ubuntumirclient"), QStringLiteral("libqpa-ubuntumirclient.so")},
            {QStringLiteral("wayland"), QStringLiteral("libqwayland-egl.so")},
        };
        for (const auto &c : cands) {
            if (QFile::exists(plugDir + QLatin1Char('/') + c.second)) {
                qputenv("QT_QPA_PLATFORM", c.first.toUtf8());
                break;
            }
        }
    }
    if (qEnvironmentVariableIsEmpty("XDG_RUNTIME_DIR")) {
        QByteArray uid = qgetenv("UID");
        if (uid.isEmpty())
            uid = QByteArray::number(getuid());
        qputenv("XDG_RUNTIME_DIR", QByteArray("/run/user/") + uid);
    }
    if (qEnvironmentVariableIsEmpty("XDG_SESSION_TYPE"))
        qputenv("XDG_SESSION_TYPE", QByteArray("mir"));

    QGuiApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("ibaotv-native"));
    app.setOrganizationName(QStringLiteral("ibaotv"));
    app.setApplicationVersion(QStringLiteral("0.2.1"));

    {
        const QString logDir = QDir::homePath() + QStringLiteral("/.cache/ibaotv.utu/ibaotv-native");
        QDir().mkpath(logDir);
        QFile lf(logDir + QStringLiteral("/startup.log"));
        if (lf.open(QIODevice::Append | QIODevice::Text)) {
            QTextStream ts(&lf);
            ts << QDateTime::currentDateTime().toString(QStringLiteral("MM-dd hh:mm:ss "))
               << QStringLiteral("qpa=") << QString::fromUtf8(qgetenv("QT_QPA_PLATFORM"))
               << QStringLiteral(" qt=") << QString::fromUtf8(qVersion())
               << QStringLiteral(" node=") << QStandardPaths::findExecutable(QStringLiteral("node"))
               << QStringLiteral("\n");
        }
    }

    Backend backend;
    DownloadManager downloader;
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("backend"), &backend);
    engine.rootContext()->setContextProperty(QStringLiteral("downloader"), &downloader);
    QQmlComponent comp(&engine, QUrl(QStringLiteral("qrc:/Main.qml")));
    if (comp.isError()) {
        qWarning() << "ibaotv-native: QML 加载失败";
        for (const QQmlError &e : comp.errors())
            qWarning().noquote() << "ibaotv-native QML:" << e.toString();
        return 1;
    }
    QObject *rootObj = comp.create();
    if (!rootObj) {
        qWarning() << "ibaotv-native: QML 实例化失败";
        return 1;
    }
    const int rc = app.exec();
    delete rootObj;
    return rc;
}
#include "main.moc"
