#ifndef IBAOTV_DOWNLOADER_H
#define IBAOTV_DOWNLOADER_H

#include <QObject>
#include <QList>
#include <QNetworkAccessManager>
#include <QString>
#include <QTimer>
#include <QUrl>
#include <QVariantList>
#include <QVariantMap>

class QNetworkReply;
class QProcess;
class QFile;

class DownloadManager : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QVariantList tasks READ tasks NOTIFY tasksChanged)
    Q_PROPERTY(QString dir READ dir CONSTANT)

public:
    explicit DownloadManager(QObject *parent = nullptr);
    ~DownloadManager() override;

    QString dir() const { return m_dir; }
    QVariantList tasks() const { return m_view; }

    Q_INVOKABLE QVariantMap info(const QString &vod, const QString &nid);

    Q_INVOKABLE void start(const QString &vod, const QString &title, const QString &cover,
                           const QString &sid, const QString &nid, const QString &label,
                           int index, const QString &url);
    Q_INVOKABLE void cancel(const QString &key);
    Q_INVOKABLE void retry(const QString &key);
    Q_INVOKABLE void remove(const QString &key);
    Q_INVOKABLE void exportTask(const QString &key);

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
        ~Task();
        QVariantMap toMap() const;
    };

    static bool isActive(const QString &s);
    Task *find(const QString &key) const;
    static QString sanitize(const QString &in);

    void schedule();
    void begin(Task *t);
    void fetchPlaylist(Task *t, const QUrl &u);
    void onPlaylist(Task *t, const QUrl &base);
    void nextSegment(Task *t);
    void onSegment(Task *t);
    void finalize(Task *t);
    void fail(Task *t, const QString &msg);
    void closeOut(Task *t);
    void touch();
    void rebuild();
    void save();
    void load();

    QNetworkReply *get(const QUrl &u, int timeoutMs);
    void armTimeout(QNetworkReply *reply, int timeoutMs);

    QString m_dir;
    QVariantList m_view;
    QList<Task *> m_tasks;
    QNetworkAccessManager m_nam;
    QNetworkReply *m_reply = nullptr;
    QProcess *m_ff = nullptr;
    Task *m_active = nullptr;
    QTimer m_uiTimer;
};

#endif
