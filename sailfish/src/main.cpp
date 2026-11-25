#include "backend.h"
#include "downloader.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QQmlContext>
#include <QQmlError>
#include <QQuickItem>
#include <QQuickView>
#include <QScopedPointer>
#include <QTextStream>
#include <QVariantMap>

#include <sailfishapp.h>

static int runSelfTest(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("ibaotv-native"));
    app.setOrganizationName(QStringLiteral("ibaotv"));
    app.setApplicationVersion(QStringLiteral("0.2.2"));

    const QStringList args = app.arguments();
    const QString cmd = args.value(2);
    Backend backend;
    QVariantMap out;

    if (cmd == QStringLiteral("list") && args.size() >= 4) {
        out = backend.rankList(args.value(3), args.value(4, QStringLiteral("1")).toInt());
    } else if (cmd == QStringLiteral("search") && args.size() >= 4) {
        out = backend.searchList(args.value(3), args.value(4, QStringLiteral("1")).toInt());
    } else if (cmd == QStringLiteral("detail") && args.size() >= 4) {
        out = backend.detail(args.value(3));
    } else if (cmd == QStringLiteral("playurl") && args.size() >= 6) {
        out.insert(QStringLiteral("url"),
                   backend.playUrl(args.value(3), args.value(4), args.value(5)));
    } else {
        QTextStream(stderr) << "usage: --selftest list <tid> <page>\n"
                            << "       --selftest search <keyword> <page>\n"
                            << "       --selftest detail <vod_id>\n"
                            << "       --selftest playurl <vod_id> <sid> <nid>\n";
        return 2;
    }

    QTextStream(stdout) << QString::fromUtf8(
        QJsonDocument::fromVariant(out).toJson(QJsonDocument::Compact))
                        << "\n";
    return out.isEmpty() ? 1 : 0;
}

int main(int argc, char *argv[])
{
    for (int i = 1; i < argc; ++i) {
        if (QString::fromLocal8Bit(argv[i]) == QStringLiteral("--selftest"))
            return runSelfTest(argc, argv);
    }

    // OP6T 上的 droid 硬解插件在 SFOS 5.2 无法建解码器（Could not configure
    // supporting library），降权让 GStreamer 走 libav 软解；用户可自行覆盖。
    if (qEnvironmentVariableIsEmpty("GST_PLUGIN_FEATURE_RANK")) {
        qputenv("GST_PLUGIN_FEATURE_RANK",
                QByteArray("droidvdec:0,droidvideo:0,droidcodec:0"));
    }

    QScopedPointer<QGuiApplication> app(SailfishApp::application(argc, argv));
    app->setApplicationName(QStringLiteral("ibaotv-native"));
    app->setOrganizationName(QStringLiteral("ibaotv"));
    app->setApplicationVersion(QStringLiteral("0.2.2"));

    {
        const QString logDir = QDir::homePath() + QStringLiteral("/.cache/ibaotv-native");
        QDir().mkpath(logDir);
        QFile lf(logDir + QStringLiteral("/startup.log"));
        if (lf.open(QIODevice::Append | QIODevice::Text)) {
            QTextStream ts(&lf);
            ts << QDateTime::currentDateTime().toString(QStringLiteral("MM-dd hh:mm:ss "))
               << QStringLiteral("qt=") << QString::fromUtf8(qVersion())
               << QStringLiteral(" qpa=") << QString::fromUtf8(qgetenv("QT_QPA_PLATFORM"))
               << QStringLiteral("\n");
        }
    }

    QScopedPointer<QQuickView> view(SailfishApp::createView());
    Backend backend;
    DownloadManager downloader;
    view->rootContext()->setContextProperty(QStringLiteral("backend"), &backend);
    view->rootContext()->setContextProperty(QStringLiteral("downloader"), &downloader);
    view->setSource(QUrl(QStringLiteral("qrc:/qml/main.qml")));
    if (view->status() == QQuickView::Error) {
        qWarning() << "ibaotv-native: QML 加载失败";
        for (const QQmlError &e : view->errors())
            qWarning().noquote() << "ibaotv-native QML:" << e.toString();
        return 1;
    }
    view->show();

    if (view->rootObject()) {
        const QByteArray testPlay = qgetenv("IBAOTV_TEST_PLAY");
        if (!testPlay.isEmpty()) {
            QMetaObject::invokeMethod(view->rootObject(), "playDirect",
                                      Q_ARG(QVariant, QString::fromUtf8(testPlay)),
                                      Q_ARG(QVariant, QStringLiteral("自检播放")));
        }
        const QByteArray testDetail = qgetenv("IBAOTV_TEST_DETAIL");
        if (!testDetail.isEmpty()) {
            QMetaObject::invokeMethod(view->rootObject(), "testDetail",
                                      Q_ARG(QVariant, QString::fromUtf8(testDetail)));
        }
        const QByteArray testSearch = qgetenv("IBAOTV_TEST_SEARCH");
        if (!testSearch.isEmpty()) {
            QMetaObject::invokeMethod(view->rootObject(), "testSearch",
                                      Q_ARG(QVariant, QString::fromUtf8(testSearch)));
        }
        const QByteArray testOrient = qgetenv("IBAOTV_TEST_ORIENT");
        if (!testOrient.isEmpty()) {
            QMetaObject::invokeMethod(view->rootObject(), "setPlayerOrientTest",
                                      Q_ARG(QVariant, QString::fromUtf8(testOrient)));
        }
    }

    return app->exec();
}
