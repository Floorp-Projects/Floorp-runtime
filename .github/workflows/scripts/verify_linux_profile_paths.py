#!/usr/bin/env python3

from __future__ import annotations

import argparse
import configparser
import json
import os
import platform
import re
import signal
import stat
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any

PROFILE_SECTION_RE = re.compile(r"Profile[0-9]+", re.ASCII)
CREATE_PROFILE_ERROR = b"Error creating profile."
DEFAULT_TIMEOUT_SECONDS = 45.0
MAX_TIMEOUT_SECONDS = 300.0


class ProfilePathVerificationError(ValueError):
    pass


@dataclass(frozen=True)
class CaseSpec:
    name: str
    config_mode: str = "default"
    cache_mode: str = "default"
    legacy_marker: bool = False
    force_legacy: bool = False
    floorp_marker: bool = False
    mozilla_marker: bool = False
    precreate_xdg_product: bool = False


@dataclass(frozen=True)
class CaseContext:
    spec: CaseSpec
    root: Path
    evidence_root: Path
    home: Path
    config_base: Path
    cache_base: Path
    expected_config_root: Path
    expected_cache_root: Path
    profile_name: str
    environment: dict[str, str]
    protected_paths: tuple[Path, ...]
    protected_before: dict[str, dict[str, Any]]


CASES = (
    CaseSpec("fresh-default"),
    CaseSpec("custom-xdg", config_mode="custom", cache_mode="custom"),
    CaseSpec("relative-xdg-fallback", config_mode="relative", cache_mode="relative"),
    CaseSpec("existing-empty-legacy", legacy_marker=True),
    CaseSpec(
        "legacy-and-xdg",
        config_mode="custom",
        cache_mode="custom",
        legacy_marker=True,
        precreate_xdg_product=True,
    ),
    CaseSpec(
        "forced-legacy-xdg-cache",
        config_mode="custom",
        cache_mode="custom",
        force_legacy=True,
    ),
    CaseSpec("capital-floorp-ignored", floorp_marker=True),
    CaseSpec("mozilla-ignored", mozilla_marker=True),
)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _is_under_mnt(path: Path) -> bool:
    return len(path.parts) >= 2 and path.parts[0] == "/" and path.parts[1] == "mnt"


def _reject_mnt_path(path: Path, label: str) -> None:
    absolute = Path(os.path.abspath(path))
    resolved = absolute.resolve(strict=False)
    if _is_under_mnt(absolute) or _is_under_mnt(resolved):
        raise ProfilePathVerificationError(
            f"{label} must be on a native Linux filesystem, not under /mnt: {path}"
        )


def validate_binary(binary: Path) -> Path:
    if not binary.is_absolute():
        raise ProfilePathVerificationError("binary path must be absolute")
    _reject_mnt_path(binary, "binary")
    try:
        resolved = binary.resolve(strict=True)
    except OSError as exc:
        raise ProfilePathVerificationError(f"could not resolve binary: {exc}") from exc
    if not resolved.is_file():
        raise ProfilePathVerificationError(f"binary is not a regular file: {resolved}")
    if not os.access(resolved, os.X_OK):
        raise ProfilePathVerificationError(f"binary is not executable: {resolved}")
    return resolved


def validate_results_path(results_path: Path) -> Path:
    if not results_path.is_absolute():
        raise ProfilePathVerificationError("results JSON path must be absolute")
    absolute = Path(os.path.abspath(results_path))
    if absolute.exists() and (absolute.is_dir() or absolute.is_symlink()):
        raise ProfilePathVerificationError(
            f"results JSON must be a regular file path: {absolute}"
        )
    return absolute


def prepare_work_dir(work_dir: Path, results_path: Path) -> Path:
    if not work_dir.is_absolute():
        raise ProfilePathVerificationError("work directory path must be absolute")
    _reject_mnt_path(work_dir, "work directory")
    absolute = Path(os.path.abspath(work_dir))
    if absolute == Path("/") or absolute == Path("/tmp"):
        raise ProfilePathVerificationError(
            f"work directory must be a dedicated child directory: {absolute}"
        )
    if absolute.exists():
        if absolute.is_symlink() or not absolute.is_dir():
            raise ProfilePathVerificationError(
                f"work directory must be a real directory: {absolute}"
            )
        entries = list(absolute.iterdir())
        if entries:
            raise ProfilePathVerificationError(
                f"work directory must be empty: {absolute}"
            )
    else:
        try:
            absolute.mkdir(parents=True, mode=0o700)
        except OSError as exc:
            raise ProfilePathVerificationError(
                f"could not create work directory {absolute}: {exc}"
            ) from exc
    if results_path == absolute:
        raise ProfilePathVerificationError(
            "results JSON path cannot be the work directory"
        )
    return absolute.resolve(strict=True)


def validate_timeout(timeout: float) -> float:
    if not 0.1 <= timeout <= MAX_TIMEOUT_SECONDS:
        raise ProfilePathVerificationError(
            f"timeout must be between 0.1 and {MAX_TIMEOUT_SECONDS:g} seconds"
        )
    return timeout


def write_json(path: Path, value: Any) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.parent / f".{path.name}.{os.getpid()}.tmp"
        with temporary.open("w", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.replace(temporary, path)
    except OSError as exc:
        raise ProfilePathVerificationError(
            f"could not write JSON {path}: {exc}"
        ) from exc


def snapshot_tree(root: Path) -> dict[str, Any]:
    if not root.exists():
        return {"exists": False, "entries": []}

    entries: list[dict[str, Any]] = []
    for current, directories, files in os.walk(root, followlinks=False):
        directories.sort()
        files.sort()
        current_path = Path(current)
        for name in (*directories, *files):
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            try:
                metadata = path.lstat()
            except OSError as exc:
                entries.append({"path": relative, "type": "error", "error": str(exc)})
                continue
            entry: dict[str, Any] = {
                "path": relative,
                "mode": stat.S_IMODE(metadata.st_mode),
            }
            if stat.S_ISLNK(metadata.st_mode):
                entry["type"] = "symlink"
                try:
                    entry["target"] = os.readlink(path)
                except OSError as exc:
                    entry["error"] = str(exc)
            elif stat.S_ISDIR(metadata.st_mode):
                entry["type"] = "directory"
            elif stat.S_ISREG(metadata.st_mode):
                entry["type"] = "file"
                entry["size"] = metadata.st_size
            else:
                entry["type"] = "other"
            entries.append(entry)
    entries.sort(key=lambda entry: entry["path"])
    return {"exists": True, "entries": entries}


def _xdg_base(
    case_root: Path, home: Path, kind: str, mode: str
) -> tuple[Path, str | None]:
    if mode == "default":
        return home / f".{kind}", None
    if mode == "custom":
        path = case_root / f"xdg-{kind}"
        return path, str(path)
    if mode == "relative":
        return home / f".{kind}", f"relative-{kind}"
    raise ProfilePathVerificationError(f"unsupported {kind} mode: {mode}")


def prepare_case(work_dir: Path, spec: CaseSpec) -> CaseContext:
    root = work_dir / "state" / spec.name
    evidence_root = work_dir / "evidence" / spec.name
    home = root / "home"
    temporary = root / "tmp"
    runtime = root / "runtime"
    for directory in (home, temporary, runtime):
        directory.mkdir(parents=True, mode=0o700)
    evidence_root.mkdir(parents=True)
    runtime.chmod(0o700)

    config_base, config_env = _xdg_base(root, home, "config", spec.config_mode)
    cache_base, cache_env = _xdg_base(root, home, "cache", spec.cache_mode)

    protected_paths: list[Path] = []
    if spec.legacy_marker:
        (home / ".floorp").mkdir()
    if spec.floorp_marker:
        marker = home / "Floorp"
        marker.mkdir()
        protected_paths.append(marker)
    if spec.mozilla_marker:
        marker = home / "mozilla"
        marker.mkdir()
        protected_paths.append(marker)
    if spec.precreate_xdg_product:
        marker = config_base / "floorp"
        marker.mkdir(parents=True)
        protected_paths.append(marker)

    expected_config_root = (
        home / ".floorp"
        if spec.legacy_marker or spec.force_legacy
        else config_base / "floorp"
    )
    expected_cache_root = cache_base / "floorp"
    profile_name = f"floorp2601-{spec.name}"

    environment = {
        "HOME": str(home),
        "TMPDIR": str(temporary),
        "XDG_RUNTIME_DIR": str(runtime),
        "MOZ_HEADLESS": "1",
        "MOZ_CRASHREPORTER_DISABLE": "1",
        "MOZ_CRASHREPORTER_NO_REPORT": "1",
        "NO_AT_BRIDGE": "1",
    }
    if config_env is not None:
        environment["XDG_CONFIG_HOME"] = config_env
    if cache_env is not None:
        environment["XDG_CACHE_HOME"] = cache_env
    if spec.force_legacy:
        environment["MOZ_LEGACY_HOME"] = "1"

    protected_before = {
        str(path.relative_to(root)): snapshot_tree(path) for path in protected_paths
    }
    return CaseContext(
        spec=spec,
        root=root,
        evidence_root=evidence_root,
        home=home,
        config_base=config_base,
        cache_base=cache_base,
        expected_config_root=expected_config_root,
        expected_cache_root=expected_cache_root,
        profile_name=profile_name,
        environment=environment,
        protected_paths=tuple(protected_paths),
        protected_before=protected_before,
    )


def _clean_environment(case_environment: dict[str, str]) -> dict[str, str]:
    environment = {
        "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
        "LANG": os.environ.get("LANG", "C.UTF-8"),
    }
    environment.update(case_environment)
    return environment


def _signal_process_group(process_group: int, process_signal: signal.Signals) -> bool:
    try:
        os.killpg(process_group, process_signal)
        return True
    except ProcessLookupError:
        return False
    except OSError:
        return False


def _terminate_process_group(process_group: int) -> None:
    if not _signal_process_group(process_group, signal.SIGTERM):
        return
    time.sleep(0.25)
    _signal_process_group(process_group, signal.SIGKILL)


def launch_create_profile(
    binary: Path,
    context: CaseContext,
    stdout_path: Path,
    stderr_path: Path,
    timeout: float,
) -> dict[str, Any]:
    command = [
        str(binary),
        "--headless",
        "--no-remote",
        "--createprofile",
        context.profile_name,
    ]
    started = time.monotonic()
    timed_out = False
    return_code: int | None = None
    process: subprocess.Popen[bytes] | None = None
    try:
        with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
            process = subprocess.Popen(
                command,
                cwd=context.root,
                env=_clean_environment(context.environment),
                stdin=subprocess.DEVNULL,
                stdout=stdout,
                stderr=stderr,
                start_new_session=True,
            )
            try:
                return_code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                _terminate_process_group(process.pid)
                try:
                    return_code = process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    _signal_process_group(process.pid, signal.SIGKILL)
                    return_code = process.wait(timeout=5)
            else:
                _terminate_process_group(process.pid)
    except OSError as exc:
        if process is not None and process.poll() is None:
            _terminate_process_group(process.pid)
        raise ProfilePathVerificationError(f"could not launch Floorp: {exc}") from exc

    return {
        "command": command,
        "return_code": return_code,
        "timed_out": timed_out,
        "duration_seconds": round(time.monotonic() - started, 3),
    }


def _contains_bytes(path: Path, needle: bytes) -> bool:
    try:
        overlap = b""
        with path.open("rb") as stream:
            while chunk := stream.read(64 * 1024):
                combined = overlap + chunk
                if needle in combined:
                    return True
                overlap = combined[-(len(needle) - 1) :] if len(needle) > 1 else b""
    except OSError as exc:
        raise ProfilePathVerificationError(
            f"could not read process log {path}: {exc}"
        ) from exc
    return False


def parse_created_profile(context: CaseContext) -> dict[str, str]:
    profiles_ini = context.expected_config_root / "profiles.ini"
    parser = configparser.ConfigParser(
        interpolation=None,
        strict=True,
        empty_lines_in_values=False,
    )
    parser.optionxform = str
    try:
        with profiles_ini.open("r", encoding="utf-8-sig") as stream:
            parser.read_file(stream, source=str(profiles_ini))
    except (OSError, UnicodeError, configparser.Error) as exc:
        raise ProfilePathVerificationError(
            f"could not parse expected profiles.ini {profiles_ini}: {exc}"
        ) from exc

    sections = [
        section
        for section in parser.sections()
        if PROFILE_SECTION_RE.fullmatch(section)
    ]
    if len(sections) != 1:
        raise ProfilePathVerificationError(
            f"expected exactly one profile entry in {profiles_ini}, found {len(sections)}"
        )
    section = sections[0]
    try:
        name = parser.get(section, "Name", raw=True)
        is_relative = parser.get(section, "IsRelative", raw=True)
        raw_path = parser.get(section, "Path", raw=True)
    except (configparser.NoOptionError, configparser.NoSectionError) as exc:
        raise ProfilePathVerificationError(
            f"incomplete [{section}] in {profiles_ini}: {exc}"
        ) from exc

    if name != context.profile_name:
        raise ProfilePathVerificationError(
            f"profile name mismatch: expected {context.profile_name}, got {name}"
        )
    if is_relative != "1":
        raise ProfilePathVerificationError(
            f"profile path must be relative, got IsRelative={is_relative!r}"
        )

    relative = PurePosixPath(raw_path)
    if (
        relative.is_absolute()
        or len(relative.parts) != 1
        or relative.parts[0] in ("", ".", "..")
    ):
        raise ProfilePathVerificationError(
            f"profile Path must be one direct child, got {raw_path!r}"
        )
    profile_child = relative.parts[0]
    config_profile = context.expected_config_root / profile_child
    cache_profile = context.expected_cache_root / profile_child
    if not config_profile.is_dir():
        raise ProfilePathVerificationError(
            f"configuration profile child is missing: {config_profile}"
        )
    if not cache_profile.is_dir():
        raise ProfilePathVerificationError(
            f"matching cache profile child is missing: {cache_profile}"
        )

    return {
        "section": section,
        "name": name,
        "relative_path": profile_child,
        "config_profile": str(config_profile),
        "cache_profile": str(cache_profile),
    }


def assert_case_invariants(context: CaseContext) -> dict[str, str]:
    capital_floorp = context.home / "Floorp"
    if context.spec.floorp_marker:
        before = context.protected_before[str(capital_floorp.relative_to(context.root))]
        if snapshot_tree(capital_floorp) != before:
            raise ProfilePathVerificationError("pre-existing ~/Floorp was modified")
    elif capital_floorp.exists():
        raise ProfilePathVerificationError("unexpected ~/Floorp was created")

    legacy_floorp = context.home / ".floorp"
    if context.expected_config_root != legacy_floorp and legacy_floorp.exists():
        raise ProfilePathVerificationError(
            "unexpected ~/.floorp was created for an XDG profile"
        )

    for protected in context.protected_paths:
        key = str(protected.relative_to(context.root))
        if protected == capital_floorp:
            continue
        if snapshot_tree(protected) != context.protected_before[key]:
            raise ProfilePathVerificationError(
                f"ignored or losing path was modified: {protected}"
            )

    for base in (context.config_base, context.cache_base):
        dotted_sibling = base / ".floorp"
        if dotted_sibling.exists():
            raise ProfilePathVerificationError(
                f"unexpected dotted Floorp sibling under XDG base: {dotted_sibling}"
            )
        capital_sibling = base / "Floorp"
        if capital_sibling.exists():
            raise ProfilePathVerificationError(
                f"unexpected capitalized Floorp sibling under XDG base: "
                f"{capital_sibling}"
            )

    candidates = {
        context.home / ".floorp" / "profiles.ini",
        context.config_base / "floorp" / "profiles.ini",
    }
    expected_ini = context.expected_config_root / "profiles.ini"
    for candidate in candidates - {expected_ini}:
        if candidate.exists():
            raise ProfilePathVerificationError(
                f"profiles.ini was created in a losing root: {candidate}"
            )

    return parse_created_profile(context)


def preserve_profiles_ini(context: CaseContext, destination: Path) -> None:
    sources = sorted(context.root.rglob("profiles.ini"))
    if len(sources) > 16:
        raise ProfilePathVerificationError(
            f"found too many profiles.ini files to preserve: {len(sources)}"
        )
    files: list[dict[str, Any]] = []
    for source in sources:
        if source.is_symlink() or not source.is_file():
            raise ProfilePathVerificationError(
                f"profiles.ini evidence source is not a regular file: {source}"
            )
        try:
            data = source.read_bytes()
        except OSError as exc:
            raise ProfilePathVerificationError(
                f"could not preserve profiles.ini from {source}: {exc}"
            ) from exc
        if len(data) > 1024 * 1024:
            raise ProfilePathVerificationError(
                f"profiles.ini exceeds 1 MiB and was not copied: {source}"
            )
        try:
            content = data.decode("utf-8-sig", errors="strict")
        except UnicodeDecodeError as exc:
            raise ProfilePathVerificationError(
                f"profiles.ini is not valid UTF-8: {source}"
            ) from exc
        files.append({
            "path": source.relative_to(context.root).as_posix(),
            "size": len(data),
            "content": content,
        })
    write_json(destination, {"files": files})


def run_case(
    binary: Path, work_dir: Path, spec: CaseSpec, timeout: float
) -> dict[str, Any]:
    context = prepare_case(work_dir, spec)
    stdout_path = context.evidence_root / "stdout.txt"
    stderr_path = context.evidence_root / "stderr.txt"
    profiles_ini_path = context.evidence_root / "profiles-ini.json"
    before_path = context.evidence_root / "tree-before.json"
    after_path = context.evidence_root / "tree-after.json"
    case_result_path = context.evidence_root / "result.json"
    write_json(before_path, snapshot_tree(context.root))

    result: dict[str, Any] = {
        "name": spec.name,
        "status": "failed",
        "profile_name": context.profile_name,
        "environment": {
            key: context.environment[key]
            for key in (
                "HOME",
                "TMPDIR",
                "XDG_RUNTIME_DIR",
                "XDG_CONFIG_HOME",
                "XDG_CACHE_HOME",
                "MOZ_LEGACY_HOME",
                "MOZ_HEADLESS",
            )
            if key in context.environment
        },
        "expected": {
            "config_root": str(context.expected_config_root),
            "cache_root": str(context.expected_cache_root),
        },
        "artifacts": {
            "stdout": str(stdout_path),
            "stderr": str(stderr_path),
            "profiles_ini": str(profiles_ini_path),
            "tree_before": str(before_path),
            "tree_after": str(after_path),
            "result": str(case_result_path),
        },
        "errors": [],
    }

    errors: list[str] = result["errors"]
    try:
        process_result = launch_create_profile(
            binary, context, stdout_path, stderr_path, timeout
        )
        result["process"] = process_result
        if process_result["timed_out"]:
            errors.append(f"Floorp exceeded the {timeout:g} second timeout")
        if process_result["return_code"] != 0:
            errors.append(f"Floorp exited with code {process_result['return_code']}")
        if _contains_bytes(stdout_path, CREATE_PROFILE_ERROR) or _contains_bytes(
            stderr_path, CREATE_PROFILE_ERROR
        ):
            errors.append("Floorp reported 'Error creating profile.'")
        if not errors:
            try:
                result["profile"] = assert_case_invariants(context)
            except ProfilePathVerificationError as exc:
                errors.append(str(exc))
    except ProfilePathVerificationError as exc:
        errors.append(str(exc))
    finally:
        try:
            preserve_profiles_ini(context, profiles_ini_path)
        except ProfilePathVerificationError as exc:
            errors.append(str(exc))
        write_json(after_path, snapshot_tree(context.root))

    if not errors:
        result["status"] = "passed"
    write_json(case_result_path, result)
    return result


def run_verification(
    binary: Path,
    work_dir: Path,
    results_path: Path,
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
) -> dict[str, Any]:
    if platform.system() != "Linux":
        raise ProfilePathVerificationError("Linux is required")
    validated_results = validate_results_path(results_path)
    validated_binary = validate_binary(binary)
    validated_timeout = validate_timeout(timeout)
    validated_work = prepare_work_dir(work_dir, validated_results)

    started_at = utc_now()
    case_results = [
        run_case(validated_binary, validated_work, spec, validated_timeout)
        for spec in CASES
    ]
    passed = sum(result["status"] == "passed" for result in case_results)
    summary = {
        "schema_version": 1,
        "status": "passed" if passed == len(CASES) else "failed",
        "success": passed == len(CASES),
        "started_at": started_at,
        "finished_at": utc_now(),
        "binary": str(validated_binary),
        "work_dir": str(validated_work),
        "timeout_seconds": validated_timeout,
        "counts": {
            "total": len(CASES),
            "passed": passed,
            "failed": len(CASES) - passed,
        },
        "cases": case_results,
    }
    write_json(validated_results, summary)
    return summary


def _write_fatal_result(results_path: Path, message: str) -> None:
    try:
        if results_path.is_absolute():
            write_json(
                Path(os.path.abspath(results_path)),
                {
                    "schema_version": 1,
                    "status": "fatal",
                    "success": False,
                    "finished_at": utc_now(),
                    "fatal_error": message,
                },
            )
    except ProfilePathVerificationError:
        pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Verify packaged Floorp Linux profile and cache paths"
    )
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--work-dir", required=True, type=Path)
    parser.add_argument("--results-json", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS)
    args = parser.parse_args(argv)

    try:
        summary = run_verification(
            args.binary, args.work_dir, args.results_json, args.timeout
        )
    except ProfilePathVerificationError as exc:
        print(f"error: {exc}", file=sys.stderr)
        _write_fatal_result(args.results_json, str(exc))
        return 2

    print(
        "Floorp Linux profile path verification: "
        f"{summary['counts']['passed']}/{summary['counts']['total']} passed; "
        f"results={args.results_json}"
    )
    if not summary["success"]:
        for result in summary["cases"]:
            if result["status"] != "passed":
                print(
                    f"error: {result['name']}: {'; '.join(result['errors'])}",
                    file=sys.stderr,
                )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
