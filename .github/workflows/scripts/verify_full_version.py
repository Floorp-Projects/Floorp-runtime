#!/usr/bin/env python3

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


BUILD_ID_RE = re.compile(r"(?<![0-9])[0-9]{14}(?![0-9])")
BUILD_ID_PAIR_RE = re.compile(
    r"(?<![0-9])(?P<application>[0-9]{14})\s+"
    r"(?P<platform>[0-9]{14})(?![0-9])"
)
MAX_OUTPUT_BYTES = 1024 * 1024


class FullVersionError(ValueError):
    pass


@dataclass(frozen=True)
class FullVersionIdentity:
    application_build_id: str
    platform_build_id: str


def validate_expected_build_id(value: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{14}", value):
        raise FullVersionError("expected build ID must be exactly 14 ASCII digits")
    try:
        parsed = datetime.strptime(value, "%Y%m%d%H%M%S")
    except ValueError as exc:
        raise FullVersionError("expected build ID must be a valid UTC timestamp") from exc
    if parsed.strftime("%Y%m%d%H%M%S") != value:
        raise FullVersionError("expected build ID must be canonical")
    return value


def parse_full_version(output: str) -> FullVersionIdentity:
    if not isinstance(output, str) or not output.strip():
        raise FullVersionError("--full-version output must not be empty")

    build_ids = BUILD_ID_RE.findall(output)
    if len(build_ids) != 2:
        raise FullVersionError(
            "--full-version output must contain exactly two 14-digit build IDs; "
            f"found {len(build_ids)}"
        )

    pairs = list(BUILD_ID_PAIR_RE.finditer(output))
    if len(pairs) != 1:
        raise FullVersionError(
            "--full-version output must contain exactly one adjacent "
            f"application/platform build ID pair; found {len(pairs)}"
        )

    pair = pairs[0]
    return FullVersionIdentity(
        application_build_id=pair.group("application"),
        platform_build_id=pair.group("platform"),
    )


def verify_full_version(output: str, expected_build_id: str) -> FullVersionIdentity:
    expected = validate_expected_build_id(expected_build_id)
    identity = parse_full_version(output)
    if identity.application_build_id != expected:
        raise FullVersionError(
            "application build ID mismatch: "
            f"expected {expected}, got {identity.application_build_id}"
        )
    if identity.platform_build_id != expected:
        raise FullVersionError(
            "platform build ID mismatch: "
            f"expected {expected}, got {identity.platform_build_id}"
        )
    return identity


def read_output(path: Path) -> str:
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise FullVersionError(f"could not read --full-version output: {exc}") from exc
    if len(data) > MAX_OUTPUT_BYTES:
        raise FullVersionError("--full-version output exceeds 1 MiB")
    try:
        return data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise FullVersionError("--full-version output is not valid UTF-8") from exc


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Verify native Floorp --full-version build IDs"
    )
    parser.add_argument("--expected-build-id", required=True)
    parser.add_argument("--output-file", required=True, type=Path)
    args = parser.parse_args(argv)

    try:
        identity = verify_full_version(
            read_output(args.output_file), args.expected_build_id
        )
    except FullVersionError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(
        "Verified native --full-version identity: "
        f"application={identity.application_build_id} "
        f"platform={identity.platform_build_id}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
