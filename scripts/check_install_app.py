#!/usr/bin/env python3
"""Check app replacement and recovery using disposable app bundles."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import install_app


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        self.source = self.root / "build/DavidAltTab.app"
        executable = self.source / "Contents/MacOS/DavidAltTab"
        executable.parent.mkdir(parents=True)
        executable.write_text("new build")
        self.install_dir = self.root / "Applications"
        self.installed = self.install_dir / "DavidAltTab.app"
        self.commands = []

    def run_command(self, command, **kwargs):
        self.commands.append(command)
        if command[0] == "ditto":
            shutil.copytree(command[1], command[2])
        return subprocess.CompletedProcess(command, 1 if command[0] in ("pgrep", "pkill") else 0)

    def test_repeat_install_removes_obsolete_files(self):
        with patch.object(install_app.subprocess, "run", side_effect=self.run_command):
            install_app.install(self.source, self.install_dir)
            (self.installed / "obsolete").write_text("old resource")
            install_app.install(self.source, self.install_dir)
        self.assertEqual((self.installed / "Contents/MacOS/DavidAltTab").read_text(), "new build")
        self.assertFalse((self.installed / "obsolete").exists())
        self.assertEqual(list(self.install_dir.iterdir()), [self.installed])

    def test_verification_failure_leaves_existing_app_running_and_intact(self):
        self.installed.mkdir(parents=True)
        (self.installed / "original").write_text("old build")

        def fail_verification(command, **kwargs):
            if command[0] == "codesign":
                raise subprocess.CalledProcessError(1, command)
            return self.run_command(command, **kwargs)

        with patch.object(install_app.subprocess, "run", side_effect=fail_verification):
            with self.assertRaises(subprocess.CalledProcessError):
                install_app.install(self.source, self.install_dir)
        self.assertEqual((self.installed / "original").read_text(), "old build")
        self.assertFalse(any(command[0] == "pkill" for command in self.commands))

    def test_failed_replacement_restores_previous_app(self):
        self.installed.mkdir(parents=True)
        (self.installed / "original").write_text("old build")
        rename = Path.rename

        def fail_replacement(path, target):
            if path.name == "DavidAltTab.app" and path.parent.name.startswith(".DavidAltTab-install-"):
                raise OSError("simulated replacement failure")
            return rename(path, target)

        with patch.object(install_app.subprocess, "run", side_effect=self.run_command):
            with patch.object(Path, "rename", fail_replacement):
                with self.assertRaises(OSError):
                    install_app.install(self.source, self.install_dir)
        self.assertEqual((self.installed / "original").read_text(), "old build")

    def test_permissions_reset_after_exit_and_before_replacement(self):
        self.installed.mkdir(parents=True)
        (self.installed / "original").write_text("old build")

        def check_reset(command, **kwargs):
            if command[0] == "tccutil":
                self.assertEqual(self.commands[-1][0], "pgrep" if command[2] == "Accessibility" else "tccutil")
                self.assertEqual((self.installed / "original").read_text(), "old build")
            return self.run_command(command, **kwargs)

        with patch.object(install_app.subprocess, "run", side_effect=check_reset):
            install_app.install(self.source, self.install_dir)
        self.assertEqual([command for command in self.commands if command[0] == "tccutil"], [
            ["tccutil", "reset", "Accessibility", "com.davidantaki.DavidAltTab"],
            ["tccutil", "reset", "ScreenCapture", "com.davidantaki.DavidAltTab"],
        ])

    def test_permission_reset_failure_aborts_before_replacement(self):
        self.installed.mkdir(parents=True)
        (self.installed / "original").write_text("old build")

        def fail_reset(command, **kwargs):
            if command[0] == "tccutil":
                raise subprocess.CalledProcessError(1, command)
            return self.run_command(command, **kwargs)

        with patch.object(install_app.subprocess, "run", side_effect=fail_reset):
            with self.assertRaises(subprocess.CalledProcessError):
                install_app.install(self.source, self.install_dir)
        self.assertEqual((self.installed / "original").read_text(), "old build")


if __name__ == "__main__":
    unittest.main()
