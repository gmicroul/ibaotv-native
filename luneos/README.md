# ibaotv-native for LuneOS

独立的 Qt6/LuneOS 版本，参考 `musicfox-touch/luneos/` 的迁移和安装方式。
原 Ubuntu Touch 与 Sailfish OS 源码、脚本和 RPM 均不改写。

## 构建

需要原生 aarch64 Linux、C++17 编译器、CMake 3.21+、Python 3、GNU tar/ar 和 Qt6 >= 6.4 开发依赖。
Qt 模块：Core、Gui、Qml、Quick、QuickControls2、Network、Multimedia。

本开发机可复用 MusicFox 已提取的 Qt 6.4.2 SDK，无须在设备上安装编译器：

```sh
python3 luneos/fetch-webp.py
IBAOTV_QT6_PREFIX=/home/defaultuser/musicfox-touch/luneos/.sdk/usr bash luneos/build.sh
```

其他环境用 `IBAOTV_QT6_PREFIX` 指定自己的原生 Qt6 开发前缀，默认 `luneos/.sdk/usr`。
`IBAOTV_BUILD_DIR` 与 `IBAOTV_BUILD_JOBS` 可覆盖构建目录和并行数。
二进制位于 `luneos/build/bin/ibaotv-native`，IPK 位于
`luneos/dist/ibaotv-native-luneos_0.2.2-1_aarch64.ipk`。
只打包程序、QML、启动器、图标和应用私有的 WebP 图片插件，不复制开发机 Qt 核心库。
WebP 插件来自 Debian Qt 6.4.2，固定 SHA256 校验并附带上游版权文件。
设备复用现有 `libwebp.so.7`、`libwebpdemux.so.2` 和 `libwebpmux.so.3`，不改全局图片插件目录。
也可用 `IBAOTV_WEBP_PLUGIN` 指定自己为目标架构构建的 Qt6 插件。

## 部署

```sh
bash luneos/deploy.sh root@192.168.2.160
```

可用 `IBAOTV_KNOWN_HOSTS` 指定 SSH 主机密钥文件，默认 `~/.ssh/known_hosts`。
脚本只部署 `org.ibaotv.native`，通过 AppInstallService 订阅等待 `installed`，
再检查 SAM 注册、执行完整 QML 离屏自检，并请求系统启动卡片。
正常入口兼容 SAM 附加的应用参数，部署结束前额外检查实际进程仍在运行。
不重启设备、桌面或音频服务，不改变全局音频路由。
安装器的 aarch64 架构项若缺失，会先备份配置再按系统架构列表补齐。

应用标题为“小宝影院”，安装目录：
`/media/cryptofs/apps/usr/palm/applications/org.ibaotv.native/`。
启动日志：`/tmp/ibaotv-luneos.log`。
正常使用的数据位于运行用户的 `~/.cache/ibaotv-native`、
`~/.config/ibaotv.LuneOS/ibaotv-native.conf` 与 `~/Videos/小宝影院`。

## 真机诊断

```sh
app=/media/cryptofs/apps/usr/palm/applications/org.ibaotv.native
"$app/bin/ibaotv-native" --smoke-test
"$app/bin/ibaotv-native" --test-list 1
"$app/bin/ibaotv-native" --test-search '流浪地球'
"$app/bin/ibaotv-native" --test-detail VOD_ID
"$app/bin/ibaotv-native" --test-image /tmp/poster.webp
"$app/bin/ibaotv-native" --test-orientation
"$app/bin/ibaotv-native" --selftest playurl VOD_ID SOURCE_ID EPISODE_ID
PULSE_SERVER=unix:/run/pulse/native "$app/bin/ibaotv-native" --test-video 'https://example/video.m3u8'
PULSE_SERVER=unix:/run/pulse/native "$app/bin/ibaotv-native" --test-video 'https://example/video.m3u8' --landscape
PULSE_SERVER=unix:/run/pulse/native "$app/bin/ibaotv-native" --test-episode 80221 32 --landscape --seconds 30
IBAOTV_TEST_WAYLAND=1 "$app/ibaotv-native" --test-episode 80221 32 --landscape --seconds 30
```

诊断使用临时 HOME，默认离屏软件渲染，不覆盖用户的历史、设置和下载任务。
列表与搜索同时检查后端返回数量和实际 QML 列表模型数量。
视频自检必须同时收到有效视频帧和指定时长的播放进度，音频静音；`--seconds` 可指定 1～300 秒。
选集自检使用实际详情页 ListView 的剧集点击信号，不走直链捷径；集数按详情列表从 1 开始计数，默认检查 15 秒。
`IBAOTV_TEST_WAYLAND=1` 配合启动器让视频或选集自检使用真实 Wayland/EGL 卡片；结果写入启动日志。
横屏自检检查 2160×1080 逻辑播放区域、视频与控制层共同旋转，以及恢复竖屏。
可用 `IBAOTV_VIDEO_SCREENSHOT=/tmp/player.png` 保存视频自检的截图。
启动器另支持 `--screenshot /tmp/ibaotv.png`，在真实 Wayland 卡片中截图后退出。

## 适配范围

- 复用原 QtQuick Controls 界面及 Sailfish C++ 网站解析、观看历史、设置、HLS 下载后端，不依赖 Node。
- Qt6 变体只生成到构建目录；替换已移除的网络重定向属性、QtMultimedia 导入和缓冲状态枚举。
- `LuneVideo.qml` 用 Qt6 MediaPlayer、AudioOutput、VideoOutput 保留现有播放与选集交互。
- 使用 webOS Wayland 卡片、输入法与 PulseAudio 媒体通道。
- 播放器右上角与设置页提供“自动 / 横屏 / 竖屏”切换并保存偏好；自动模式跟随方向传感器。
- 横屏同时旋转视频、手势和控制层并交换逻辑宽高；退出全屏播放自动恢复竖向目录。
- 详情页选集通过 `Qt.callLater` 延后播放请求，先让点击信号结束，避免横屏重排释放列表项时与同步网络事件循环重入导致 Qt6 主动中止。
- 下载合并需要设备提供 `ffmpeg` 命令；文件夹按钮依赖系统文件管理器的 URL 处理能力。
- 不包含 Sailfish Silica、Cover、Nemo KeepAlive 和锁屏媒体控制；实际声音、输入法和长时间后台播放需人工体验。

## FFmpeg 安装（2026-11-16）

已在 `root@192.168.2.160` 通过 `opkg` 安装独立工具包 `ibaotv-ffmpeg 8.0.3-r0ibaotv1`。
提供 `/usr/bin/ffmpeg` 与 `/usr/bin/ffprobe`，系统卡片的默认 PATH 可以直接找到。
本机安装包：`luneos/dist/ibaotv-ffmpeg_8.0.3-r0ibaotv1_aarch64.ipk`，约 22 MiB。
将该 IPK 上传到设备的 `/tmp` 后，可重新安装和检查：

```sh
opkg install /tmp/ibaotv-ffmpeg_8.0.3-r0ibaotv1_aarch64.ipk
ffmpeg -version
ffprobe -version
opkg verify ibaotv-ffmpeg
```

源码来自 `https://ffmpeg.org/releases/ffmpeg-8.0.3.tar.xz`，已验证官方 PGP 签名，
签名密钥指纹为 `FCF986EA15E6E293A5644F10B4322F04D67658D8`。
源码 SHA256：`6136812ea6d4e68bdba27e33c2a94382711cdf4f8602ffef056ff792bd6f9818`。
源码、签名和构建缓存保存在 `luneos/.sdk/ffmpeg-8.0.3/`，不纳入 Git。

该版本静态链接 FFmpeg 自身的库，运行时只依赖系统 `libc.so.6` 和 `libm.so.6`；
没有替换系统 Qt、GStreamer 或原有 FFmpeg 8.0.1 共享库，安装前后六个 libav/libsw 库的 SHA256 一致。
关闭外部依赖自动探测，不包含外部 TLS、libx264 等库；小宝影院的网络下载仍由 Qt 后端完成。
包管理器只新增 `ibaotv-ffmpeg`，没有升级或删除其他软件包；可用 `opkg remove ibaotv-ffmpeg` 卸载。

真机使用下载管理器相同的 `-c copy -bsf:a aac_adtstoasc` 参数，
把两秒 MPEG-4/AAC 合成 TS 样本封装成 MP4；音视频均保留，完整解码无错误，结果与本机 SHA256 一致。
隔离临时目录内的中文路径导出复制检查通过，未覆盖用户文件，也未重启设备或服务。
这些检查不等同于实际网站下载及界面导出的完整验收。
新下载结束时会自动查找该工具，无须重新编译应用；已完成的 TS 文件不会自动转换。

## 部署验证（2026-11-16）

目标 `root@192.168.2.160`：LuneOS 1.0 / aarch64 / Qt 6.12.0 / GStreamer 1.28.2。

- IPK 由 AppInstallService 安装成功，SAM 返回可见的“小宝影院”启动项，系统启动请求和实际进程检查通过。
- 完整 QML 自检加载目录、详情、下载、历史、设置、播放器六个页面。
- 电影目录返回 10 条，搜索“流浪地球”返回 3 条；实际 QML 列表模型数量分别为 10 / 3。
- “流浪地球”详情与播放地址解析通过；真实 HLS 静音离屏解码收到 1920×756 视频帧与 1.032 秒进度。
- 横屏离屏检查得到 2160×1080 逻辑区域，视频与控制层共同旋转 90°，恢复竖屏通过。
- 系统截图接口取得 1080×2160 真机画面，确认播放器控制层和横屏切换入口显示正常。
- 应用私有 WebP 插件成功解码 270×337 的站点海报，无须修改系统图片插件目录。

截图保存在本机 `luneos/dist/ibaotv-luneos-screen.png`，IPK 和 SDK 缓存不纳入 Git。
初次部署时设备没有 `ffmpeg`；现已安装独立工具并通过同参数封装和临时导出复制检查，见“FFmpeg 安装”。
实际网站下载与界面导出的完整流程仍需用真实任务验收。
自动旋转依赖设备方向传感器；扬声器出声、蓝牙、实际旋转体验和长期后台播放仍需人工验证。

## 选集闪退修复（2026-11-16）

- 问题片源为“走马上任” `80221`，第32集对应 `sid=1 / nid=32`。
- 原版的真实选集信号回归可复现 `SIGABRT`；崩溃栈为列表项析构、`QQmlData::destroyed`、同步 `QEventLoop::exec` 和 `Backend::playUrl`。
- 横屏缩短详情列表的可视区域，列表项在其点击信号尚未结束时被释放；延后调用 `playAt` 后，同一回归不再中止。
- 修复版离屏检查播放15秒、收到376帧；已安装版本 Wayland/EGL 横屏检查播放30秒、收到751帧，视频为1920×1080、旋转90°。
- 诊断前后用户配置字节一致，观看历史与设置未被覆盖；已安装二进制与本机打包产物的 SHA256 一致。
