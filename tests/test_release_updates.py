"""Integration coverage for the native release-aware installers.

The tests deliberately exercise the scripts as users do.  Release checks use a
small fake ``curl`` placed first on ``PATH``; no test contacts GitHub.  The
PowerShell tests cover the local/offline path on machines that provide a
PowerShell executable.  The shell release-download tests are skipped when a
POSIX shell is unavailable (the repository supports Windows installations
without Git for Windows).
"""

from __future__ import annotations

import hashlib
import io
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
import tempfile
import textwrap
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SHELL_CANDIDATES = (
    "sh",
    "bash",
    r"C:\Program Files\Git\bin\sh.exe",
    r"C:\Program Files\Git\usr\bin\sh.exe",
)
POWERSHELL_CANDIDATES = ("pwsh", "powershell")


def _working_executable(candidates: tuple[str, ...], probe: list[str]) -> str | None:
    """Return the first executable that can run a harmless probe."""

    seen: set[str] = set()
    for candidate in candidates:
        executable = shutil.which(candidate) or candidate
        if executable in seen or not Path(executable).exists() and not shutil.which(candidate):
            continue
        seen.add(executable)
        try:
            result = subprocess.run(
                [executable, *probe],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        if result.returncode == 0:
            return executable
    return None


def find_shell() -> str | None:
    # ``C:\Windows\System32\bash.exe`` is the WSL launcher, rather than a
    # POSIX shell executable.  It cannot receive the temporary test PATH and
    # environment directly from a Windows subprocess.  Run the shell suite
    # inside WSL instead (the same test file is used there by CI).
    override = os.environ.get("ORCHESTRATOR_TEST_SH")
    if override:
        return _working_executable((override,), ["-c", "exit 0"])
    for candidate in SHELL_CANDIDATES:
        executable = shutil.which(candidate) or candidate
        normalized = executable.replace("/", "\\").lower()
        if normalized.endswith("\\windows\\system32\\bash.exe"):
            continue
        found = _working_executable((candidate,), ["-c", "exit 0"])
        if found:
            return found
    return None


def find_powershell() -> str | None:
    override = os.environ.get("ORCHESTRATOR_TEST_POWERSHELL")
    if override:
        return _working_executable(
            (override,),
            ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "exit 0"],
        )
    return _working_executable(
        POWERSHELL_CANDIDATES,
        ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "exit 0"],
    )


def snapshot_tree(root: Path) -> dict[str, str]:
    """Hash a source tree while ignoring VCS and Python cache artifacts."""

    snapshot: dict[str, str] = {}
    for path in root.rglob("*"):
        if any(part in {".git", "__pycache__"} for part in path.parts):
            continue
        if path.is_file():
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            snapshot[path.relative_to(root).as_posix()] = digest
    return snapshot


class Runner:
    """A native installer command plus the options it accepts."""

    def __init__(self, name: str, executable: str, script_name: str):
        self.name = name
        self.executable = executable
        self.script_name = script_name

    @property
    def is_shell(self) -> bool:
        return self.script_name.endswith(".sh")

    def command(self, source: Path, script_name: str | None = None, *args: str) -> list[str]:
        script = source / (script_name or self.script_name)
        if self.is_shell:
            return [self.executable, str(script), *args]
        return [
            self.executable,
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(script),
            *args,
        ]

    def setup_command(self, source: Path, *args: str) -> list[str]:
        return self.command(source, None, *args)

    def updater_command(self, source: Path, *args: str) -> list[str]:
        return self.command(source, "update.sh" if self.is_shell else "update.ps1", *args)

    def __repr__(self) -> str:
        return self.name


def available_runners() -> list[Runner]:
    runners: list[Runner] = []
    shell = find_shell()
    if shell:
        runners.append(Runner("shell", shell, "setup.sh"))
    powershell = find_powershell()
    if powershell:
        runners.append(Runner("powershell", powershell, "setup.ps1"))
    return runners


def run_process(
    command: list[str],
    *,
    cwd: Path,
    input_text: str = "",
    env: dict[str, str] | None = None,
    timeout: int = 45,
) -> subprocess.CompletedProcess[str]:
    process_env = os.environ.copy()
    if env:
        process_env.update(env)
    process = subprocess.run(
        command,
        cwd=cwd,
        # Passing text=True on Windows lets the CRT translate LF to CRLF.
        # Git sh then leaves the carriage return in answers, so its ``y`` /
        # ``n`` prompts never match.  Bytes keep stdin identical on both OSes.
        input=input_text.encode("utf-8"),
        text=False,
        capture_output=True,
        env=process_env,
        timeout=timeout,
        check=False,
    )
    return subprocess.CompletedProcess(
        process.args,
        process.returncode,
        process.stdout.decode("utf-8", errors="replace"),
        process.stderr.decode("utf-8", errors="replace"),
    )


def setup_input(target: Path, profile: str = "pro", components: tuple[str, str, str] = ("", "", "")) -> str:
    """Build answers for target, profile, and the three component prompts."""

    return target.name + "\n" + profile + "\n" + "".join(answer + "\n" for answer in components)


class FakeCurl:
    """A deterministic curl replacement for release API/archive tests."""

    def __init__(
        self,
        directory: Path,
        archive: Path | None = None,
        tag: str = "v9.9.9",
        fail: bool = False,
        archive_fail: bool = False,
    ):
        self.directory = directory
        self.archive = archive
        self.tag = tag
        self.fail = fail
        self.archive_fail = archive_fail
        self.bin = directory / "curl"
        self.log = directory / "curl.log"
        directory.mkdir(parents=True, exist_ok=True)
        self._write()

    def _write(self) -> None:
        # The script intentionally accepts the curl forms used by both common
        # shell implementations: ``-o path`` and stdout output.
        script = textwrap.dedent(
            r'''
            #!/bin/sh
            set -eu
            : "${MOCK_CURL_LOG:?}"
            printf '%s\n' "$*" >> "$MOCK_CURL_LOG"
            if [ "${MOCK_CURL_FAIL:-0}" = 1 ]; then
                exit 22
            fi

            url=
            output=
            previous=
            writeout=no
            for argument in "$@"; do
                case "$previous" in
                    -o|--output) output=$argument ;;
                    -w|--write-out) writeout=yes ;;
                esac
                case "$argument" in
                    --output=*) output=${argument#--output=} ;;
                esac
                previous=$argument
                case "$argument" in
                    http://*|https://*) url=$argument ;;
                esac
            done

            if printf '%s' "$url" | grep -q '/releases/latest'; then
                effective_url=$(printf 'https://github.com/donvito/codex-astra-luna-orchestrator/releases/tag/%s' "$MOCK_CURL_TAG")
                if [ "$writeout" = yes ]; then
                    printf '%s' "$effective_url"
                elif [ -n "$output" ]; then
                    printf '{"tag_name":"%s","html_url":"%s"}\n' "$MOCK_CURL_TAG" "$effective_url" > "$output"
                else
                    printf '{"tag_name":"%s","html_url":"%s"}\n' "$MOCK_CURL_TAG" "$effective_url"
                fi
                exit 0
            fi

            if [ -z "${MOCK_CURL_ARCHIVE:-}" ]; then
                exit 23
            fi
            if [ "${MOCK_CURL_ARCHIVE_FAIL:-0}" = 1 ]; then
                exit 22
            fi
            if [ -n "$output" ]; then
                cp "$MOCK_CURL_ARCHIVE" "$output"
            else
                cat "$MOCK_CURL_ARCHIVE"
            fi
            ''')
        self.bin.write_text(script, encoding="utf-8", newline="\n")
        self.bin.chmod(self.bin.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    def environment(
        self,
        *,
        fail: bool | None = None,
        archive_fail: bool | None = None,
        tag: str | None = None,
    ) -> dict[str, str]:
        path = os.environ.get("PATH", "")
        return {
            "PATH": str(self.directory) + os.pathsep + path,
            "MOCK_CURL_LOG": str(self.log),
            "MOCK_CURL_TAG": tag or self.tag,
            "MOCK_CURL_FAIL": "1" if (self.fail if fail is None else fail) else "0",
            "MOCK_CURL_ARCHIVE_FAIL": "1"
            if (self.archive_fail if archive_fail is None else archive_fail)
            else "0",
            **({"MOCK_CURL_ARCHIVE": str(self.archive)} if self.archive else {}),
        }


def create_release_archive(directory: Path, *, failing: bool = False) -> Path:
    """Create a tiny tarball containing an installer that records invocation."""

    root = "codex-astra-luna-orchestrator-v9.9.9"
    status = "17" if failing else "0"
    installer = textwrap.dedent(
        f"""\
        #!/bin/sh
        set -eu
        [ "${{CODEX_ORCHESTRATOR_SKIP_UPDATE_CHECK:-}}" = 1 ] || exit 19
        : "${{MOCK_INSTALL_LOG:?}}"
        printf 'run\\n' >> "$MOCK_INSTALL_LOG"
        count=$(wc -l < "$MOCK_INSTALL_LOG")
        printf '%s' "$count" > "${{MOCK_INSTALL_COUNT_FILE:?}}"
        exit {status}
        """
    )
    archive_path = directory / ("release-failure.tar.gz" if failing else "release-success.tar.gz")
    with tarfile.open(archive_path, "w:gz") as archive:
        data = installer.encode("utf-8")
        info = tarfile.TarInfo(f"{root}/setup.sh")
        info.size = len(data)
        info.mode = 0o755
        archive.addfile(info, io.BytesIO(data))
        profiles = tarfile.TarInfo(f"{root}/profiles")
        profiles.type = tarfile.DIRTYPE
        profiles.mode = 0o755
        archive.addfile(profiles)
        agents = tarfile.TarInfo(f"{root}/AGENTS.md")
        agents_data = b"# release fixture\n"
        agents.size = len(agents_data)
        archive.addfile(agents, io.BytesIO(agents_data))
    return archive_path


def create_powershell_release_archive(directory: Path, *, failing: bool = False) -> Path:
    """Create the equivalent minimal ZIP release used by update.ps1."""

    root = "codex-astra-luna-orchestrator-v9.9.9"
    status = "17" if failing else "0"
    installer = textwrap.dedent(
        f"""
        param()
        if ($env:CODEX_ORCHESTRATOR_SKIP_UPDATE_CHECK -ne '1') {{ exit 19 }}
        Add-Content -LiteralPath $env:MOCK_INSTALL_LOG -Value 'run'
        exit {status}
        """
    ).lstrip()
    archive_path = directory / ("release-failure.zip" if failing else "release-success.zip")
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(f"{root}/", "")
        archive.writestr(f"{root}/profiles/", "")
        archive.writestr(f"{root}/setup.ps1", installer)
        archive.writestr(f"{root}/AGENTS.md", "# release fixture\n")
    return archive_path


def powershell_quote(value: Path | str) -> str:
    """Quote a path for a single-quoted PowerShell string literal."""

    return "'" + str(value).replace("'", "''") + "'"


def create_powershell_harness(
    directory: Path,
    *,
    updater: Path,
    source: Path,
    check: bool,
) -> Path:
    """Dot-source update.ps1 and replace only its network primitives.

    Dot-sourcing keeps the production functions (SemVer handling, staging,
    archive validation, cleanup, and relaunch) under test.  The two mocked
    commands are sibling functions, so no real network request can occur.
    """

    check_literal = "$true" if check else "$false"
    harness = textwrap.dedent(
        f"""
        $ErrorActionPreference = 'Stop'
        . {powershell_quote(updater)}

        function Invoke-RestMethod {{
            param(
                [string]$Uri,
                [hashtable]$Headers,
                [int]$TimeoutSec
            )
            return [pscustomobject]@{{
                tag_name = $env:MOCK_PS_TAG
                draft = $false
                prerelease = $false
            }}
        }}

        function Invoke-WebRequest {{
            param(
                [string]$Uri,
                [string]$OutFile,
                [switch]$UseBasicParsing,
                [int]$TimeoutSec
            )
            if ($null -ne $env:MOCK_PS_DOWNLOAD_LOG) {{
                Add-Content -LiteralPath $env:MOCK_PS_DOWNLOAD_LOG -Value $Uri
            }}
            if ($env:MOCK_PS_DOWNLOAD_FAIL -eq '1') {{
                throw 'mock archive download failed'
            }}
            Copy-Item -LiteralPath $env:MOCK_PS_ARCHIVE -Destination $OutFile -Force
        }}

        $exitCode = Invoke-Updater -SourceDirectory {powershell_quote(source)} -Check:{check_literal} -Help:$false
        exit ([int]$exitCode)
        """
    ).lstrip()
    path = directory / "powershell-updater-harness.ps1"
    path.write_text(harness, encoding="utf-8", newline="\n")
    return path


def create_powershell_setup_harness(
    directory: Path,
    *,
    setup: Path,
    source: Path,
    api_failure: bool = False,
) -> Path:
    """Dot-source setup.ps1 with deterministic network primitives."""

    if api_failure:
        network_functions = """
        function Invoke-RestMethod {
            param([string]$Uri, [hashtable]$Headers, [int]$TimeoutSec)
            throw 'mock release API failure'
        }
        """
    else:
        network_functions = """
        function Invoke-RestMethod {
            param([string]$Uri, [hashtable]$Headers, [int]$TimeoutSec)
            return [pscustomobject]@{
                tag_name = $env:MOCK_PS_TAG
                draft = $false
                prerelease = $false
            }
        }

        function Invoke-WebRequest {
            param(
                [string]$Uri,
                [string]$OutFile,
                [switch]$UseBasicParsing,
                [int]$TimeoutSec
            )
            Copy-Item -LiteralPath $env:MOCK_PS_ARCHIVE -Destination $OutFile -Force
        }
        """
    harness = textwrap.dedent(
        f"""
        $ErrorActionPreference = 'Stop'
        $global:LASTEXITCODE = 0
        {network_functions}
        . {powershell_quote(setup)}
        $exitCode = if ($null -eq $global:LASTEXITCODE) {{ 0 }} else {{ [int]$global:LASTEXITCODE }}
        exit $exitCode
        """
    ).lstrip()
    path = directory / "powershell-setup-harness.ps1"
    path.write_text(harness, encoding="utf-8", newline="\n")
    return path


class ReleaseUpdateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.runners = available_runners()
        if not cls.runners:
            raise unittest.SkipTest("neither a POSIX shell nor PowerShell is available")

    def runners_for(self, *, shell_only: bool = False, network: bool = False) -> list[Runner]:
        if network and os.name == "nt":
            self.skipTest("network-mocked POSIX updater tests run in the Linux/WSL test job")
        runners = [runner for runner in self.runners if not shell_only or runner.is_shell]
        if shell_only and not runners:
            self.skipTest("Git sh/bash is required for this release archive test")
        return runners

    def run_setup(
        self,
        runner: Runner,
        source: Path,
        worktree: Path,
        target: Path,
        *,
        profile: str = "pro",
        components: tuple[str, str, str] = ("", "", ""),
        input_suffix: str = "",
        input_text: str | None = None,
        offline: bool = True,
        env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        args = ("--offline",) if offline and runner.is_shell else ("-Offline",) if offline else ()
        return run_process(
            runner.setup_command(source, *args),
            cwd=worktree,
            input_text=(
                setup_input(target, profile, components) + input_suffix
                if input_text is None
                else input_text
            ),
            env=env,
        )

    def run_check(
        self,
        runner: Runner,
        source: Path,
        worktree: Path,
        *,
        tag: str,
        fake_curl: FakeCurl,
        source_version: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        if source_version is not None:
            (source / "VERSION").write_text(source_version + "\n", encoding="utf-8")
        args = ("--check",) if runner.is_shell else ("-Check",)
        return run_process(
            runner.updater_command(source, *args),
            cwd=worktree,
            env=fake_curl.environment(tag=tag),
        )

    def powershell_runner(self) -> Runner:
        runners = [runner for runner in self.runners if not runner.is_shell]
        if not runners:
            self.skipTest("PowerShell is required for this mocked updater test")
        return runners[0]

    def run_powershell_mock(
        self,
        *,
        source: Path,
        worktree: Path,
        check: bool,
        tag: str,
        archive: Path | None = None,
        answer: str = "",
        download_fail: bool = False,
    ) -> tuple[subprocess.CompletedProcess[str], Path, Path, Path]:
        runner = self.powershell_runner()
        stage_parent = worktree / "powershell-temp"
        stage_parent.mkdir()
        download_log = worktree / "powershell-download.log"
        install_log = worktree / "powershell-install.log"
        harness = create_powershell_harness(
            worktree,
            updater=source / "update.ps1",
            source=source,
            check=check,
        )
        command = [
            runner.executable,
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(harness),
        ]
        environment = {
            "MOCK_PS_TAG": tag,
            "MOCK_PS_ARCHIVE": str(archive or ""),
            "MOCK_PS_DOWNLOAD_LOG": str(download_log),
            "MOCK_PS_DOWNLOAD_FAIL": "1" if download_fail else "0",
            "MOCK_INSTALL_LOG": str(install_log),
            # .NET uses TMP/TEMP when resolving GetTempPath on Windows.
            "TEMP": str(stage_parent),
            "TMP": str(stage_parent),
        }
        result = run_process(command, cwd=worktree, input_text=answer, env=environment, timeout=60)
        return result, stage_parent, download_log, install_log

    def run_powershell_setup_mock(
        self,
        *,
        source: Path,
        worktree: Path,
        target: Path,
        tag: str,
        archive: Path | None = None,
        answer: str,
        api_failure: bool = False,
    ) -> tuple[subprocess.CompletedProcess[str], Path]:
        runner = self.powershell_runner()
        stage_parent = worktree / "powershell-setup-temp"
        stage_parent.mkdir()
        harness = create_powershell_setup_harness(
            worktree,
            setup=source / "setup.ps1",
            source=source,
            api_failure=api_failure,
        )
        command = [
            runner.executable,
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(harness),
        ]
        environment = {
            "MOCK_PS_TAG": tag,
            "MOCK_PS_ARCHIVE": str(archive or ""),
            "MOCK_INSTALL_LOG": str(worktree / "powershell-setup-install.log"),
            "TEMP": str(stage_parent),
            "TMP": str(stage_parent),
        }
        result = run_process(
            command,
            cwd=worktree,
            input_text=answer,
            env=environment,
            timeout=60,
        )
        return result, stage_parent

    def test_offline_setup_skips_network_and_preserves_relative_cwd(self) -> None:
        for runner in self.runners:
            with self.subTest(runner=runner):
                with tempfile.TemporaryDirectory(prefix="astra-release-setup-") as temporary:
                    worktree = Path(temporary)
                    target = worktree / "target"
                    target.mkdir()
                    fake = FakeCurl(worktree / "bin")
                    before = snapshot_tree(ROOT)
                    result = self.run_setup(
                        runner,
                        ROOT,
                        worktree,
                        target,
                        components=("n", "n", "n"),
                        env=fake.environment(fail=True),
                    )
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertFalse(fake.log.exists(), "--offline must not invoke curl")
                    self.assertEqual([], list(target.iterdir()))
                    self.assertEqual(before, snapshot_tree(ROOT), "setup changed its source checkout")

    def test_powershell_mocked_check_uses_numeric_semver_and_does_not_write(self) -> None:
        runner = self.powershell_runner()
        with tempfile.TemporaryDirectory(prefix="astra-powershell-semver-") as temporary:
            worktree = Path(temporary)
            source = worktree / "source"
            shutil.copytree(ROOT, source, ignore=shutil.ignore_patterns(".git", "__pycache__"))
            (source / "VERSION").write_text("0.9.0\n", encoding="utf-8")
            before = snapshot_tree(source)
            result, stage_parent, download_log, _install_log = self.run_powershell_mock(
                source=source,
                worktree=worktree,
                check=True,
                tag="v0.10.0",
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            output = (result.stdout + result.stderr).lower()
            self.assertIn("v0.10.0", output)
            self.assertIn("newer", output)
            self.assertFalse(download_log.exists(), "-Check must not download an archive")
            self.assertEqual([], list(stage_parent.iterdir()), "-Check created staging files")
            self.assertEqual(before, snapshot_tree(source), "-Check modified the source tree")

    def test_powershell_mocked_update_confirmation_eof_and_cleanup(self) -> None:
        runner = self.powershell_runner()
        del runner  # Keep the explicit availability/skip check above readable.
        cases = (
            ("declined", False, "n", 0, False),
            ("eof", False, "", 1, False),
            ("success", False, "y\n", 0, True),
            ("installer-failure", True, "y\n", 1, True),
        )
        for name, failing, answer, expected_returncode, expect_install in cases:
            with self.subTest(case=name):
                with tempfile.TemporaryDirectory(prefix="astra-powershell-update-") as temporary:
                    worktree = Path(temporary)
                    archive = create_powershell_release_archive(worktree, failing=failing)
                    result, stage_parent, download_log, install_log = self.run_powershell_mock(
                        source=ROOT,
                        worktree=worktree,
                        check=False,
                        tag="v9.9.9",
                        archive=archive,
                        answer=answer,
                    )
                    self.assertEqual(result.returncode, expected_returncode, result.stdout + result.stderr)
                    if expect_install:
                        self.assertEqual(["run"], install_log.read_text(encoding="utf-8").splitlines())
                        self.assertEqual(["https://github.com/donvito/codex-astra-luna-orchestrator/archive/refs/tags/v9.9.9.zip"], download_log.read_text(encoding="utf-8").splitlines())
                    else:
                        self.assertFalse(install_log.exists(), result.stdout + result.stderr)
                        self.assertFalse(download_log.exists(), result.stdout + result.stderr)
                    self.assertEqual([], list(stage_parent.iterdir()), "PowerShell updater left staging files")

    def test_powershell_setup_api_failure_falls_back_to_local_install(self) -> None:
        self.powershell_runner()
        with tempfile.TemporaryDirectory(prefix="astra-powershell-api-failure-") as temporary:
            worktree = Path(temporary)
            target = worktree / "target"
            target.mkdir()
            answer = setup_input(target, "pro")
            result, stage_parent = self.run_powershell_setup_mock(
                source=ROOT,
                worktree=worktree,
                target=target,
                tag="v9.9.9",
                answer=answer,
                api_failure=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((target / ".codex" / "config.toml").is_file(), result.stdout + result.stderr)
            self.assertEqual([], list(stage_parent.iterdir()))

    def test_powershell_confirmed_automatic_update_failure_does_not_fall_back_to_local_setup(self) -> None:
        self.powershell_runner()
        with tempfile.TemporaryDirectory(prefix="astra-powershell-auto-failure-") as temporary:
            worktree = Path(temporary)
            target = worktree / "target"
            target.mkdir()
            archive = create_powershell_release_archive(worktree, failing=True)
            # The answers after the release confirmation are deliberately a
            # complete local setup.  If setup.ps1 falls back after a selected
            # release fails, it will consume them and install the old source,
            # making the regression observable.
            answer = "y\n" + setup_input(target, "pro")
            result, _stage_parent = self.run_powershell_setup_mock(
                source=ROOT,
                worktree=worktree,
                target=target,
                tag="v9.9.9",
                archive=archive,
                answer=answer,
            )
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((target / ".codex").exists(), result.stdout + result.stderr)

    def test_all_profiles_install_the_expected_baseline(self) -> None:
        profiles = {
            "pro": ("gpt-6-astra", "4"),
            "plus": ("gpt-5.6-luna", "4"),
            "pro-max-2-subagents": ("gpt-6-astra", "2"),
            "plus-max-2-subagents": ("gpt-5.6-luna", "2"),
        }
        # The profile files are identical across native installers, so one
        # available runner gives complete profile coverage without doubling
        # the slow interactive process matrix.  The previous test covers both.
        runner = next((candidate for candidate in self.runners if candidate.is_shell), self.runners[0])
        for profile, (model, concurrency) in profiles.items():
            with self.subTest(profile=profile, runner=runner):
                with tempfile.TemporaryDirectory(prefix="astra-profile-") as temporary:
                    worktree = Path(temporary)
                    target = worktree / "target"
                    target.mkdir()
                    result = self.run_setup(runner, ROOT, worktree, target, profile=profile)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    config = (target / ".codex" / "config.toml").read_text(encoding="utf-8")
                    self.assertIn(f'model = "{model}"', config)
                    self.assertIn(f"max_concurrent_threads_per_session = {concurrency}", config)
                    self.assertTrue((target / ".agents" / "skills" / "astra-orchestrator" / "SKILL.md").is_file())
                    self.assertEqual(
                        (target / "AGENTS.md").read_text(encoding="utf-8"),
                        (ROOT / "AGENTS.md").read_text(encoding="utf-8"),
                    )

    def test_declining_existing_component_overwrite_preserves_local_edit(self) -> None:
        for runner in self.runners:
            with self.subTest(runner=runner):
                with tempfile.TemporaryDirectory(prefix="astra-overwrite-") as temporary:
                    worktree = Path(temporary)
                    target = worktree / "target"
                    target.mkdir()
                    first = self.run_setup(runner, ROOT, worktree, target)
                    self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
                    config_path = target / ".codex" / "config.toml"
                    original = config_path.read_text(encoding="utf-8")
                    marker = "\n# local customization retained by declined update\n"
                    config_path.write_text(original + marker, encoding="utf-8")

                    # Install .codex, decline its overwrite, and skip the
                    # other components so no unrelated prompt is involved.
                    second = self.run_setup(
                        runner,
                        ROOT,
                        worktree,
                        target,
                        components=("y", "n", "n"),
                        input_suffix="n\n",
                    )
                    self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
                    self.assertEqual(original + marker, config_path.read_text(encoding="utf-8"))

    def test_release_check_uses_numeric_semver_and_does_not_write(self) -> None:
        for runner in self.runners_for(shell_only=True, network=True):
            with self.subTest(runner=runner):
                with tempfile.TemporaryDirectory(prefix="astra-semver-") as temporary:
                    worktree = Path(temporary)
                    source = worktree / "source"
                    shutil.copytree(ROOT, source, ignore=shutil.ignore_patterns(".git", "__pycache__"))
                    fake = FakeCurl(worktree / "bin", tag="v0.10.0")
                    (source / "VERSION").write_text("0.9.0\n", encoding="utf-8")
                    before = snapshot_tree(source)
                    result = self.run_check(runner, source, worktree, tag="v0.10.0", fake_curl=fake)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    output = (result.stdout + result.stderr).lower()
                    self.assertIn("0.10.0", output)
                    self.assertTrue(any(word in output for word in ("newer", "available", "update")), output)
                    self.assertEqual(before, snapshot_tree(source), "--check modified the source tree")
                    calls = fake.log.read_text(encoding="utf-8").splitlines()
                    self.assertEqual(1, len(calls), calls)

    def test_setup_network_failure_falls_back_to_local_install(self) -> None:
        for runner in self.runners_for(shell_only=True, network=True):
            with self.subTest(runner=runner):
                with tempfile.TemporaryDirectory(prefix="astra-network-fallback-") as temporary:
                    worktree = Path(temporary)
                    target = worktree / "target"
                    target.mkdir()
                    fake = FakeCurl(worktree / "bin", fail=True)
                    result = self.run_setup(
                        runner,
                        ROOT,
                        worktree,
                        target,
                        offline=False,
                        env=fake.environment(fail=True),
                    )
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertTrue((target / ".codex" / "config.toml").is_file(), result.stdout + result.stderr)
                    self.assertTrue(
                        any(word in (result.stdout + result.stderr).lower() for word in ("warning", "failed", "unable")),
                        result.stdout + result.stderr,
                    )

    def test_automatic_release_decline_continues_with_local_setup(self) -> None:
        for runner in self.runners:
            with self.subTest(runner=runner):
                if runner.is_shell and os.name == "nt":
                    continue
                with tempfile.TemporaryDirectory(prefix="astra-auto-decline-") as temporary:
                    worktree = Path(temporary)
                    target = worktree / "target"
                    target.mkdir()
                    if runner.is_shell:
                        fake = FakeCurl(worktree / "bin", tag="v9.9.9")
                        result = self.run_setup(
                            runner,
                            ROOT,
                            worktree,
                            target,
                            offline=False,
                            input_text="n\n" + setup_input(target, "pro"),
                            env=fake.environment(),
                        )
                    else:
                        archive = create_powershell_release_archive(worktree)
                        result, _stage_parent = self.run_powershell_setup_mock(
                            source=ROOT,
                            worktree=worktree,
                            target=target,
                            tag="v9.9.9",
                            archive=archive,
                            answer="n\n" + setup_input(target, "pro"),
                        )
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertTrue((target / ".codex" / "config.toml").is_file(), result.stdout + result.stderr)
                    self.assertIn("declin", (result.stdout + result.stderr).lower())

    def test_successful_automatic_release_does_not_continue_old_setup(self) -> None:
        for runner in self.runners:
            with self.subTest(runner=runner):
                if runner.is_shell and os.name == "nt":
                    continue
                with tempfile.TemporaryDirectory(prefix="astra-auto-success-") as temporary:
                    worktree = Path(temporary)
                    target = worktree / "target"
                    target.mkdir()
                    if runner.is_shell:
                        archive = create_release_archive(worktree)
                        fake = FakeCurl(worktree / "bin", archive=archive, tag="v9.9.9")
                        marker = worktree / "install.log"
                        environment = fake.environment()
                        environment["MOCK_INSTALL_LOG"] = str(marker)
                        environment["MOCK_INSTALL_COUNT_FILE"] = str(worktree / "install.count")
                        result = self.run_setup(
                            runner,
                            ROOT,
                            worktree,
                            target,
                            offline=False,
                            input_text="y\n",
                            env=environment,
                        )
                    else:
                        archive = create_powershell_release_archive(worktree)
                        result, _stage_parent = self.run_powershell_setup_mock(
                            source=ROOT,
                            worktree=worktree,
                            target=target,
                            tag="v9.9.9",
                            archive=archive,
                            answer="y\n",
                        )
                        marker = worktree / "powershell-setup-install.log"
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(["run"], marker.read_text(encoding="utf-8").splitlines())
                    self.assertFalse((target / ".codex").exists(), result.stdout + result.stderr)
                    # setup.ps1 prints its banner before checking for an
                    # update; setup.sh prints it after the check.  The target
                    # prompt belongs to the old setup body, so it must never
                    # appear after a successful release relaunch.
                    self.assertNotIn("Target repository path:", result.stdout)

    def test_missing_or_invalid_version_falls_back_without_offering_release(self) -> None:
        for version_text in (None, "development"):
            for runner in self.runners:
                with self.subTest(version=version_text, runner=runner):
                    if runner.is_shell and os.name == "nt":
                        continue
                    with tempfile.TemporaryDirectory(prefix="astra-version-fallback-") as temporary:
                        worktree = Path(temporary)
                        source = worktree / "source"
                        shutil.copytree(ROOT, source, ignore=shutil.ignore_patterns(".git", "__pycache__"))
                        version_path = source / "VERSION"
                        if version_text is None:
                            version_path.unlink()
                        else:
                            version_path.write_text(version_text + "\n", encoding="utf-8")
                        target = worktree / "target"
                        target.mkdir()
                        if runner.is_shell:
                            fake = FakeCurl(worktree / "bin", tag="v9.9.9")
                            result = self.run_setup(
                                runner,
                                source,
                                worktree,
                                target,
                                offline=False,
                                input_text=setup_input(target, "pro"),
                                env=fake.environment(),
                            )
                            self.assertFalse(fake.log.exists(), "invalid VERSION should not call the release endpoint")
                        else:
                            archive = create_powershell_release_archive(worktree)
                            result, _stage_parent = self.run_powershell_setup_mock(
                                source=source,
                                worktree=worktree,
                                target=target,
                                tag="v9.9.9",
                                archive=archive,
                                answer=setup_input(target, "pro"),
                            )
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        output = (result.stdout + result.stderr).lower()
                        self.assertTrue((target / ".codex" / "config.toml").is_file(), output)
                        self.assertNotIn("download and run", output)

    def test_automatic_confirmation_eof_cancels_without_local_setup(self) -> None:
        for runner in self.runners:
            with self.subTest(runner=runner):
                if runner.is_shell and os.name == "nt":
                    continue
                with tempfile.TemporaryDirectory(prefix="astra-auto-eof-") as temporary:
                    worktree = Path(temporary)
                    target = worktree / "target"
                    target.mkdir()
                    if runner.is_shell:
                        fake = FakeCurl(worktree / "bin", tag="v9.9.9")
                        result = self.run_setup(
                            runner,
                            ROOT,
                            worktree,
                            target,
                            offline=False,
                            input_text="",
                            env=fake.environment(),
                        )
                    else:
                        archive = create_powershell_release_archive(worktree)
                        result, _stage_parent = self.run_powershell_setup_mock(
                            source=ROOT,
                            worktree=worktree,
                            target=target,
                            tag="v9.9.9",
                            archive=archive,
                            answer="",
                        )
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertFalse((target / ".codex").exists(), result.stdout + result.stderr)

    def test_confirmed_automatic_update_failure_does_not_fall_back_to_local_setup(self) -> None:
        """A selected release failure must be visible to the caller.

        Falling back into the old installer after the user approved a release
        would make a failed update look successful and could consume the same
        stdin as a second, unintended installation.  Keep this test shell only
        because its curl replacement is deterministic on POSIX environments.
        """

        for runner in self.runners_for(shell_only=True, network=True):
            with self.subTest(runner=runner):
                with tempfile.TemporaryDirectory(prefix="astra-auto-failure-") as temporary:
                    worktree = Path(temporary)
                    target = worktree / "target"
                    target.mkdir()
                    archive = create_release_archive(worktree, failing=True)
                    fake = FakeCurl(worktree / "bin", archive=archive)
                    result = self.run_setup(
                        runner,
                        ROOT,
                        worktree,
                        target,
                        offline=False,
                        input_text="y\n",
                        env=fake.environment(),
                    )
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertFalse((target / ".codex").exists(), result.stdout + result.stderr)

    def _run_release_update(self, *, failing: bool, answer: str) -> tuple[subprocess.CompletedProcess[str], Path, Path, FakeCurl]:
        runner = self.runners_for(shell_only=True, network=True)[0]
        temporary = tempfile.TemporaryDirectory(prefix="astra-release-download-")
        worktree = Path(temporary.name)
        archive = create_release_archive(worktree, failing=failing)
        fake = FakeCurl(worktree / "bin", archive=archive, tag="v9.9.9")
        cleanup = worktree / "release-temp"
        cleanup.mkdir()
        marker = worktree / "install.log"
        count = worktree / "install.count"
        target = worktree / "target"
        target.mkdir()
        environment = fake.environment()
        environment.update(
            {
                "MOCK_INSTALL_LOG": str(marker),
                "MOCK_INSTALL_COUNT_FILE": str(count),
                "TMPDIR": str(cleanup),
                "TEMP": str(cleanup),
                "TMP": str(cleanup),
            }
        )
        result = run_process(
            runner.updater_command(ROOT),
            cwd=worktree,
            input_text=answer,
            env=environment,
            timeout=60,
        )
        # Keep the TemporaryDirectory alive for the caller's assertions.
        result._astra_test_tempdir = temporary  # type: ignore[attr-defined]
        return result, cleanup, marker, fake

    def test_updater_decline_does_not_download_release(self) -> None:
        result, cleanup, marker, fake = self._run_release_update(failing=False, answer="n\n")
        try:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists(), result.stdout + result.stderr)
            self.assertFalse(any("release-success" in line for line in fake.log.read_text(encoding="utf-8").splitlines()))
            self.assertEqual([], list(cleanup.iterdir()), "declined update left temporary files")
        finally:
            result._astra_test_tempdir.cleanup()  # type: ignore[attr-defined]

    def test_updater_runs_downloaded_installer_once_and_cleans_success(self) -> None:
        result, cleanup, marker, _fake = self._run_release_update(failing=False, answer="y\n")
        try:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.is_file(), result.stdout + result.stderr)
            self.assertEqual(1, len(marker.read_text(encoding="utf-8").splitlines()))
            self.assertEqual([], list(cleanup.iterdir()), "successful update left temporary files")
        finally:
            result._astra_test_tempdir.cleanup()  # type: ignore[attr-defined]

    def test_updater_cleans_temporary_files_when_downloaded_installer_fails(self) -> None:
        result, cleanup, marker, _fake = self._run_release_update(failing=True, answer="y\n")
        try:
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(marker.is_file(), result.stdout + result.stderr)
            self.assertEqual(1, len(marker.read_text(encoding="utf-8").splitlines()))
            self.assertEqual([], list(cleanup.iterdir()), "failed update left temporary files")
        finally:
            result._astra_test_tempdir.cleanup()  # type: ignore[attr-defined]


if __name__ == "__main__":
    unittest.main()
