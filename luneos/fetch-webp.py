import hashlib
import io
from pathlib import Path
import platform
import subprocess
import tarfile
import urllib.request


def main():
    if platform.machine() != "aarch64":
        raise RuntimeError("The pinned WebP plugin is for native aarch64 builds")
    directory = Path(__file__).resolve().parent / ".sdk"
    cache = directory / "packages"
    cache.mkdir(parents=True, exist_ok=True)
    name = "qt6-image-formats-plugins_6.4.2-1_arm64.deb"
    archive = cache / name
    if not archive.exists():
        url = "https://deb.debian.org/debian/pool/main/q/qt6-imageformats/" + name
        with urllib.request.urlopen(url, timeout=60) as response:
            content = response.read()
        archive.write_bytes(content)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != "5e2808af469c46b837aeff3d8abb3b8f34d4111dfa6a947941e92e2ee1b330c8":
        raise RuntimeError("SHA256 mismatch: " + str(archive))
    data = subprocess.check_output(["ar", "p", str(archive), "data.tar.xz"])
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:xz") as bundle:
        files = {
            "./usr/lib/aarch64-linux-gnu/qt6/plugins/imageformats/libqwebp.so":
                directory / "plugins/imageformats/libqwebp.so",
            "./usr/share/doc/qt6-image-formats-plugins/copyright":
                directory / "licenses/qt6-imageformats-copyright",
        }
        for member, destination in files.items():
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(bundle.extractfile(member).read())
            print(destination)


if __name__ == "__main__":
    main()
