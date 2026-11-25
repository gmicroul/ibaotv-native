# 小宝影院原生客户端 (SailfishOS)
# 本机构建: rpmbuild -bb packaging/rpm/ibaotv-native.spec
# 需先运行 packaging/rpm/build-rpm.sh 生成源码包
Name:       ibaotv-native
Version:    0.2.2
Release:    1
Summary:    小宝影院原生客户端 (SailfishOS)
License:    MIT
URL:        https://github.com/gmicroul/ibaotv-native
Source0:    %{name}-%{version}.tar.gz

BuildRequires:  pkgconfig(Qt5Core)
BuildRequires:  pkgconfig(Qt5Gui)
BuildRequires:  pkgconfig(Qt5Qml)
BuildRequires:  pkgconfig(Qt5Quick)
BuildRequires:  pkgconfig(Qt5Network)
BuildRequires:  pkgconfig(Qt5Multimedia)
BuildRequires:  pkgconfig(sailfishapp)

Requires:   sailfishsilica-qt5
Requires:   qt5-qtdeclarative-import-qtquick2plugin
Requires:   qt5-qtdeclarative-import-multimedia
Requires:   qt5-qtmultimedia
Requires:   nemo-qtmultimedia-plugins-gstvideotexturebackend
Requires:   gstreamer1.0-plugins-good
Requires:   gstreamer1.0-plugins-bad
Requires:   gstreamer1.0-libav
Requires:   libkeepalive
Requires:   ffmpeg-tools
Requires:   curl

%description
小宝影院（ibaotv.com）原生 Sailfish OS 客户端：分类、搜索、详情选集、
HLS 播放、倍速、断点续播、小窗、下载与观看记录。

%prep
%setup -q

%build
qmake sailfish.pro
make %{?_smp_mflags}

%install
make install INSTALL_ROOT=%{buildroot}

%files
%defattr(-,root,root,-)
%{_bindir}/ibaotv-native
%{_datadir}/applications/ibaotv-native.desktop
%{_datadir}/icons/hicolor/86x86/apps/ibaotv-native.png
%{_datadir}/icons/hicolor/128x128/apps/ibaotv-native.png
%{_datadir}/icons/hicolor/172x172/apps/ibaotv-native.png
%{_datadir}/icons/hicolor/256x256/apps/ibaotv-native.png

%changelog
* Tue Nov 10 2026 ibaotv-native contributors - 0.2.2-1
- 首个 SailfishOS 原生版本：Silica 界面，C++ 直连 ibaotv.com
- 分类/搜索/详情选集/HLS 播放/倍速/断点续播/小窗/下载/记录
