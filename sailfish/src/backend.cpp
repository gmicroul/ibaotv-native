#include "backend.h"

#include <QDateTime>
#include <QDir>
#include <QEventLoop>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcess>
#include <QRegularExpression>
#include <QSettings>
#include <QStringList>
#include <QStandardPaths>
#include <QTextStream>
#include <QTimer>
#include <QUrl>
#include <QUrlQuery>
#include <QVariant>

#include <algorithm>

namespace {

const char *kSite = "https://ibaotv.com";
const char *kUserAgent =
    "Mozilla/5.0 (Linux; Android 10; Volla Phone Build/QP1A.191005.007) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.144 "
    "Mobile Safari/537.36";

QString valueToString(const QJsonValue &v)
{
    if (v.isString())
        return v.toString();
    if (v.isDouble())
        return QString::number(v.toDouble(), 'f', 0);
    if (v.isBool())
        return v.toBool() ? QStringLiteral("true") : QStringLiteral("false");
    return QString();
}

int valueToInt(const QJsonValue &v, int fallback = 0)
{
    if (v.isDouble())
        return v.toInt(fallback);
    if (v.isString()) {
        bool ok = false;
        const int n = v.toString().toInt(&ok);
        return ok ? n : fallback;
    }
    return fallback;
}

QString unesc(QString s)
{
    s.replace(QStringLiteral("&amp;"), QStringLiteral("&"));
    s.replace(QStringLiteral("&quot;"), QStringLiteral("\""));
    s.replace(QStringLiteral("&#39;"), QStringLiteral("'"));
    s.replace(QStringLiteral("&lt;"), QStringLiteral("<"));
    s.replace(QStringLiteral("&gt;"), QStringLiteral(">"));
    s.replace(QStringLiteral("&nbsp;"), QStringLiteral(" "));
    return s;
}

QString stripTags(QString s)
{
    static const QRegularExpression tags(QStringLiteral("<[^>]+>"));
    s.remove(tags);
    s = unesc(s);
    s.replace(QRegularExpression(QStringLiteral("\\s+")), QStringLiteral(" "));
    return s.trimmed();
}

QString firstGroup(const QString &text, const QRegularExpression &re)
{
    const QRegularExpressionMatch m = re.match(text);
    return m.hasMatch() ? m.captured(1) : QString();
}

QString absUrl(const QString &raw)
{
    QString u = raw.trimmed();
    if (u.isEmpty())
        return QString();
    static const QRegularExpression httpRe(QStringLiteral("^https?://"),
                                           QRegularExpression::CaseInsensitiveOption);
    if (httpRe.match(u).hasMatch())
        return u;
    return Backend::siteUrl() + (u.startsWith(QLatin1Char('/')) ? u : QLatin1Char('/') + u);
}

QVariantMap cardFromJson(const QJsonObject &v)
{
    QVariantMap card;
    card.insert(QStringLiteral("sid"), valueToString(v.value(QStringLiteral("vod_id"))));
    card.insert(QStringLiteral("title"), unesc(valueToString(v.value(QStringLiteral("vod_name")))));
    card.insert(QStringLiteral("cover"), absUrl(valueToString(v.value(QStringLiteral("vod_pic")))));
    card.insert(QStringLiteral("year"), valueToString(v.value(QStringLiteral("vod_year"))));
    QString cls = valueToString(v.value(QStringLiteral("vod_class")));
    cls.replace(QLatin1Char(','), QStringLiteral(" / "));
    card.insert(QStringLiteral("cls"), cls);
    card.insert(QStringLiteral("area"), valueToString(v.value(QStringLiteral("vod_area"))));
    card.insert(QStringLiteral("remarks"), valueToString(v.value(QStringLiteral("vod_remarks"))));
    return card;
}

QString percentEncode(const QString &s)
{
    return QString::fromLatin1(QUrl::toPercentEncoding(s));
}

} // namespace

Backend::Backend(QObject *parent)
    : QObject(parent)
{
    m_cache = QDir::homePath() + QStringLiteral("/.cache/ibaotv-native");
    QDir().mkpath(m_cache);
}

QString Backend::siteUrl()
{
    const QByteArray env = qgetenv("IBAOTV_SITE");
    if (!env.isEmpty())
        return QString::fromUtf8(env).trimmed();
    return QString::fromLatin1(kSite);
}

QByteArray Backend::httpGet(const QString &url, int timeoutMs, bool *ok, QString *error,
                            int *statusCode)
{
    if (ok)
        *ok = false;
    if (error)
        error->clear();
    if (statusCode)
        *statusCode = 0;

    QNetworkRequest req((QUrl(url)));
    req.setRawHeader("User-Agent", kUserAgent);
    req.setRawHeader("Accept",
                     "text/html,application/xhtml+xml,application/json,application/xml;q=0.9,*/*;q=0.8");
    req.setRawHeader("Accept-Language", "zh-CN,zh;q=0.9");
    req.setRawHeader("Referer", siteUrl().toUtf8() + "/");
    req.setAttribute(QNetworkRequest::FollowRedirectsAttribute, true);

    QNetworkReply *reply = m_nam.get(req);
    QEventLoop loop;
    QTimer timer;
    timer.setSingleShot(true);
    QObject::connect(&timer, &QTimer::timeout, &loop, [&loop]() { loop.quit(); });
    QObject::connect(reply, &QNetworkReply::finished, &loop, &QEventLoop::quit);
    timer.start(timeoutMs);
    loop.exec();

    const int httpStatus =
        reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (statusCode)
        *statusCode = httpStatus;

    QByteArray data;
    if (!reply->isFinished()) {
        reply->abort();
        if (error)
            *error = QStringLiteral("网络超时");
    } else if (reply->error() != QNetworkReply::NoError) {
        if (error)
            *error = reply->errorString();
    } else {
        data = reply->readAll();
        if (ok)
            *ok = true;
        if (error)
            error->clear();
    }
    reply->deleteLater();
    return data;
}

QByteArray Backend::curlGet(const QString &url, int timeoutSec, bool *ok, QString *error,
                            int *statusCode)
{
    if (ok)
        *ok = false;
    const QString curl = QStandardPaths::findExecutable(QStringLiteral("curl"));
    if (curl.isEmpty()) {
        if (error)
            *error = QStringLiteral("无 curl 可用");
        return QByteArray();
    }
    QProcess p;
    QStringList args;
    args << QStringLiteral("-sL") << QStringLiteral("--compressed")
         << QStringLiteral("-m") << QString::number(timeoutSec)
         << QStringLiteral("-A") << QString::fromLatin1(kUserAgent)
         << QStringLiteral("-e") << siteUrl() + QStringLiteral("/")
         << QStringLiteral("-H") << QStringLiteral("Accept-Language: zh-CN,zh;q=0.9")
         << QStringLiteral("-w") << QStringLiteral("\\n%{http_code}")
         << url;
    p.start(curl, args);
    if (!p.waitForStarted(5000)) {
        if (error)
            *error = QStringLiteral("curl 启动失败");
        return QByteArray();
    }
    if (!p.waitForFinished((timeoutSec + 10) * 1000)) {
        p.kill();
        if (error)
            *error = QStringLiteral("curl 超时");
        return QByteArray();
    }
    QByteArray out = p.readAllStandardOutput();
    const int nl = out.lastIndexOf('\n');
    int status = 0;
    if (nl >= 0) {
        status = out.mid(nl + 1).trimmed().toInt();
        out.truncate(nl);
    }
    if (statusCode)
        *statusCode = status;
    if (p.exitCode() != 0 || out.isEmpty()) {
        if (error)
            *error = QStringLiteral("curl 失败 code=%1").arg(p.exitCode());
        return QByteArray();
    }
    if (ok)
        *ok = true;
    return out;
}

QByteArray Backend::httpGetRetry(const QString &url, int timeoutMs, int attempts, bool *ok,
                                 QString *error, int *statusCode)
{
    for (int i = 0; i < attempts; ++i) {
        bool aok = false;
        QString aerr;
        int st = 0;
        const QByteArray data = httpGet(url, timeoutMs, &aok, &aerr, &st);
        if (aok) {
            if (ok)
                *ok = true;
            if (error)
                error->clear();
            if (statusCode)
                *statusCode = st;
            return data;
        }
        if (statusCode)
            *statusCode = st;
        if (error)
            *error = aerr;
        qWarning() << "ibaotv: 请求失败" << (i + 1) << "/" << attempts << aerr
                   << url.left(90);
    }

    bool cok = false;
    QString cerr;
    int cst = 0;
    qWarning() << "ibaotv: 改用 curl" << url.left(90);
    const QByteArray data = curlGet(url, qMax(10, timeoutMs / 1000), &cok, &cerr, &cst);
    if (cok) {
        if (ok)
            *ok = true;
        if (error)
            error->clear();
        if (statusCode)
            *statusCode = cst;
        return data;
    }
    if (ok)
        *ok = false;
    if (error)
        *error = cerr;
    if (statusCode)
        *statusCode = cst;
    return QByteArray();
}

void Backend::setStatusInternal(const QString &s)
{
    if (m_status == s)
        return;
    m_status = s;
    emit statusChanged();
}

void Backend::setStatus(const QString &s)
{
    setStatusInternal(s);
}

QVariantMap Backend::rankList(const QString &tid, int page)
{
    QVariantMap out;
    if (page < 1)
        page = 1;
    setStatusInternal(QStringLiteral("加载列表…"));
    bool ok = false;
    QString err;
    const QString url = siteUrl() + QStringLiteral("/index.php/ajax/data?mid=1&tid=")
        + percentEncode(tid) + QStringLiteral("&page=") + QString::number(page);
    const QByteArray data = httpGetRetry(url, 20000, 2, &ok, &err);
    setStatusInternal(QString());
    if (!ok) {
        qWarning() << "ibaotv: 列表失败" << err;
        return out;
    }
    QJsonParseError pe;
    const QJsonDocument doc = QJsonDocument::fromJson(data, &pe);
    if (pe.error != QJsonParseError::NoError || !doc.isObject()) {
        qWarning() << "ibaotv: 列表返回非 JSON" << pe.errorString();
        return out;
    }
    const QJsonObject d = doc.object();
    int pagecount = valueToInt(d.value(QStringLiteral("pagecount")), 1);
    if (pagecount < 1)
        pagecount = 1;
    QVariantList cards;
    if (page <= pagecount) {
        const QJsonArray list = d.value(QStringLiteral("list")).toArray();
        for (const QJsonValue &v : list) {
            if (v.isObject())
                cards.append(cardFromJson(v.toObject()));
        }
    }
    out.insert(QStringLiteral("page"), page);
    out.insert(QStringLiteral("pagecount"), pagecount);
    out.insert(QStringLiteral("cards"), cards);
    qInfo() << "ibaotv: 列表 tid" << tid << "页" << page << "共" << pagecount
            << "页" << cards.size() << "条";
    return out;
}

QVariantMap Backend::searchList(const QString &keyword, int page)
{
    QVariantMap out;
    if (keyword.trimmed().isEmpty())
        return out;
    if (page < 1)
        page = 1;
    setStatusInternal(QStringLiteral("搜索中…"));
    const QString wd = percentEncode(keyword.trimmed());
    const QString url = page <= 1
        ? siteUrl() + QStringLiteral("/index.php/vod/search.html?wd=") + wd
        : siteUrl() + QStringLiteral("/index.php/vod/search/page/") + QString::number(page)
            + QStringLiteral("/wd/") + wd + QStringLiteral(".html");
    bool ok = false;
    QString err;
    int status = 0;
    const QByteArray data = httpGetRetry(url, 15000, 2, &ok, &err, &status);
    setStatusInternal(QString());
    if (!ok && status == 404) {
        out.insert(QStringLiteral("page"), page);
        out.insert(QStringLiteral("pagecount"), page);
        out.insert(QStringLiteral("cards"), QVariantList());
        return out;
    }
    if (!ok) {
        qWarning() << "ibaotv: 搜索失败" << err;
        return out;
    }
    const QString html = QString::fromUtf8(data);

    int pagecount = 1;
    {
        static const QRegularExpression pageRe(QStringLiteral("search/page/(\\d+)/wd/"));
        auto it = pageRe.globalMatch(html);
        while (it.hasNext()) {
            const int n = it.next().captured(1).toInt();
            if (n > pagecount)
                pagecount = n;
        }
    }

    int begin = html.indexOf(QStringLiteral("id=\"searchList\""));
    QString block;
    if (begin >= 0) {
        const int end = html.indexOf(QStringLiteral("</ul>"), begin);
        block = html.mid(begin, (end > begin ? end : html.size()) - begin);
    }

    QVariantList cards;
    QStringList seen;
    static const QRegularExpression liRe(
        QStringLiteral(R"(<li class="clearfix">([\s\S]*?)</li>)"));
    static const QRegularExpression hrefRe(
        QStringLiteral(R"iba(href="(/index\.php/vod/detail/id/\d+\.html)")iba"));
    static const QRegularExpression idRe(QStringLiteral("/id/(\\d+)\\.html"));
    static const QRegularExpression anchorRe(
        QStringLiteral(R"(<a class="myui-vodlist__thumb[^"]*"([^>]*)>)"));
    static const QRegularExpression titleRe(QStringLiteral("title=\"([^\"]*)\""));
    static const QRegularExpression coverRe(QStringLiteral("data-original=\"([^\"]*)\""));
    static const QRegularExpression yearRe1(QStringLiteral("年份：</span>([^<]*)<"));
    static const QRegularExpression yearRe2(
        QStringLiteral("<span class=\"tag\"[^>]*>([^<]*)</span>"));
    static const QRegularExpression clsRe(QStringLiteral("分类：</span>([^<]*)<"));
    static const QRegularExpression areaRe(QStringLiteral("地区：</span>([^<]*)<"));
    static const QRegularExpression remarksRe(
        QStringLiteral("<span class=\"pic-text text-right\">([^<]*)</span>"));

    auto it = liRe.globalMatch(block);
    while (it.hasNext()) {
        const QString li = it.next().captured(1);
        const QString href = firstGroup(li, hrefRe);
        const QString sid = firstGroup(href, idRe);
        if (sid.isEmpty() || seen.contains(sid))
            continue;
        seen.append(sid);
        const QString anchor = firstGroup(li, anchorRe);
        QString title = stripTags(firstGroup(anchor, titleRe));
        if (title.isEmpty())
            title = sid;
        QString year = firstGroup(li, yearRe1);
        if (year.isEmpty())
            year = firstGroup(li, yearRe2);
        QString cls = firstGroup(li, clsRe);
        cls.replace(QLatin1Char(','), QStringLiteral(" / "));
        const int anchorEnd = li.indexOf(QStringLiteral("</a>"));
        const QString head = anchorEnd >= 0 ? li.left(anchorEnd + 4) : li;

        QVariantMap card;
        card.insert(QStringLiteral("sid"), sid);
        card.insert(QStringLiteral("title"), title);
        card.insert(QStringLiteral("cover"), absUrl(firstGroup(li, coverRe)));
        card.insert(QStringLiteral("year"), year.trimmed());
        card.insert(QStringLiteral("cls"), cls.trimmed());
        card.insert(QStringLiteral("area"), firstGroup(li, areaRe).trimmed());
        card.insert(QStringLiteral("remarks"), firstGroup(head, remarksRe).trimmed());
        cards.append(card);
    }

    out.insert(QStringLiteral("page"), page);
    out.insert(QStringLiteral("pagecount"), pagecount);
    out.insert(QStringLiteral("cards"), cards);
    qInfo() << "ibaotv: 搜索" << keyword << "页" << page << cards.size() << "条";
    return out;
}

static QString detailField(const QString &seg, const QString &name)
{
    const QRegularExpression re(
        QStringLiteral("%1：\\s*</span>([\\s\\S]*?)(?=<span class=\"text-muted|</p>|<br|</li>|$)")
            .arg(QRegularExpression::escape(name)));
    return stripTags(firstGroup(seg, re));
}

QVariantMap Backend::detail(const QString &id)
{
    QVariantMap d;
    setStatusInternal(QStringLiteral("取详情…"));
    bool ok = false;
    QString err;
    const QString url = siteUrl() + QStringLiteral("/index.php/vod/detail/id/")
        + percentEncode(id) + QStringLiteral(".html");
    const QByteArray data = httpGetRetry(url, 20000, 2, &ok, &err);
    setStatusInternal(QString());
    if (!ok) {
        qWarning() << "ibaotv: 详情失败" << err;
        return d;
    }
    const QString html = QString::fromUtf8(data);

    int di = html.indexOf(QStringLiteral("myui-content__detail"));
    const QString seg = di >= 0 ? html.mid(di, 6000) : QString();

    QString title = stripTags(firstGroup(
        html, QRegularExpression(QStringLiteral("<h1[^>]*>([\\s\\S]*?)</h1>"))));
    if (title.isEmpty()) {
        title = stripTags(firstGroup(
            html, QRegularExpression(QStringLiteral(
                      "<meta[^>]+property=\"og:title\"[^>]+content=\"([^\"]*)\""))));
    }
    if (title.isEmpty()) {
        qWarning() << "ibaotv: 未找到影片标题" << id;
        return d;
    }

    QString cover = absUrl(firstGroup(
        html, QRegularExpression(QStringLiteral(
                  "<meta[^>]+property=\"og:image\"[^>]+content=\"([^\"]*)\""))));
    if (cover.isEmpty())
        cover = absUrl(firstGroup(
            seg, QRegularExpression(QStringLiteral("data-original=\"([^\"]*)\""))));

    QString intro = stripTags(firstGroup(
        html, QRegularExpression(QStringLiteral(
                  "<span class=\"sketch content\">([\\s\\S]*?)</span>"))));
    if (intro.isEmpty())
        intro = detailField(seg, QStringLiteral("简介"));

    struct Group {
        QString sid;
        QVariantList episodes;
    };
    QList<Group> groups;
    static const QRegularExpression groupRe(QStringLiteral(
        R"iba(<div id="playlist(\d+)"[\s\S]*?<ul class="myui-content__list[\s\S]*?</ul>)iba"));
    static const QRegularExpression epAnchorRe(QStringLiteral(
        R"(<a[^>]+href="[^"]*/vod/play/id/\d+/sid/\d+/nid/(\d+)\.html"[^>]*>([\s\S]*?)</a>)"));
    auto git = groupRe.globalMatch(html);
    while (git.hasNext()) {
        const QRegularExpressionMatch gm = git.next();
        Group g;
        g.sid = gm.captured(1);
        const QString block = gm.captured(0);
        auto ait = epAnchorRe.globalMatch(block);
        while (ait.hasNext()) {
            const QRegularExpressionMatch am = ait.next();
            QVariantMap ep;
            ep.insert(QStringLiteral("nid"), am.captured(1));
            ep.insert(QStringLiteral("label"), stripTags(am.captured(2)));
            g.episodes.append(ep);
        }
        if (!g.episodes.isEmpty())
            groups.append(g);
    }
    if (groups.isEmpty()) {
        Group g;
        g.sid = QStringLiteral("1");
        static const QRegularExpression allAnchorRe(QStringLiteral(
            R"(href="[^"]*/vod/play/id/\d+/sid/(\d+)/nid/(\d+)\.html"[^>]*>([\s\S]*?)</a>)"));
        auto ait = allAnchorRe.globalMatch(html);
        while (ait.hasNext()) {
            const QRegularExpressionMatch am = ait.next();
            const QString label = stripTags(am.captured(3));
            if (label.isEmpty() || label.contains(QStringLiteral("立即播放")))
                continue;
            QVariantMap ep;
            ep.insert(QStringLiteral("nid"), am.captured(2));
            ep.insert(QStringLiteral("label"), label);
            g.episodes.append(ep);
        }
        if (!g.episodes.isEmpty())
            groups.append(g);
    }

    std::stable_sort(groups.begin(), groups.end(), [](const Group &a, const Group &b) {
        return a.episodes.size() > b.episodes.size();
    });
    const Group best = groups.isEmpty() ? Group() : groups.first();

    QVariantList episodes;
    QStringList seenNid;
    for (const QVariant &v : best.episodes) {
        const QVariantMap in = v.toMap();
        const QString nid = in.value(QStringLiteral("nid")).toString();
        if (nid.isEmpty() || seenNid.contains(nid))
            continue;
        seenNid.append(nid);
        QString label = in.value(QStringLiteral("label")).toString();
        if (label.isEmpty())
            label = QStringLiteral("第%1集").arg(episodes.size() + 1);
        QVariantMap ep;
        ep.insert(QStringLiteral("nid"), nid);
        ep.insert(QStringLiteral("sid"), best.sid);
        ep.insert(QStringLiteral("index"), episodes.size() + 1);
        ep.insert(QStringLiteral("label"), label);
        episodes.append(ep);
    }

    d.insert(QStringLiteral("sid"), QString::number(id.toLongLong()));
    d.insert(QStringLiteral("title"), title);
    d.insert(QStringLiteral("cover"), cover);
    d.insert(QStringLiteral("intro"), intro);
    d.insert(QStringLiteral("cls"), detailField(seg, QStringLiteral("分类")));
    d.insert(QStringLiteral("area"), detailField(seg, QStringLiteral("地区")));
    d.insert(QStringLiteral("year"), detailField(seg, QStringLiteral("年份")));
    d.insert(QStringLiteral("updated"), detailField(seg, QStringLiteral("更新")));
    d.insert(QStringLiteral("actor"), detailField(seg, QStringLiteral("主演")));
    d.insert(QStringLiteral("director"), detailField(seg, QStringLiteral("导演")));
    d.insert(QStringLiteral("total"), episodes.size());
    d.insert(QStringLiteral("sources"), groups.size());
    d.insert(QStringLiteral("playSid"), best.sid);
    d.insert(QStringLiteral("episodes"), episodes);
    qInfo() << "ibaotv: 详情" << id << title << "共" << episodes.size() << "集";
    return d;
}

QString Backend::playUrl(const QString &id, const QString &sid, const QString &nid)
{
    const QString key = id + QLatin1Char('/') + sid + QLatin1Char('/') + nid;
    if (m_urlCache.contains(key))
        return m_urlCache.value(key);

    setStatusInternal(QStringLiteral("取播放地址…"));
    bool ok = false;
    QString err;
    const QString url = siteUrl() + QStringLiteral("/index.php/vod/play/id/")
        + percentEncode(id) + QStringLiteral("/sid/") + percentEncode(sid)
        + QStringLiteral("/nid/") + percentEncode(nid) + QStringLiteral(".html");
    const QByteArray data = httpGetRetry(url, 15000, 2, &ok, &err);
    setStatusInternal(QString());
    if (!ok) {
        logLine(QStringLiteral("playUrl FAIL id=") + id + QStringLiteral(" sid=") + sid
                + QStringLiteral(" nid=") + nid + QStringLiteral(" err=") + err);
        return QString();
    }
    const QString html = QString::fromUtf8(data);
    const QRegularExpression re(
        QStringLiteral(R"(player_aaaa\s*=\s*(\{[\s\S]*?\})\s*;?\s*</script>)"),
        QRegularExpression::DotMatchesEverythingOption);
    const QString jsonText = firstGroup(html, re);
    if (jsonText.isEmpty()) {
        qWarning() << "ibaotv: 播放页无播放地址" << id << sid << nid;
        logLine(QStringLiteral("playUrl NO-DATA id=") + id);
        return QString();
    }
    QJsonParseError pe;
    const QJsonDocument doc = QJsonDocument::fromJson(jsonText.toUtf8(), &pe);
    if (pe.error != QJsonParseError::NoError || !doc.isObject()) {
        qWarning() << "ibaotv: 播放信息解析失败" << pe.errorString();
        return QString();
    }
    const QJsonObject j = doc.object();
    const int encrypt = valueToInt(j.value(QStringLiteral("encrypt")));
    if (encrypt != 0) {
        qWarning() << "ibaotv: 播放源已加密";
        return QString();
    }
    QString play = j.value(QStringLiteral("url")).toString();
    play.replace(QStringLiteral("\\/"), QStringLiteral("/"));
    if (play.isEmpty())
        return QString();
    static const QRegularExpression mediaRe(
        QStringLiteral("\\.m3u8(\\?|$)|\\.mp4(\\?|$)"),
        QRegularExpression::CaseInsensitiveOption);
    if (!mediaRe.match(play).hasMatch()) {
        qWarning() << "ibaotv: 暂不支持该播放格式" << play.left(80);
        return QString();
    }
    m_urlCache.insert(key, play);
    qInfo() << "ibaotv: 播放地址" << id << sid << nid << play.left(90);
    return play;
}

void Backend::savePos(const QString &key, qint64 ms)
{
    if (key.isEmpty())
        return;
    QSettings().setValue(QStringLiteral("pos/") + key, ms);
}

qint64 Backend::loadPos(const QString &key)
{
    if (key.isEmpty())
        return 0;
    return QSettings().value(QStringLiteral("pos/") + key, 0).toLongLong();
}

void Backend::saveLast(const QString &sid, const QString &vid)
{
    QSettings s;
    s.setValue(QStringLiteral("last/sid"), sid);
    s.setValue(QStringLiteral("last/vid"), vid);
}

QVariantMap Backend::loadLast()
{
    QSettings s;
    QVariantMap m;
    m.insert(QStringLiteral("sid"), s.value(QStringLiteral("last/sid")).toString());
    m.insert(QStringLiteral("vid"), s.value(QStringLiteral("last/vid")).toString());
    return m;
}

QString Backend::durationText(qint64 ms) const
{
    if (ms < 0 || ms > 360000000)
        return QStringLiteral("--:--");
    const qint64 sec = ms / 1000;
    const qint64 h = sec / 3600;
    const qint64 m = (sec % 3600) / 60;
    const qint64 s = sec % 60;
    if (h > 0) {
        return QStringLiteral("%1:%2:%3").arg(h)
            .arg(m, 2, 10, QLatin1Char('0'))
            .arg(s, 2, 10, QLatin1Char('0'));
    }
    return QStringLiteral("%1:%2").arg(m, 2, 10, QLatin1Char('0'))
        .arg(s, 2, 10, QLatin1Char('0'));
}

QVariantList Backend::history() const
{
    return QSettings().value(QStringLiteral("history/list")).toList();
}

void Backend::saveHistory(const QString &sid, const QString &title, int episode,
                          qint64 pos, const QString &cover)
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

void Backend::clearHistory()
{
    QSettings s;
    const QStringList keys = s.allKeys();
    for (const QString &key : keys) {
        if (key == QStringLiteral("history/list")
                || key.startsWith(QStringLiteral("pos/"))
                || key == QStringLiteral("last/sid")
                || key == QStringLiteral("last/vid"))
            s.remove(key);
    }
    s.sync();
}

bool Backend::resumeOnLaunch() const
{
    return QSettings().value(QStringLiteral("pref/resumeOnLaunch"), true).toBool();
}

void Backend::setResumeOnLaunch(bool v)
{
    QSettings().setValue(QStringLiteral("pref/resumeOnLaunch"), v);
}

bool Backend::autoNext() const
{
    return QSettings().value(QStringLiteral("pref/autoNext"), true).toBool();
}

void Backend::setAutoNext(bool v)
{
    QSettings().setValue(QStringLiteral("pref/autoNext"), v);
}

bool Backend::backgroundPlayback() const
{
    return QSettings().value(QStringLiteral("pref/backgroundPlayback"), false).toBool();
}

void Backend::setBackgroundPlayback(bool v)
{
    QSettings().setValue(QStringLiteral("pref/backgroundPlayback"), v);
}

double Backend::playbackRate() const
{
    return QSettings().value(QStringLiteral("pref/playbackRate"), 1.0).toDouble();
}

void Backend::setPlaybackRate(double v)
{
    if (v < 0.5)
        v = 0.5;
    if (v > 3.0)
        v = 3.0;
    QSettings().setValue(QStringLiteral("pref/playbackRate"), v);
}

int Backend::playerOrient() const
{
    return QSettings().value(QStringLiteral("pref/playerOrient"), 0).toInt();
}

void Backend::setPlayerOrient(int v)
{
    if (v < 0 || v > 2)
        v = 0;
    QSettings().setValue(QStringLiteral("pref/playerOrient"), v);
}

void Backend::logLine(const QString &text)
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
