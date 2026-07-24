#!/usr/bin/env python3

from __future__ import annotations

import argparse
import configparser
import os
import platform
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Callable

BUILD_ID_RE = re.compile(r"[0-9]{14}", re.ASCII)
SUPPORTED_ARCHES = frozenset({"arm64", "x86_64"})
LIPO = "/usr/bin/lipo"


class Stage1VerificationError(ValueError):
    pass


@dataclass(frozen=True)
class Stage1Identity:
    binary: Path
    runner_arch: str
    binary_arch: str
    application_build_id: str
    platform_build_id: str


def validate_build_id(value: str) -> str:
    if not isinstance(value, str) or BUILD_ID_RE.fullmatch(value) is None:
        raise Stage1VerificationError("build ID must be exactly 14 ASCII digits")
    try:
        parsed = datetime.strptime(value, "%Y%m%d%H%M%S")
    except ValueError as exc:
        raise Stage1VerificationError("build ID must be a valid UTC timestamp") from exc
    if parsed.strftime("%Y%m%d%H%M%S") != value:
        raise Stage1VerificationError("build ID must be canonical")
    return value


def require_within_root(root: Path, path: Path, label: str = "path") -> None:
    try:
        path.relative_to(root)
    except ValueError as exc:
        raise Stage1VerificationError(f"{label} escapes trusted root: {path}") from exc


def resolve_search_root(workspace_root: Path, search_root: Path) -> Path:
    try:
        workspace = workspace_root.resolve(strict=True)
    except OSError as exc:
        raise Stage1VerificationError(
            f"could not resolve workspace root {workspace_root}: {exc}"
        ) from exc
    if not workspace.is_dir():
        raise Stage1VerificationError(f"workspace root is not a directory: {workspace}")

    declared = search_root if search_root.is_absolute() else workspace / search_root
    declared = Path(os.path.abspath(declared))
    require_within_root(workspace, declared, "Stage 1 search root")
    current = workspace
    for component in declared.relative_to(workspace).parts:
        current /= component
        if current.is_symlink():
            raise Stage1VerificationError(
                f"Stage 1 search root must not contain symlinks: {current}"
            )
    try:
        root = declared.resolve(strict=True)
    except OSError as exc:
        raise Stage1VerificationError(
            f"could not resolve Stage 1 search root {declared}: {exc}"
        ) from exc
    if root != declared:
        raise Stage1VerificationError(
            f"Stage 1 search root must not contain symlinks: {declared}"
        )
    if not root.is_dir():
        raise Stage1VerificationError(f"Stage 1 search root is not a directory: {root}")
    return root


def discover_binary(
    workspace_root: Path,
    search_root: Path,
    executable_check: Callable[[Path, int], bool] | None = None,
) -> tuple[Path, Path]:
    root = resolve_search_root(workspace_root, search_root)

    candidates = sorted(root.glob("*.app/Contents/MacOS/floorp"))
    if len(candidates) != 1:
        raise Stage1VerificationError(
            f"expected exactly one Stage 1 app binary in {root}, "
            f"found {len(candidates)}"
        )

    candidate = candidates[0]
    try:
        binary = candidate.resolve(strict=True)
    except OSError as exc:
        raise Stage1VerificationError(
            f"could not resolve Stage 1 binary {candidate}: {exc}"
        ) from exc
    require_within_root(root, binary, "Stage 1 binary")
    if binary != candidate:
        raise Stage1VerificationError(
            f"Stage 1 binary path must not contain symlinks: {candidate}"
        )
    if not binary.is_file():
        raise Stage1VerificationError(f"Stage 1 binary is not a regular file: {binary}")

    checker = executable_check or os.access
    if not checker(binary, os.X_OK):
        raise Stage1VerificationError(f"Stage 1 binary is not executable: {binary}")
    return root, binary


def resolve_regular_file(root: Path, path: Path, label: str) -> Path:
    require_within_root(root, path, label)
    try:
        resolved = path.resolve(strict=True)
    except OSError as exc:
        raise Stage1VerificationError(
            f"could not resolve {label} {path}: {exc}"
        ) from exc
    require_within_root(root, resolved, label)
    if resolved != path:
        raise Stage1VerificationError(f"{label} path must not contain symlinks: {path}")
    if not resolved.is_file():
        raise Stage1VerificationError(f"{label} is not a regular file: {resolved}")
    return resolved


def read_build_id(path: Path, section: str) -> str:
    parser = configparser.ConfigParser(
        interpolation=None,
        strict=True,
        empty_lines_in_values=False,
    )
    parser.optionxform = str
    try:
        with path.open("r", encoding="utf-8") as stream:
            parser.read_file(stream, source=str(path))
    except (OSError, UnicodeError, configparser.Error) as exc:
        raise Stage1VerificationError(f"could not parse {path}: {exc}") from exc

    if not parser.has_section(section):
        raise Stage1VerificationError(f"missing [{section}] section in {path}")
    if not parser.has_option(section, "BuildID"):
        raise Stage1VerificationError(f"missing [{section}] BuildID in {path}")
    return validate_build_id(parser.get(section, "BuildID", raw=True))


def read_binary_arch(
    binary: Path,
    runner: Callable[..., subprocess.CompletedProcess[str]] | None = None,
) -> str:
    command_runner = runner or subprocess.run
    try:
        result = command_runner(
            [LIPO, "-archs", str(binary)],
            capture_output=True,
            check=False,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Stage1VerificationError(
            f"could not inspect Stage 1 binary: {exc}"
        ) from exc

    if result.returncode != 0:
        stderr = (result.stderr or "").strip()
        detail = f": {stderr}" if stderr else ""
        raise Stage1VerificationError(
            f"{LIPO} failed with exit code {result.returncode}{detail}"
        )
    arches = (result.stdout or "").split()
    if len(arches) != 1:
        raise Stage1VerificationError(
            "Stage 1 binary must contain exactly one architecture; "
            f"found {arches or 'none'}"
        )
    return arches[0]


def verify_stage1(
    workspace_root: Path,
    search_root: Path,
    expected_build_id: str,
    expected_arch: str,
    *,
    machine: str | None = None,
    lipo_runner: Callable[..., subprocess.CompletedProcess[str]] | None = None,
    executable_check: Callable[[Path, int], bool] | None = None,
) -> Stage1Identity:
    expected_id = validate_build_id(expected_build_id)
    if expected_arch not in SUPPORTED_ARCHES:
        raise Stage1VerificationError(
            f"unsupported expected architecture: {expected_arch}"
        )

    runner_arch = machine if machine is not None else platform.machine()
    if runner_arch != expected_arch:
        raise Stage1VerificationError(
            f"runner architecture mismatch: expected {expected_arch}, got {runner_arch}"
        )

    root, binary = discover_binary(workspace_root, search_root, executable_check)
    binary_arch = read_binary_arch(binary, lipo_runner)
    if binary_arch != expected_arch:
        raise Stage1VerificationError(
            f"binary architecture mismatch: expected {expected_arch}, got {binary_arch}"
        )

    resources = binary.parent.parent / "Resources"
    application_ini = resolve_regular_file(
        root, resources / "application.ini", "application.ini"
    )
    platform_ini = resolve_regular_file(
        root, resources / "platform.ini", "platform.ini"
    )
    application_build_id = read_build_id(application_ini, "App")
    platform_build_id = read_build_id(platform_ini, "Build")
    for label, actual in (
        ("application", application_build_id),
        ("platform", platform_build_id),
    ):
        if actual != expected_id:
            raise Stage1VerificationError(
                f"{label} BuildID mismatch: expected {expected_id}, got {actual}"
            )

    print(f"Stage 1 app binary: {binary}")
    print(f"Stage 1 runner architecture: {runner_arch}")
    print(f"Stage 1 binary architecture: {binary_arch}")
    print(f"Stage 1 application.ini: {application_ini}")
    print(f"Stage 1 application BuildID: {application_build_id}")
    print(f"Stage 1 platform.ini: {platform_ini}")
    print(f"Stage 1 platform BuildID: {platform_build_id}")

    return Stage1Identity(
        binary=binary,
        runner_arch=runner_arch,
        binary_arch=binary_arch,
        application_build_id=application_build_id,
        platform_build_id=platform_build_id,
    )


def write_github_output(path: Path, name: str, value: str) -> None:
    if any(character in value for character in ("\r", "\n")):
        raise Stage1VerificationError(f"{name} contains a line break")
    try:
        with path.open("a", encoding="utf-8", newline="\n") as stream:
            stream.write(f"{name}={value}\n")
    except OSError as exc:
        raise Stage1VerificationError(f"could not write GitHub output: {exc}") from exc


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Verify a macOS PGO Stage 1 bundle without launching it"
    )
    parser.add_argument("--workspace-root", required=True, type=Path)
    parser.add_argument("--search-root", required=True, type=Path)
    parser.add_argument("--expected-build-id", required=True)
    parser.add_argument("--expected-arch", required=True)
    parser.add_argument("--github-output", required=True, type=Path)
    args = parser.parse_args(argv)

    try:
        identity = verify_stage1(
            args.workspace_root,
            args.search_root,
            args.expected_build_id,
            args.expected_arch,
        )
        write_github_output(
            args.github_output,
            "app_binary",
            str(identity.binary),
        )
    except Stage1VerificationError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
