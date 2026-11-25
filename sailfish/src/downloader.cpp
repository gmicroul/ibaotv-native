#include "downloader.h"

#include <QDateTime>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcess>
#include <QRegularExpression>
#include <QSettings>
#include <QStandardPaths>
#include <QUrl>

namespace {
const char *kDlUserAgent = "Mozilla/5.0 (Linux; Sailfish)";
}

DownloadManager::Task::~Task()
{
    if (out) {
        out->close();
        delete out;
    }
}

QVariantMap DownloadManager::Task::toMap() const
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

DownloadManager::DownloadManager(QObject *parent)
    : QObject(parent)
{
    m_dir = QDir::homePath() + QStringLiteral("/Videos/小宝影院");
    QDir().mkpath(m_dir);
    m_uiTimer.setSingleShot(true);
    m_uiTimer.setInterval(500);
    connect(&m_uiTimer, &QTimer::timeout, this, [this]() { rebuild(); });
    load();
}

DownloadManager::~DownloadManager()
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

QVariantMap DownloadManager::info(const QString &vod, const QString &nid)
{
    Task *t = find(vod + QLatin1Char('/') + nid);
    return t ? t->toMap() : QVariantMap();
}

void DownloadManager::start(const QString &vod, const QString &title, const QString &cover,
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
        old->title = title;
        old->cover = cover;
        old->sid = sid;
        old->label = label;
        old->index = index;
        old->url = url;
        old->status = QStringLiteral("排队中");
        old->error.clear();
        old->percent = 0;
        old->segDone = 0;
        old->segTotal = 0;
        old->segIdx = 0;
        old->bytes = 0;
        old->speed = 0;
        old->retries = 0;
        old->depth = 0;
        rebuild();
        schedule();
        return;
    }
    Task *t = new Task;
    t->key = key;
    t->vod = vod;
    t->title = title;
    t->cover = cover;
    t->sid = sid.isEmpty() ? QStringLiteral("1") : sid;
    t->nid = nid;
    t->label = label;
    t->index = index;
    t->url = url;
    t->status = QStringLiteral("排队中");
    m_tasks.prepend(t);
    rebuild();
    schedule();
}

void DownloadManager::cancel(const QString &key)
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
        t->percent = 0;
        t->speed = 0;
        m_active = nullptr;
    } else if (isActive(t->status)) {
        t->status = QStringLiteral("已取消");
    }
    rebuild();
    schedule();
}

void DownloadManager::retry(const QString &key)
{
    Task *t = find(key);
    if (!t || isActive(t->status) || t->status == QStringLiteral("已完成"))
        return;
    t->status = QStringLiteral("排队中");
    t->error.clear();
    t->percent = 0;
    t->segDone = 0;
    t->segTotal = 0;
    t->segIdx = 0;
    t->bytes = 0;
    t->speed = 0;
    t->retries = 0;
    t->depth = 0;
    rebuild();
    schedule();
}

void DownloadManager::remove(const QString &key)
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

void DownloadManager::exportTask(const QString &key)
{
    Task *t = find(key);
    if (!t || t->status != QStringLiteral("已完成") || t->file.isEmpty()
        || !QFileInfo::exists(t->file))
        return;
    const QString dstDir = QDir::homePath() + QStringLiteral("/Downloads/小宝影院")
        + QLatin1Char('/') + sanitize(t->title.isEmpty() ? t->vod : t->title);
    QDir().mkpath(dstDir);
    const QString dst = dstDir + QLatin1Char('/') + QFileInfo(t->file).fileName();
    if (QFileInfo::exists(dst)) {
        t->error = QStringLiteral("下载目录已有同名文件");
        rebuild();
        return;
    }
    t->error = QStringLiteral("导出中…");
    rebuild();
    QProcess *p = new QProcess(this);
    connect(p, static_cast<void (QProcess::*)(int, QProcess::ExitStatus)>(&QProcess::finished),
            this, [this, t, p, dst](int code, QProcess::ExitStatus) {
                p->deleteLater();
                if (m_tasks.contains(t)) {
                    t->error = (code == 0 && QFileInfo::exists(dst))
                        ? QStringLiteral("已导出到 Downloads")
                        : QStringLiteral("导出失败");
                    rebuild();
                }
            });
    p->start(QStringLiteral("cp"), QStringList() << QStringLiteral("-n") << t->file << dst);
}

bool DownloadManager::isActive(const QString &s)
{
    return s == QStringLiteral("排队中") || s == QStringLiteral("获取列表")
        || s == QStringLiteral("下载中") || s == QStringLiteral("合并中")
        || s.startsWith(QStringLiteral("重试中"));
}

DownloadManager::Task *DownloadManager::find(const QString &key) const
{
    for (Task *t : m_tasks) {
        if (t->key == key)
            return t;
    }
    return nullptr;
}

QString DownloadManager::sanitize(const QString &in)
{
    QString s = in.trimmed();
    s.replace(QRegularExpression(QStringLiteral("[\\\\/:*?\"<>|\\r\\n\\t]")), QStringLiteral("_"));
    if (s.isEmpty())
        s = QStringLiteral("未命名");
    return s.left(60);
}

void DownloadManager::schedule()
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

void DownloadManager::begin(Task *t)
{
    m_active = t;
    t->depth = 0;
    t->segments.clear();
    t->status = QStringLiteral("获取列表");
    rebuild();
    fetchPlaylist(t, QUrl(t->url));
}

QNetworkReply *DownloadManager::get(const QUrl &u, int timeoutMs)
{
    QNetworkRequest req(u);
    req.setAttribute(QNetworkRequest::FollowRedirectsAttribute, true);
    req.setRawHeader("User-Agent", kDlUserAgent);
    req.setRawHeader("Referer", "https://ibaotv.com/");
    QNetworkReply *reply = m_nam.get(req);
    if (timeoutMs > 0) {
        QTimer *timer = new QTimer(reply);
        timer->setSingleShot(true);
        QObject::connect(timer, &QTimer::timeout, reply, &QNetworkReply::abort);
        timer->start(timeoutMs);
    }
    return reply;
}

void DownloadManager::fetchPlaylist(Task *t, const QUrl &u)
{
    m_reply = get(u, 30000);
    connect(m_reply, &QNetworkReply::finished, this, [this, t, u]() { onPlaylist(t, u); });
}

void DownloadManager::onPlaylist(Task *t, const QUrl &base)
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

void DownloadManager::nextSegment(Task *t)
{
    if (m_active != t)
        return;
    if (t->segIdx >= t->segTotal) {
        finalize(t);
        return;
    }
    m_reply = get(t->segments[t->segIdx], 30000);
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

void DownloadManager::onSegment(Task *t)
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

void DownloadManager::finalize(Task *t)
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
    connect(m_ff, static_cast<void (QProcess::*)(int, QProcess::ExitStatus)>(&QProcess::finished),
            this, [this, t, ts, outFile](int code, QProcess::ExitStatus) {
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

void DownloadManager::fail(Task *t, const QString &msg)
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

void DownloadManager::closeOut(Task *t)
{
    if (t->out) {
        t->out->close();
        delete t->out;
        t->out = nullptr;
    }
}

void DownloadManager::touch()
{
    if (!m_uiTimer.isActive())
        m_uiTimer.start();
}

void DownloadManager::rebuild()
{
    QVariantList v;
    for (Task *t : m_tasks)
        v.append(t->toMap());
    m_view = v;
    save();
    emit tasksChanged();
}

void DownloadManager::save()
{
    QSettings s;
    QVariantList list;
    for (Task *t : m_tasks)
        list.append(t->toMap());
    s.setValue(QStringLiteral("downloads/list"), list);
}

void DownloadManager::load()
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
            if (!t->file.isEmpty() && QFileInfo::exists(t->file)) {
                t->status = QStringLiteral("已完成");
                t->error.clear();
                t->percent = 100;
                t->speed = 0;
            } else {
                t->status = QStringLiteral("已中断");
                t->error = QStringLiteral("上次未完成，可重试");
                t->percent = 0;
                t->speed = 0;
            }
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
