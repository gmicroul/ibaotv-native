#ifndef IBAOTV_LUNEOS_DOWNLOADADAPTER_H
#define IBAOTV_LUNEOS_DOWNLOADADAPTER_H

#include "downloader.h"
#include <QDesktopServices>

class DownloadAdapter : public DownloadManager
{
    Q_OBJECT
public:
    using DownloadManager::DownloadManager;

    Q_INVOKABLE bool openFolder()
    {
        return QDesktopServices::openUrl(QUrl::fromLocalFile(dir()));
    }
};

#endif
