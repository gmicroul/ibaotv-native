#include "backend.h"
#include "downloadadapter.h"

#include <QAudioOutput>
#include <QCoreApplication>
#include <QDebug>
#include <QGuiApplication>
#include <QImage>
#include <QImageReader>
#include <QJsonDocument>
#include <QMediaPlayer>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QQuickItem>
#include <QQuickWindow>
#include <QScreen>
#include <QTemporaryDir>
#include <QTextStream>
#include <QTimer>
#include <QVideoFrame>
#include <QVideoSink>

static void configureApplication(QCoreApplication &application)
{
    application.setApplicationName(QStringLiteral("ibaotv-native"));
    application.setOrganizationName(QStringLiteral("ibaotv.LuneOS"));
    application.setApplicationVersion(QStringLiteral("0.2.2"));
}

static int runSelfTest(int argc, char *argv[])
{
    QCoreApplication application(argc, argv);
    configureApplication(application);
    const QStringList arguments = application.arguments();
    const QString command = arguments.value(2);
    Backend backend;
    QVariantMap result;
    bool successful = false;
    if (command == QStringLiteral("list") && arguments.size() >= 4) {
        result = backend.rankList(arguments.value(3), arguments.value(4, QStringLiteral("1")).toInt());
        successful = !result.value(QStringLiteral("cards")).toList().isEmpty();
    } else if (command == QStringLiteral("search") && arguments.size() >= 4) {
        result = backend.searchList(arguments.value(3), arguments.value(4, QStringLiteral("1")).toInt());
        successful = !result.value(QStringLiteral("cards")).toList().isEmpty();
    } else if (command == QStringLiteral("detail") && arguments.size() >= 4) {
        result = backend.detail(arguments.value(3));
        successful = !result.value(QStringLiteral("episodes")).toList().isEmpty();
    } else if (command == QStringLiteral("playurl") && arguments.size() >= 6) {
        const QString url = backend.playUrl(arguments.value(3), arguments.value(4), arguments.value(5));
        result.insert(QStringLiteral("url"), url);
        successful = !url.isEmpty();
    } else {
        QTextStream(stderr) << "Usage: --selftest list <tid> [page]\n"
                            << "       --selftest search <keyword> [page]\n"
                            << "       --selftest detail <vod_id>\n"
                            << "       --selftest playurl <vod_id> <sid> <nid>\n";
        return 2;
    }
    QTextStream(stdout) << QJsonDocument::fromVariant(result).toJson(QJsonDocument::Compact) << '\n';
    return successful ? 0 : 1;
}

int main(int argc, char *argv[])
{
    const QString mode = argc > 1 ? QString::fromLocal8Bit(argv[1]) : QString();
    const QString parameter = argc > 2 ? QString::fromLocal8Bit(argv[2]) : QString();
    const bool smokeTest = mode == QStringLiteral("--smoke-test");
    const bool listTest = mode == QStringLiteral("--test-list");
    const bool searchTest = mode == QStringLiteral("--test-search");
    const bool detailTest = mode == QStringLiteral("--test-detail");
    const bool videoTest = mode == QStringLiteral("--test-video");
    const bool episodeTest = mode == QStringLiteral("--test-episode");
    const bool playbackTest = videoTest || episodeTest;
    const bool imageTest = mode == QStringLiteral("--test-image");
    const bool orientationTest = mode == QStringLiteral("--test-orientation");
    const bool screenshot = mode == QStringLiteral("--screenshot");
    const bool diagnostic = smokeTest || listTest || searchTest || detailTest || playbackTest || imageTest || orientationTest
        || mode == QStringLiteral("--selftest");
    const bool waylandTest = playbackTest && qEnvironmentVariableIntValue("IBAOTV_TEST_WAYLAND") == 1;
    QTemporaryDir temporaryHome(QStringLiteral("/tmp/ibaotv-luneos-check.XXXXXX"));
    if (diagnostic) {
        if (!temporaryHome.isValid())
            return 1;
        qputenv("HOME", temporaryHome.path().toUtf8());
        qputenv("XDG_CONFIG_HOME", (temporaryHome.path() + QStringLiteral("/config")).toUtf8());
        qputenv("XDG_CACHE_HOME", (temporaryHome.path() + QStringLiteral("/cache")).toUtf8());
    }
    if (mode == QStringLiteral("--selftest"))
        return runSelfTest(argc, argv);
    if ((listTest || searchTest || detailTest || playbackTest || imageTest || screenshot) && parameter.isEmpty()) {
        QTextStream(stderr) << "Usage: ibaotv-native [--smoke-test | --test-list <tid> | "
                            << "--test-search <keyword> | --test-detail <id> | "
                            << "--test-video <url> [--landscape] [--seconds <seconds>] | "
                            << "--test-episode <id> <episode-number> [--landscape] [--seconds <seconds>] | "
                            << "--test-image <file> | "
                            << "--test-orientation | --screenshot <png>]\n";
        return 2;
    }
    if (diagnostic && !waylandTest) {
        qputenv("QT_QPA_PLATFORM", "offscreen");
        qputenv("QT_QUICK_BACKEND", "software");
    }
    QQuickStyle::setStyle(QStringLiteral("Basic"));
    QGuiApplication application(argc, argv);
    configureApplication(application);
    application.setDesktopFileName(QStringLiteral("org.ibaotv.native"));
    const QStringList arguments = application.arguments();
    const bool landscapeVideo = playbackTest && arguments.contains(QStringLiteral("--landscape"));
    bool episodeNumberValid = false;
    const int episodeNumber = arguments.value(3).toInt(&episodeNumberValid);
    if (episodeTest && (!episodeNumberValid || episodeNumber < 1)) {
        QTextStream(stderr) << "--test-episode requires a positive episode number\n";
        return 2;
    }
    int playbackSeconds = episodeTest ? 15 : 1;
    const int secondsArgument = arguments.indexOf(QStringLiteral("--seconds"));
    if (playbackTest && secondsArgument >= 0) {
        bool secondsValid = false;
        playbackSeconds = arguments.value(secondsArgument + 1).toInt(&secondsValid);
        if (!secondsValid || playbackSeconds < 1 || playbackSeconds > 300) {
            QTextStream(stderr) << "--seconds must be between 1 and 300\n";
            return 2;
        }
    }
    const qint64 playbackMilliseconds = qint64(playbackSeconds) * 1000;
    QCoreApplication::addLibraryPath(application.applicationDirPath() + QStringLiteral("/../plugins"));
    if (imageTest) {
        const QImage image(parameter);
        qInfo() << (image.isNull() ? "IBAOTV_IMAGE_FAIL" : "IBAOTV_IMAGE_OK") << image.size();
        return image.isNull() ? 1 : 0;
    }
    if (smokeTest && !QImageReader::supportedImageFormats().contains(QByteArray("webp"))) {
        qCritical() << "IBAOTV_QML_FAIL WebP decoder unavailable";
        return 1;
    }
    Backend backend;
    DownloadAdapter downloader;
    QQmlApplicationEngine engine;
    bool qmlWarnings = false;
    QObject::connect(&engine, &QQmlEngine::warnings, &application,
                     [&qmlWarnings](const QList<QQmlError> &warnings) {
        for (const QQmlError &warning : warnings) {
            if (!warning.description().contains(QStringLiteral("deprecated"), Qt::CaseInsensitive))
                qmlWarnings = true;
        }
    });
    engine.rootContext()->setContextProperty(QStringLiteral("backend"), &backend);
    engine.rootContext()->setContextProperty(QStringLiteral("downloader"), &downloader);
    engine.rootContext()->setContextProperty(QStringLiteral("startupOffline"), diagnostic);
    engine.load(QUrl(QStringLiteral("qrc:/qml/Main.qml")));
    if (engine.rootObjects().isEmpty())
        return 1;
    auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
    if (!window)
        return 1;
    window->setProperty("appId", QStringLiteral("org.ibaotv.native"));
    window->setProperty("_WEBOS_WINDOW_TYPE", QStringLiteral("card"));
    if (application.primaryScreen())
        window->resize(application.primaryScreen()->size());
    if (orientationTest || landscapeVideo) {
        window->resize(1080, 2160);
        window->show();
    } else {
        window->showFullScreen();
    }
    qInfo().noquote() << "IBAOTV_START qt=" + QString::fromLatin1(qVersion())
        << "platform=" + application.platformName() << "size=" << window->size();

    int videoFrameCount = 0;
    bool videoTestCompleted = false;
    qint64 reportedVideoPosition = 0;
    if (playbackTest) {
        auto *player = window->findChild<QMediaPlayer *>(QStringLiteral("ibaotvMediaPlayer"));
        if (!player || !player->videoSink() || !player->audioOutput())
            return 1;
        player->audioOutput()->setMuted(true);
        QObject::connect(player->videoSink(), &QVideoSink::videoFrameChanged, &application,
                         [&videoFrameCount](const QVideoFrame &frame) {
            if (frame.isValid())
                ++videoFrameCount;
        });
        QObject::connect(player, &QMediaPlayer::positionChanged, &application,
                         [&, player, window, landscapeVideo, playbackMilliseconds](qint64 position) {
            if (!videoTestCompleted && videoFrameCount > 0 && position >= reportedVideoPosition + 5000) {
                reportedVideoPosition = position;
                qInfo() << "IBAOTV_VIDEO_PROGRESS position=" << position
                        << "frames=" << videoFrameCount << "exposed=" << window->isExposed();
            }
            if (!videoTestCompleted && videoFrameCount > 0 && position >= playbackMilliseconds) {
                videoTestCompleted = true;
                player->pause();
                const bool orientationValid = !landscapeVideo || window->property("playerAngle").toInt() == 90;
                if (!orientationValid) {
                    application.exit(1);
                    return;
                }
                qInfo() << "IBAOTV_VIDEO_OK position=" << position
                        << "frames=" << videoFrameCount
                        << "frame=" << player->videoSink()->videoFrame().size()
                        << "rotation=" << window->property("playerAngle").toInt()
                        << "series=" << window->property("dSid").toString()
                        << "episode=" << window->property("curIdx").toInt() + 1;
                const QString capture = qEnvironmentVariable("IBAOTV_VIDEO_SCREENSHOT");
                if (!capture.isEmpty() && !window->grabWindow().save(capture)) {
                    application.exit(1);
                    return;
                }
                application.exit(0);
            }
        });
        QObject::connect(player, &QMediaPlayer::errorOccurred, &application,
                         [&application](QMediaPlayer::Error, const QString &message) {
            qCritical().noquote() << "IBAOTV_VIDEO_FAIL" << message;
            application.exit(1);
        });
        QTimer::singleShot(30000 + int(playbackMilliseconds), &application, [&application] {
            qCritical() << "IBAOTV_VIDEO_FAIL timeout";
            application.exit(1);
        });
        QTimer::singleShot(0, &application, [&, window, parameter, landscapeVideo, episodeNumber] {
            if (landscapeVideo)
                window->setProperty("playerOrient", 1);
            if (!episodeTest) {
                QMetaObject::invokeMethod(window, "playDirect", Q_ARG(QVariant, parameter));
                return;
            }
            QVariant prepared;
            QMetaObject::invokeMethod(window, "prepareEpisodeTest", Q_RETURN_ARG(QVariant, prepared),
                                      Q_ARG(QVariant, parameter), Q_ARG(QVariant, episodeNumber));
            if (!prepared.toBool()) {
                qCritical() << "IBAOTV_EPISODE_FAIL detail or episode unavailable";
                application.exit(1);
                return;
            }
            QTimer::singleShot(500, &application, [&application, window, episodeNumber] {
                qInfo() << "IBAOTV_EPISODE_CLICK series=" << window->property("dSid").toString()
                        << "episode=" << episodeNumber;
                QVariant clicked;
                QMetaObject::invokeMethod(window, "clickEpisodeTest", Q_RETURN_ARG(QVariant, clicked));
                if (!clicked.toBool()) {
                    qCritical() << "IBAOTV_EPISODE_FAIL episode delegate unavailable";
                    application.exit(1);
                }
            });
        });
    } else if (orientationTest) {
        QTimer::singleShot(0, &application, [&, window] {
            QMetaObject::invokeMethod(window, "testOrientation", Q_ARG(QVariant, 1));
            QTimer::singleShot(300, &application, [&, window] {
                auto *surface = window->findChild<QQuickItem *>(QStringLiteral("ibaotvSurface"));
                auto *videoLayer = window->findChild<QQuickItem *>(QStringLiteral("ibaotvVideoLayer"));
                auto *controls = window->findChild<QQuickItem *>(QStringLiteral("ibaotvControls"));
                const bool landscape = surface && surface->rotation() == 90
                    && surface->width() > surface->height() && videoLayer && controls
                    && videoLayer->parentItem() == surface && controls->parentItem() == surface;
                qInfo() << "IBAOTV_LANDSCAPE" << landscape
                        << (surface ? QSizeF(surface->width(), surface->height()) : QSizeF());
                QMetaObject::invokeMethod(window, "testOrientation", Q_ARG(QVariant, 2));
                QTimer::singleShot(300, &application, [&, surface, landscape] {
                    const bool portrait = surface && surface->rotation() == 0 && surface->width() < surface->height();
                    qInfo() << "IBAOTV_PORTRAIT" << portrait;
                    application.exit(landscape && portrait && !qmlWarnings ? 0 : 1);
                });
            });
        });
    } else if (diagnostic) {
        QTimer::singleShot(0, &application, [&] {
            QVariant result;
            if (smokeTest) {
                QMetaObject::invokeMethod(window, "smokePages", Q_RETURN_ARG(QVariant, result));
                QTimer::singleShot(300, &application, [&application, &qmlWarnings, result] {
                    const bool success = result.toBool() && !qmlWarnings;
                    qInfo() << (success ? "IBAOTV_QML_OK pages=6" : "IBAOTV_QML_FAIL");
                    application.exit(success ? 0 : 1);
                });
            } else if (detailTest) {
                QMetaObject::invokeMethod(window, "openDetail", Q_RETURN_ARG(QVariant, result),
                                          Q_ARG(QVariant, parameter));
                const int count = window->property("episodes").toList().size();
                qInfo() << "IBAOTV_DETAIL episodes=" << count;
                application.exit(result.toBool() && count > 0 ? 0 : 1);
            } else {
                QMetaObject::invokeMethod(window, listTest ? "testList" : "testSearch",
                                          Q_RETURN_ARG(QVariant, result), Q_ARG(QVariant, parameter));
                QTimer::singleShot(300, &application, [&, result] {
                    const int tabIndex = window->property("tabIdx").toInt();
                    QObject *feed = window->findChild<QObject *>(QStringLiteral("ibaotvFeed%1").arg(tabIndex));
                    const int modelCount = feed ? feed->property("count").toInt() : 0;
                    const int count = result.toInt();
                    qInfo() << (listTest ? "IBAOTV_LIST" : "IBAOTV_SEARCH")
                            << "cards=" << count << "model=" << modelCount;
                    application.exit(count > 0 && modelCount == count ? 0 : 1);
                });
            }
        });
    } else if (screenshot) {
        QTimer::singleShot(5000, &application, [&application, window, parameter] {
            const bool saved = window->grabWindow().save(parameter);
            qInfo() << "IBAOTV_SCREENSHOT" << saved << parameter;
            application.exit(saved ? 0 : 1);
        });
    }
    return application.exec();
}
