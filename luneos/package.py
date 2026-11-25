import argparse
from pathlib import Path
import platform
import subprocess
import tarfile
import tempfile


APPLICATION_ID = "org.ibaotv.native"
VERSION = "0.2.2-1"


def root_owner(member):
    member.uid = 0
    member.gid = 0
    member.uname = "root"
    member.gname = "root"
    return member


def main():
    parser = argparse.ArgumentParser(description="Package the LuneOS application as an IPK")
    parser.add_argument("root", type=Path)
    parser.add_argument("output", type=Path)
    arguments = parser.parse_args()
    root = arguments.root.resolve()
    application = root / "usr/palm/applications" / APPLICATION_ID
    if not (application / "bin/ibaotv-native").is_file():
        parser.error("The install tree does not contain ibaotv-native")
    output = arguments.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    architecture = platform.machine()
    installed_size = sum((item.stat().st_size + 1023) // 1024 for item in application.rglob("*") if item.is_file())
    archive = output / ("ibaotv-native-luneos_" + VERSION + "_" + architecture + ".ipk")
    with tempfile.TemporaryDirectory(prefix="ibaotv-ipk-") as temporary:
        directory = Path(temporary)
        (directory / "control").write_text(
            "Package: " + APPLICATION_ID + "\n"
            "Version: " + VERSION + "\n"
            "Architecture: " + architecture + "\n"
            "Installed-Size: " + str(installed_size) + "\n"
            "Maintainer: ibaotv\n"
            "Section: multimedia\n"
            "Priority: optional\n"
            "Description: ibaotv native video player for LuneOS\n"
            " Requires system Qt6 >= 6.4, QtQuick Controls, QtMultimedia, webOS Wayland and PulseAudio.\n",
            encoding="utf-8",
        )
        with tarfile.open(directory / "control.tar.gz", "w:gz", format=tarfile.GNU_FORMAT) as bundle:
            bundle.add(directory / "control", arcname="./control", filter=root_owner)
        with tarfile.open(directory / "data.tar.gz", "w:gz", format=tarfile.GNU_FORMAT) as bundle:
            bundle.add(application, arcname="./usr/palm/applications/" + APPLICATION_ID, filter=root_owner)
        (directory / "debian-binary").write_text("2.0\n", encoding="ascii")
        subprocess.run(
            ["ar", "rc", str(archive), "debian-binary", "control.tar.gz", "data.tar.gz"],
            cwd=directory, check=True,
        )
    print(archive)


if __name__ == "__main__":
    main()
