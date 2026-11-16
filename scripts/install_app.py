#!/usr/bin/env python3
"""Stage, verify, replace, and launch a local DavidAltTab build."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import time


def install(source: Path, install_dir: Path) -> Path:
    if not (source / "Contents/MacOS/DavidAltTab").is_file():
        raise ValueError(f"DavidAltTab build not found at {source}")
    install_dir.mkdir(parents=True, exist_ok=True)
    destination = install_dir / "DavidAltTab.app"
    # Stage on the destination volume so the final rename is atomic.
    with tempfile.TemporaryDirectory(prefix=".DavidAltTab-install-", dir=install_dir) as staging:
        staged_app = Path(staging) / "DavidAltTab.app"
        backup = Path(staging) / "previous.app"
        subprocess.run(["ditto", str(source), str(staged_app)], check=True)
        subprocess.run(["codesign", "--verify", "--deep", str(staged_app)], check=True)
        stopped = subprocess.run(["pkill", "-x", "-u", str(os.getuid()), "DavidAltTab"])
        if stopped.returncode not in (0, 1):
            raise RuntimeError("Could not stop DavidAltTab. Quit it and retry make install.")
        for _ in range(50):
            running = subprocess.run(["pgrep", "-x", "-u", str(os.getuid()), "DavidAltTab"],
                                     stdout=subprocess.DEVNULL)
            if running.returncode == 1:
                break
            if running.returncode != 0:
                raise RuntimeError("Could not check whether DavidAltTab is running.")
            time.sleep(0.1)
        else:
            raise RuntimeError("DavidAltTab is still running. Quit it and retry make install.")
        if destination.exists():
            # Clear grants for the old build before its ad-hoc identity changes.
            # macOS will ask the user to authorize the replacement app.
            for service in ("Accessibility", "ScreenCapture"):
                subprocess.run(["tccutil", "reset", service, "com.davidantaki.DavidAltTab"], check=True)
            destination.rename(backup)
        try:
            staged_app.rename(destination)
        except OSError:
            if backup.exists():
                backup.rename(destination)
            raise
    return destination


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("install_dir", type=Path)
    args = parser.parse_args()
    try:
        destination = install(args.source.resolve(), args.install_dir.resolve())
        print(f"Installed {destination}", flush=True)
        print("Grant Accessibility and Screen Recording access when macOS asks.", flush=True)
        subprocess.run(["open", str(destination)], check=True)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Install failed: {error}\n")


if __name__ == "__main__":
    main()
