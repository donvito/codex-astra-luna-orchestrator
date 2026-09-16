"""Reject unsafe release archives before extracting or running their contents."""

import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]


def native_shell():
    if os.name == "nt":
        candidate = Path(r"C:\Program Files\Git\bin\sh.exe")
        return str(candidate) if candidate.exists() else None
    return shutil.which("sh")


def powershell_hosts():
    candidates = [shutil.which("pwsh"), shutil.which("powershell")]
    if os.name == "nt":
        candidates.append(r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe")
    return list(dict.fromkeys(str(Path(path).resolve()) for path in candidates if path and Path(path).is_file()))


def ps_literal(value):
    return "'" + str(value).replace("'", "''") + "'"


class ReleaseArchiveValidationTests(unittest.TestCase):
    def make_tar(self, directory, extra=None, *, include_instructions=True):
        path = directory / "release.tar.gz"
        with tarfile.open(path, "w:gz", format=tarfile.USTAR_FORMAT) as archive:
            for name in ("release/", "release/profiles/"):
                entry = tarfile.TarInfo(name)
                entry.type = tarfile.DIRTYPE
                entry.mode = 0o755
                archive.addfile(entry)
            files = [("release/setup.sh", b"exit 0\n")]
            if include_instructions:
                files.append(("release/AGENTS.md", b"Fixture instructions\n"))
            for name, content in files:
                entry = tarfile.TarInfo(name)
                entry.mode = 0o644
                entry.size = len(content)
                archive.addfile(entry, io.BytesIO(content))
            if extra:
                name, kind, target = extra
                entry = tarfile.TarInfo(name)
                entry.type = kind
                entry.linkname = target
                archive.addfile(entry)
        return path

    def validate_tar(self, directory, archive):
        shell = native_shell()
        if not shell:
            self.skipTest("POSIX shell unavailable")
        runner = directory / "validate.sh"
        runner.write_text(
            '#!/bin/sh\nset -eu\n'
            'if command -v cygpath >/dev/null 2>&1; then\n'
            '  set -- "$(cygpath -u "$1")" "$(cygpath -u "$2")" "$(cygpath -u "$3")"\n'
            'fi\n. "$1/scripts/release-update.sh"\n'
            'release_update_listing="$2/names.txt"\n'
            'release_update_types="$2/types.txt"\n'
            'release_update_payload="$2/extract"\n'
            'mkdir "$release_update_payload"\n'
            'release_update_validate_archive "$3"\n',
            encoding="utf-8", newline="\n",
        )
        # Forward slashes are accepted by Git sh and native POSIX shells.
        return subprocess.run(
            [shell, runner.as_posix(), ROOT.as_posix(), directory.as_posix(), archive.as_posix()],
            capture_output=True, timeout=30,
        )

    def test_tar_accepts_normal_github_source_layout(self):
        with tempfile.TemporaryDirectory(prefix="release-tar-valid-") as temporary:
            directory = Path(temporary)
            result = self.validate_tar(directory, self.make_tar(directory))
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
            self.assertTrue((directory / "extract/release/setup.sh").is_file())

    def test_tar_rejects_unsafe_entries_before_extraction(self):
        cases = [
            ("release/../../escape", tarfile.REGTYPE, ""),
            ("/absolute/escape", tarfile.REGTYPE, ""),
            ("release/profiles/link", tarfile.SYMTYPE, "../../outside"),
            ("release/profiles/link", tarfile.LNKTYPE, "../../outside"),
            ("release/profiles/pipe", tarfile.FIFOTYPE, ""),
            ("second-root/file", tarfile.REGTYPE, ""),
        ]
        for extra in cases:
            with self.subTest(entry=extra), tempfile.TemporaryDirectory(prefix="release-tar-invalid-") as temporary:
                directory = Path(temporary)
                result = self.validate_tar(directory, self.make_tar(directory, extra))
                self.assertNotEqual(result.returncode, 0, result.stdout.decode(errors="replace"))
                self.assertEqual(list((directory / "extract").iterdir()), [])

    def test_tar_rejects_incomplete_release(self):
        with tempfile.TemporaryDirectory(prefix="release-tar-incomplete-") as temporary:
            directory = Path(temporary)
            result = self.validate_tar(directory, self.make_tar(directory, include_instructions=False))
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list((directory / "extract").iterdir()), [])

    def make_zip(self, directory, extra=None, *, include_instructions=True, include_profiles=True, include_setup=True):
        path = directory / "release.zip"
        with zipfile.ZipFile(path, "w") as archive:
            for name in (("release/", "release/profiles/") if include_profiles else ("release/",)):
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = (0o40755 << 16) | 0x10
                archive.writestr(entry, b"")
            files = [("release/setup.ps1", b"exit 0\n")] if include_setup else []
            if include_instructions:
                files.append(("release/AGENTS.md", b"Fixture instructions\n"))
            for name, content in files:
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = 0o100644 << 16
                archive.writestr(entry, content)
            if extra:
                name, mode, content = extra
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = mode << 16
                archive.writestr(entry, content)
        return path

    def validate_zip(self, host, directory, archive):
        runner = directory / "validate.ps1"
        runner.write_text(
            "$ErrorActionPreference = 'Stop'\n"
            f". {ps_literal(ROOT / 'update.ps1')}\n"
            "try {\n"
            f"  $null = Expand-AndValidateReleaseArchive -ArchivePath {ps_literal(archive)} "
            f"-ExtractionDirectory {ps_literal(directory / 'extract')}\n"
            "  exit 0\n"
            "} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }\n",
            encoding="utf-8",
        )
        return subprocess.run(
            [host, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(runner)],
            capture_output=True, timeout=30,
        )

    def test_zip_accepts_unix_attributes_in_both_powershell_hosts(self):
        hosts = powershell_hosts()
        if not hosts:
            self.skipTest("PowerShell unavailable")
        for host in hosts:
            with self.subTest(host=host), tempfile.TemporaryDirectory(prefix="release-zip-valid-") as temporary:
                directory = Path(temporary)
                result = self.validate_zip(host, directory, self.make_zip(directory))
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                self.assertTrue((directory / "extract/release/setup.ps1").is_file())

    def test_zip_rejects_unsafe_entries_before_extraction(self):
        hosts = powershell_hosts()
        if not hosts:
            self.skipTest("PowerShell unavailable")
        cases = [
            ("release/../../escape", 0o100644, b""),
            ("/absolute/escape", 0o100644, b""),
            ("release\\..\\..\\escape", 0o100644, b""),
            ("release/profiles/link", 0o120777, b"../../outside"),
            ("release/profiles/pipe", 0o010644, b""),
            ("release/agents.md", 0o100644, b"duplicate case-insensitive path"),
            ("release/profiles/evil:stream", 0o100644, b""),
            ("release/profiles/trailing. ", 0o100644, b""),
            ("second-root/file", 0o100644, b""),
        ]
        for host in hosts:
            for extra in cases:
                with self.subTest(host=host, entry=extra), tempfile.TemporaryDirectory(prefix="release-zip-invalid-") as temporary:
                    directory = Path(temporary)
                    result = self.validate_zip(host, directory, self.make_zip(directory, extra))
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(list((directory / "extract").iterdir()), [])

    def test_zip_rejects_missing_required_release_content(self):
        hosts = powershell_hosts()
        if not hosts:
            self.skipTest("PowerShell unavailable")
        for host in hosts:
            for missing in ("include_instructions", "include_profiles", "include_setup"):
                with self.subTest(host=host, missing=missing), tempfile.TemporaryDirectory(prefix="release-zip-incomplete-") as temporary:
                    directory = Path(temporary)
                    archive = self.make_zip(directory, **{missing: False})
                    result = self.validate_zip(host, directory, archive)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(list((directory / "extract").iterdir()), [])


if __name__ == "__main__":
    unittest.main()
