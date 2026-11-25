#ifndef IBAOTV_BACKEND_H
#define IBAOTV_BACKEND_H

#include <QObject>
#include <QNetworkAccessManager>
#include <QHash>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>

class Backend : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    Q_PROPERTY(QString cacheDir READ cacheDir CONSTANT)

public:
    explicit Backend(QObject *parent = nullptr);

    QString status() const { return m_status; }
    QString cacheDir() const { return m_cache; }

    Q_INVOKABLE QVariantMap rankList(const QString &tid, int page);
    Q_INVOKABLE QVariantMap searchList(const QString &keyword, int page);
    Q_INVOKABLE QVariantMap detail(const QString &id);
    Q_INVOKABLE QString playUrl(const QString &id, const QString &sid, const QString &nid);

    Q_INVOKABLE void savePos(const QString &key, qint64 ms);
    Q_INVOKABLE qint64 loadPos(const QString &key);
    Q_INVOKABLE void saveLast(const QString &sid, const QString &vid);
    Q_INVOKABLE QVariantMap loadLast();
    Q_INVOKABLE QString durationText(qint64 ms) const;

    Q_INVOKABLE QVariantList history() const;
    Q_INVOKABLE void saveHistory(const QString &sid, const QString &title, int episode,
                                 qint64 pos, const QString &cover);
    Q_INVOKABLE void clearHistory();

    Q_INVOKABLE bool resumeOnLaunch() const;
    Q_INVOKABLE void setResumeOnLaunch(bool v);
    Q_INVOKABLE bool autoNext() const;
    Q_INVOKABLE void setAutoNext(bool v);
    Q_INVOKABLE bool backgroundPlayback() const;
    Q_INVOKABLE void setBackgroundPlayback(bool v);
    Q_INVOKABLE double playbackRate() const;
    Q_INVOKABLE void setPlaybackRate(double v);
    Q_INVOKABLE int playerOrient() const;
    Q_INVOKABLE void setPlayerOrient(int v);

    Q_INVOKABLE void logLine(const QString &text);
    Q_INVOKABLE void setStatus(const QString &s);

    static QString siteUrl();

signals:
    void statusChanged();

private:
    QByteArray httpGet(const QString &url, int timeoutMs, bool *ok, QString *error = nullptr,
                       int *statusCode = nullptr);
    QByteArray httpGetRetry(const QString &url, int timeoutMs, int attempts, bool *ok,
                            QString *error = nullptr, int *statusCode = nullptr);
    QByteArray curlGet(const QString &url, int timeoutSec, bool *ok, QString *error = nullptr,
                       int *statusCode = nullptr);
    void setStatusInternal(const QString &s);

    QNetworkAccessManager m_nam;
    QString m_status;
    QString m_cache;
    QHash<QString, QString> m_urlCache;
};

#endif
