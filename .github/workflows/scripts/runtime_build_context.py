#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Mapping

BUILD_ID_RE = re.compile(r"[0-9]{14}\Z")
CREATED_AT_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\Z")
REPOSITORY_RE = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9_.-]{1,100}\Z")
SHA_RE = re.compile(r"[0-9a-f]{40}\Z")
POSITIVE_DECIMAL_RE = re.compile(r"[1-9][0-9]{0,19}\Z")
MAX_RESPONSE_BYTES = 1024 * 1024


class BuildContextError(ValueError):
    pass


@dataclass(frozen=True)
class BuildContext:
    expected_build_id: str
    repository: str
    head_sha: str
    workflow_run_id: str
    run_created_at: str
    run_attempt: str

    def as_outputs(self) -> dict[str, str]:
        return {
            "expected-build-id": self.expected_build_id,
            "repository": self.repository,
            "head-sha": self.head_sha,
            "workflow-run-id": self.workflow_run_id,
            "run-created-at": self.run_created_at,
            "run-attempt": self.run_attempt,
        }


def validate_build_id(value: str, field: str) -> str:
    if not isinstance(value, str) or not BUILD_ID_RE.fullmatch(value):
        raise BuildContextError(f"{field} must be exactly 14 ASCII digits")
    try:
        parsed = datetime.strptime(value, "%Y%m%d%H%M%S")
    except ValueError as exc:
        raise BuildContextError(f"{field} is not a valid UTC timestamp") from exc
    if parsed.strftime("%Y%m%d%H%M%S") != value:
        raise BuildContextError(f"{field} is not canonical")
    return value


def validate_optional_build_id(value: str, field: str) -> str:
    if value == "":
        return ""
    return validate_build_id(value, field)


def validate_repository(value: str) -> str:
    if not isinstance(value, str) or not REPOSITORY_RE.fullmatch(value):
        raise BuildContextError("repository must be a canonical owner/name value")
    owner, name = value.split("/", 1)
    if owner.endswith("-") or "--" in owner or name in {".", ".."}:
        raise BuildContextError("repository must be a canonical owner/name value")
    return value


def validate_head_sha(value: str) -> str:
    if not isinstance(value, str) or not SHA_RE.fullmatch(value):
        raise BuildContextError(
            "head_sha must be exactly 40 lowercase hexadecimal characters"
        )
    return value


def validate_positive_decimal(value: str, field: str) -> str:
    if not isinstance(value, str) or not POSITIVE_DECIMAL_RE.fullmatch(value):
        raise BuildContextError(f"{field} must be a positive canonical decimal integer")
    return value


def validate_positive_integer(value: Any, field: str) -> int:
    if type(value) is not int or value <= 0 or len(str(value)) > 20:
        raise BuildContextError(f"REST {field} must be a positive integer")
    return value


def parse_created_at(value: Any) -> datetime:
    if not isinstance(value, str) or not CREATED_AT_RE.fullmatch(value):
        raise BuildContextError(
            "REST created_at must use canonical UTC YYYY-MM-DDTHH:MM:SSZ"
        )
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as exc:
        raise BuildContextError("REST created_at is not a valid UTC timestamp") from exc
    if parsed.strftime("%Y-%m-%dT%H:%M:%SZ") != value:
        raise BuildContextError("REST created_at is not canonical")
    return parsed


def derive_build_id(created_at: str) -> str:
    return parse_created_at(created_at).strftime("%Y%m%d%H%M%S")


def parse_boolean(value: str, field: str) -> bool:
    if value == "true":
        return True
    if value == "false":
        return False
    raise BuildContextError(f"{field} must be exactly true or false")


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise BuildContextError(
                f"REST response contains duplicate JSON key {key!r}"
            )
        result[key] = value
    return result


def parse_rest_json(data: bytes) -> Mapping[str, Any]:
    try:
        text = data.decode("utf-8", errors="strict")
        value = json.loads(
            text,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=lambda constant: (_ for _ in ()).throw(
                BuildContextError(
                    f"REST response contains invalid JSON value {constant}"
                )
            ),
        )
    except UnicodeDecodeError as exc:
        raise BuildContextError("REST response is not valid UTF-8") from exc
    except json.JSONDecodeError as exc:
        raise BuildContextError("REST response is not valid JSON") from exc
    if not isinstance(value, dict):
        raise BuildContextError("REST response must be a JSON object")
    return value


def build_run_url(api_url: str, repository: str, workflow_run_id: str) -> str:
    repository = validate_repository(repository)
    workflow_run_id = validate_positive_decimal(workflow_run_id, "workflow_run_id")
    if not isinstance(api_url, str) or api_url == "":
        raise BuildContextError("GITHUB_API_URL is required for REST resolution")
    if any(character.isspace() or ord(character) < 0x20 for character in api_url):
        raise BuildContextError("GITHUB_API_URL contains invalid characters")
    try:
        parsed = urllib.parse.urlsplit(api_url)
        port = parsed.port
    except ValueError as exc:
        raise BuildContextError("GITHUB_API_URL is invalid") from exc
    if (
        parsed.scheme != "https"
        or parsed.hostname is None
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or port is not None
        and not 1 <= port <= 65535
    ):
        raise BuildContextError("GITHUB_API_URL must be an HTTPS API base URL")
    owner, name = repository.split("/", 1)
    encoded_repository = "/".join(
        urllib.parse.quote(part, safe="") for part in (owner, name)
    )
    return (
        f"{api_url.rstrip('/')}/repos/{encoded_repository}/actions/runs/"
        f"{workflow_run_id}"
    )


def fetch_actions_run(
    *,
    api_url: str,
    repository: str,
    workflow_run_id: str,
    github_token: str,
    timeout: float = 30.0,
) -> Mapping[str, Any]:
    if not isinstance(github_token, str) or github_token == "":
        raise BuildContextError("GITHUB_TOKEN is required for REST resolution")
    if any(
        character.isspace() or ord(character) < 0x20 or ord(character) == 0x7F
        for character in github_token
    ):
        raise BuildContextError("GITHUB_TOKEN contains invalid characters")
    url = build_run_url(api_url, repository, workflow_run_id)
    request = urllib.request.Request(
        url,
        method="GET",
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {github_token}",
            "User-Agent": "floorp-runtime-build-context",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            if response.status != 200:
                raise BuildContextError(
                    f"Actions run REST request returned HTTP {response.status}"
                )
            data = response.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as exc:
        raise BuildContextError(
            f"Actions run REST request returned HTTP {exc.code}"
        ) from exc
    except urllib.error.URLError as exc:
        raise BuildContextError("Actions run REST request failed") from exc
    if len(data) > MAX_RESPONSE_BYTES:
        raise BuildContextError("Actions run REST response is too large")
    return parse_rest_json(data)


def validate_run_payload(
    payload: Mapping[str, Any],
    *,
    repository: str,
    workflow_run_id: str,
    head_sha: str,
    run_attempt: str,
) -> tuple[str, str]:
    if not isinstance(payload, Mapping):
        raise BuildContextError("REST response must be a JSON object")
    repository = validate_repository(repository)
    workflow_run_id = validate_positive_decimal(workflow_run_id, "workflow_run_id")
    head_sha = validate_head_sha(head_sha)
    run_attempt = validate_positive_decimal(run_attempt, "run_attempt")

    response_repository = payload.get("repository")
    if not isinstance(response_repository, dict):
        raise BuildContextError("REST repository must be an object")
    response_full_name = response_repository.get("full_name")
    if not isinstance(response_full_name, str):
        raise BuildContextError("REST repository.full_name must be a string")
    validate_repository(response_full_name)
    if response_full_name != repository:
        raise BuildContextError(
            "REST repository.full_name does not match GITHUB_REPOSITORY"
        )

    response_id = validate_positive_integer(payload.get("id"), "id")
    if str(response_id) != workflow_run_id:
        raise BuildContextError("REST id does not match GITHUB_RUN_ID")

    response_head_sha = payload.get("head_sha")
    if not isinstance(response_head_sha, str):
        raise BuildContextError("REST head_sha must be a string")
    validate_head_sha(response_head_sha)
    if response_head_sha != head_sha:
        raise BuildContextError("REST head_sha does not match GITHUB_SHA")

    response_created_at = payload.get("created_at")
    parse_created_at(response_created_at)

    response_run_attempt = validate_positive_integer(
        payload.get("run_attempt"), "run_attempt"
    )
    if str(response_run_attempt) != run_attempt:
        raise BuildContextError("REST run_attempt does not match GITHUB_RUN_ATTEMPT")

    return response_created_at, str(response_run_attempt)


def resolve_build_context(
    *,
    resolved_moz_build_date: str,
    requested_moz_build_date: str,
    require_run_metadata: bool,
    repository: str,
    head_sha: str,
    workflow_run_id: str,
    run_attempt: str,
    github_token: str,
    api_url: str,
    fetcher: Callable[..., Mapping[str, Any]] | None = None,
) -> BuildContext:
    resolved = validate_optional_build_id(
        resolved_moz_build_date, "resolved_moz_build_date"
    )
    requested = validate_optional_build_id(
        requested_moz_build_date, "requested_moz_build_date"
    )
    if resolved and requested and resolved != requested:
        raise BuildContextError(
            "resolved_moz_build_date conflicts with requested_moz_build_date"
        )

    repository = validate_repository(repository)
    head_sha = validate_head_sha(head_sha)
    workflow_run_id = validate_positive_decimal(workflow_run_id, "workflow_run_id")
    run_attempt = validate_positive_decimal(run_attempt, "run_attempt")

    if resolved and not require_run_metadata:
        return BuildContext(
            expected_build_id=resolved,
            repository=repository,
            head_sha=head_sha,
            workflow_run_id=workflow_run_id,
            run_created_at="",
            run_attempt=run_attempt,
        )

    active_fetcher = fetcher or fetch_actions_run
    payload = active_fetcher(
        api_url=api_url,
        repository=repository,
        workflow_run_id=workflow_run_id,
        github_token=github_token,
    )
    created_at, observed_run_attempt = validate_run_payload(
        payload,
        repository=repository,
        workflow_run_id=workflow_run_id,
        head_sha=head_sha,
        run_attempt=run_attempt,
    )
    expected_build_id = derive_build_id(created_at)
    for field, asserted_value in (
        ("resolved_moz_build_date", resolved),
        ("requested_moz_build_date", requested),
    ):
        if asserted_value and asserted_value != expected_build_id:
            raise BuildContextError(
                f"{field} does not match the build ID derived from REST created_at"
            )

    return BuildContext(
        expected_build_id=expected_build_id,
        repository=repository,
        head_sha=head_sha,
        workflow_run_id=workflow_run_id,
        run_created_at=created_at,
        run_attempt=observed_run_attempt,
    )


def write_github_output(path: str, context: BuildContext) -> None:
    if not isinstance(path, str) or path == "":
        raise BuildContextError("GITHUB_OUTPUT is required")
    outputs = context.as_outputs()
    for key, value in outputs.items():
        if "\n" in value or "\r" in value:
            raise BuildContextError(f"output {key} contains a line break")
    with Path(path).open("a", encoding="utf-8", newline="\n") as output_file:
        for key, value in outputs.items():
            output_file.write(f"{key}={value}\n")


def create_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Resolve a Floorp runtime build context"
    )
    parser.add_argument(
        "--resolved-moz-build-date",
        default=os.environ.get("RESOLVED_MOZ_BUILD_DATE", ""),
    )
    parser.add_argument(
        "--requested-moz-build-date",
        default=os.environ.get("REQUESTED_MOZ_BUILD_DATE", ""),
    )
    parser.add_argument(
        "--require-run-metadata",
        default=os.environ.get("REQUIRE_RUN_METADATA", "false"),
    )
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--head-sha", default=os.environ.get("GITHUB_SHA", ""))
    parser.add_argument(
        "--workflow-run-id", default=os.environ.get("GITHUB_RUN_ID", "")
    )
    parser.add_argument(
        "--run-attempt", default=os.environ.get("GITHUB_RUN_ATTEMPT", "")
    )
    parser.add_argument(
        "--api-url", default=os.environ.get("GITHUB_API_URL", "https://api.github.com")
    )
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT", ""))
    return parser


def main(argv: list[str] | None = None) -> int:
    args = create_argument_parser().parse_args(argv)
    try:
        context = resolve_build_context(
            resolved_moz_build_date=args.resolved_moz_build_date,
            requested_moz_build_date=args.requested_moz_build_date,
            require_run_metadata=parse_boolean(
                args.require_run_metadata, "require_run_metadata"
            ),
            repository=args.repository,
            head_sha=args.head_sha,
            workflow_run_id=args.workflow_run_id,
            run_attempt=args.run_attempt,
            github_token=os.environ.get("GITHUB_TOKEN", ""),
            api_url=args.api_url,
        )
        write_github_output(args.github_output, context)
    except (BuildContextError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(
        f"Resolved build context for {context.repository} run "
        f"{context.workflow_run_id} attempt {context.run_attempt}: "
        f"{context.expected_build_id}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
