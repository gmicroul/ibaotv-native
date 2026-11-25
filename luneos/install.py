import argparse
import ctypes
import io
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile


APPLICATION_ID = "org.ibaotv.native"
SYSTEM_PACKAGES = {
    "qtbase", "qtbase-plugins", "qtdeclarative", "qtdeclarative-qmlplugins",
    "qtmultimedia", "qtmultimedia-plugins", "qtmultimedia-qmlplugins",
    "qtsensors", "qtsensors-qmlplugins",
    "qtwayland-plugins", "qtwayland-webos", "pulseaudio-misc",
}


def prepare(package, configuration=Path("/etc/palm/appinstalld/opkg.conf")):
    control_bytes = subprocess.check_output(["ar", "p", str(package), "control.tar.gz"])
    with tarfile.open(fileobj=io.BytesIO(control_bytes), mode="r:gz") as control:
        metadata = dict(line.split(": ", 1) for line in control.extractfile("./control").read().decode().splitlines()
                        if ": " in line and not line.startswith(" "))
    architecture = metadata.get("Architecture")
    if metadata.get("Package") != APPLICATION_ID or architecture != platform.machine():
        raise RuntimeError("This IPK must be " + APPLICATION_ID + " for " + platform.machine())
    installed = dict(line.split(" - ", 1) for line in subprocess.check_output(["opkg", "list-installed"], text=True).splitlines()
                     if " - " in line)
    missing = SYSTEM_PACKAGES - installed.keys()
    if missing:
        raise RuntimeError("Required LuneOS system packages are missing: " + ", ".join(sorted(missing)))
    qt_version = tuple(int(part) for part in installed["qtbase"].split(".")[:2])
    if qt_version < (6, 4):
        raise RuntimeError("LuneOS Qt6 >= 6.4 is required")
    for library in ("libwebp.so.7", "libwebpdemux.so.2", "libwebpmux.so.3"):
        ctypes.CDLL(library)
    installer_architectures = subprocess.check_output(
        ["opkg", "-f", str(configuration), "print-architecture"], text=True,
    )
    if any(line.split()[1:2] == [architecture] for line in installer_architectures.splitlines()):
        return
    system_architectures = subprocess.check_output(["opkg", "print-architecture"], text=True)
    entry = next((line for line in system_architectures.splitlines() if line.split()[1:2] == [architecture]), None)
    if entry is None:
        raise RuntimeError("The system package manager does not support " + architecture)
    backup = configuration.with_name(configuration.name + ".ibaotv-backup")
    if not backup.exists():
        shutil.copy2(configuration, backup)
    with configuration.open("a", encoding="utf-8") as output:
        output.write("\n" + entry + "\n")
    print("Added installer architecture:", entry, "(backup:", str(backup) + ")", flush=True)


def install(package, timeout=90000):
    request = {"id": APPLICATION_ID, "ipkUrl": str(package.resolve()), "subscribe": True}
    process = subprocess.Popen(
        ["luna-send", "-i", "-w", str(timeout), "luna://com.webos.appInstallService/install", json.dumps(request)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
    )
    previous_state = None
    try:
        for line in process.stdout:
            response = json.loads(line)
            if response.get("returnValue") is False:
                raise RuntimeError(response.get("errorText", "The install service rejected the request"))
            if response.get("id") != APPLICATION_ID:
                continue
            details = response.get("details", {})
            state = details.get("state")
            if state != previous_state:
                print("ibaotv install:", state, flush=True)
                previous_state = state
            if state == "installed":
                return
            if state == "install failed":
                raise RuntimeError(details.get("reason", "ibaotv installation failed"))
        raise RuntimeError("The install service exited or timed out without confirming installation")
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        process.stdout.close()


def main():
    parser = argparse.ArgumentParser(description="Install ibaotv through LuneOS AppInstallService")
    parser.add_argument("package", type=Path)
    parser.add_argument("--timeout", type=int, default=90000, help="Installation timeout in milliseconds")
    arguments = parser.parse_args()
    if not arguments.package.is_file() or arguments.timeout <= 0:
        parser.error("An existing IPK and a positive timeout are required")
    try:
        prepare(arguments.package)
        install(arguments.package, arguments.timeout)
    except (OSError, ValueError, RuntimeError, tarfile.TarError, subprocess.SubprocessError) as error:
        print("ibaotv installation failed:", error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
