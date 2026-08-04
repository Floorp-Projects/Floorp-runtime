#!/usr/bin/env python3

from __future__ import annotations

import json
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

import verify_linux_profile_paths as verifier

FAKE_BROWSER = r"""
#!/usr/bin/env python3
import os
import subprocess
import sys
import time
from pathlib import Path

MODE = __MODE__
arguments = sys.argv[1:]
if len(arguments) != 4 or arguments[:3] != ["--headless", "--no-remote", "--createprofile"]:
    print("unexpected command: " + repr(arguments), file=sys.stderr)
    raise SystemExit(9)

name = arguments[3]
home = Path(os.environ["HOME"])

def xdg_base(variable, fallback):
    value = os.environ.get(variable)
    if value and Path(value).is_absolute():
        return Path(value)
    return home / fallback

config_base = xdg_base("XDG_CONFIG_HOME", ".config")
cache_base = xdg_base("XDG_CACHE_HOME", ".cache")
legacy = (home / ".floorp").exists() or os.environ.get("MOZ_LEGACY_HOME", "").startswith("1")
config_root = home / ".floorp" if legacy else config_base / "floorp"
cache_root = cache_base / "floorp"
child = "abcdefgh." + name

config_profile = config_root / child
cache_profile = cache_root / child
config_profile.mkdir(parents=True, exist_ok=True)
targeted = name.endswith("fresh-default")
if not (MODE == "missing-cache" and targeted):
    cache_profile.mkdir(parents=True, exist_ok=True)
    (cache_profile / "cache-marker").write_text("cache", encoding="utf-8")
(config_profile / "profile-marker").write_text("profile", encoding="utf-8")

profile_path = "../escaped" if MODE == "escaping-profile" and targeted else child
(config_root / "profiles.ini").write_text(
    "[Profile0]\n"
    f"Name={name}\n"
    "IsRelative=1\n"
    f"Path={profile_path}\n"
    "\n"
    "[General]\n"
    "StartWithLastProfile=1\n"
    "Version=2\n",
    encoding="utf-8",
)

if MODE == "capital-write" and targeted:
    marker = home / "Floorp"
    marker.mkdir(exist_ok=True)
    (marker / "unexpected").write_text("bad", encoding="utf-8")
if MODE == "legacy-marker-write" and targeted:
    (home / ".floorp").mkdir(exist_ok=True)
if MODE == "capital-xdg-write" and targeted:
    (config_base / "Floorp").mkdir(parents=True, exist_ok=True)
    (cache_base / "Floorp").mkdir(parents=True, exist_ok=True)
if MODE == "error-log" and targeted:
    print("Error creating profile.", file=sys.stderr)
if MODE == "nonzero" and targeted:
    raise SystemExit(7)
if MODE == "hang" and targeted:
    marker = home / "child-signal.txt"
    child_code = '''
import signal
import sys
import time
from pathlib import Path
marker = Path(sys.argv[1])
def terminated(signum, frame):
    marker.write_text("terminated", encoding="utf-8")
    raise SystemExit(0)
signal.signal(signal.SIGTERM, terminated)
marker.write_text("ready", encoding="utf-8")
while True:
    time.sleep(1)
'''
    subprocess.Popen([sys.executable, "-c", child_code, str(marker)])
    deadline = time.monotonic() + 2
    while not marker.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    time.sleep(60)
print("created " + name)
"""


@unittest.skipUnless(sys.platform.startswith("linux"), "Linux-only verifier")
class LinuxProfilePathVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="floorp-2601-verifier-test-", dir="/tmp"
        )
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def make_browser(self, mode: str = "pass") -> Path:
        binary = self.root / f"fake-floorp-{mode}"
        source = textwrap.dedent(FAKE_BROWSER).replace("__MODE__", repr(mode)).lstrip()
        binary.write_text(source, encoding="utf-8", newline="\n")
        binary.chmod(0o755)
        return binary

    def run_matrix(self, mode: str = "pass") -> tuple[dict, Path, Path]:
        work = self.root / f"work-{mode}"
        results = self.root / f"results-{mode}.json"
        summary = verifier.run_verification(
            self.make_browser(mode), work, results, timeout=5
        )
        return summary, work, results

    def test_complete_matrix_passes_and_preserves_evidence(self) -> None:
        summary, work, results = self.run_matrix()

        self.assertTrue(summary["success"])
        self.assertEqual(summary["counts"], {"total": 8, "passed": 8, "failed": 0})
        self.assertEqual(json.loads(results.read_text(encoding="utf-8")), summary)
        self.assertEqual(
            [case["name"] for case in summary["cases"]],
            [spec.name for spec in verifier.CASES],
        )

        cases = {case["name"]: case for case in summary["cases"]}
        self.assertEqual(
            Path(cases["fresh-default"]["expected"]["config_root"]),
            work / "state" / "fresh-default" / "home" / ".config" / "floorp",
        )
        self.assertEqual(
            Path(cases["custom-xdg"]["expected"]["cache_root"]),
            work / "state" / "custom-xdg" / "xdg-cache" / "floorp",
        )
        self.assertEqual(
            Path(cases["forced-legacy-xdg-cache"]["expected"]["config_root"]),
            work / "state" / "forced-legacy-xdg-cache" / "home" / ".floorp",
        )
        self.assertEqual(
            Path(cases["forced-legacy-xdg-cache"]["expected"]["cache_root"]),
            work / "state" / "forced-legacy-xdg-cache" / "xdg-cache" / "floorp",
        )

        for case in summary["cases"]:
            self.assertEqual(case["status"], "passed")
            self.assertEqual(
                case["process"]["command"][1:4],
                ["--headless", "--no-remote", "--createprofile"],
            )
            self.assertFalse(case["process"]["timed_out"])
            self.assertEqual(case["process"]["return_code"], 0)
            self.assertEqual(
                Path(case["profile"]["config_profile"]).name,
                Path(case["profile"]["cache_profile"]).name,
            )
            for artifact in case["artifacts"].values():
                self.assertTrue(Path(artifact).is_file(), artifact)
            profiles_evidence = json.loads(
                Path(case["artifacts"]["profiles_ini"]).read_text(encoding="utf-8")
            )
            self.assertEqual(len(profiles_evidence["files"]), 1)
            self.assertIn(
                f"Name={case['profile_name']}",
                profiles_evidence["files"][0]["content"],
            )

    def test_missing_matching_cache_child_fails_only_target_case(self) -> None:
        summary, _, results = self.run_matrix("missing-cache")

        self.assertFalse(summary["success"])
        self.assertEqual(summary["counts"], {"total": 8, "passed": 7, "failed": 1})
        failed = [case for case in summary["cases"] if case["status"] == "failed"]
        self.assertEqual([case["name"] for case in failed], ["fresh-default"])
        self.assertIn("matching cache profile child is missing", failed[0]["errors"][0])
        self.assertFalse(json.loads(results.read_text(encoding="utf-8"))["success"])

    def test_zero_exit_with_create_profile_error_is_rejected(self) -> None:
        summary, _, _ = self.run_matrix("error-log")

        failed = [case for case in summary["cases"] if case["status"] == "failed"]
        self.assertEqual([case["name"] for case in failed], ["fresh-default"])
        self.assertEqual(failed[0]["process"]["return_code"], 0)
        self.assertIn("Error creating profile.", failed[0]["errors"][0])

    def test_unexpected_capital_floorp_creation_is_rejected(self) -> None:
        summary, _, _ = self.run_matrix("capital-write")

        failed = [case for case in summary["cases"] if case["status"] == "failed"]
        self.assertEqual([case["name"] for case in failed], ["fresh-default"])
        self.assertIn("unexpected ~/Floorp was created", failed[0]["errors"][0])

    def test_unexpected_legacy_marker_creation_is_rejected(self) -> None:
        summary, _, _ = self.run_matrix("legacy-marker-write")

        failed = [case for case in summary["cases"] if case["status"] == "failed"]
        self.assertEqual([case["name"] for case in failed], ["fresh-default"])
        self.assertIn("unexpected ~/.floorp", failed[0]["errors"][0])

    def test_unexpected_capitalized_xdg_sibling_is_rejected(self) -> None:
        summary, _, _ = self.run_matrix("capital-xdg-write")

        failed = [case for case in summary["cases"] if case["status"] == "failed"]
        self.assertEqual([case["name"] for case in failed], ["fresh-default"])
        self.assertIn("unexpected capitalized Floorp sibling", failed[0]["errors"][0])

    def test_escaping_profile_descriptor_is_rejected(self) -> None:
        summary, _, _ = self.run_matrix("escaping-profile")

        failed = [case for case in summary["cases"] if case["status"] == "failed"]
        self.assertEqual([case["name"] for case in failed], ["fresh-default"])
        self.assertIn("one direct child", failed[0]["errors"][0])

    def test_timeout_terminates_the_browser_process_group(self) -> None:
        work = self.root / "work-hang"
        results = self.root / "results-hang.json"
        summary = verifier.run_verification(
            self.make_browser("hang"), work, results, timeout=0.5
        )

        failed = [case for case in summary["cases"] if case["status"] == "failed"]
        self.assertEqual([case["name"] for case in failed], ["fresh-default"])
        self.assertTrue(failed[0]["process"]["timed_out"])
        self.assertEqual(
            (work / "state" / "fresh-default" / "home" / "child-signal.txt").read_text(
                encoding="utf-8"
            ),
            "terminated",
        )

    def test_cli_success_writes_machine_readable_summary(self) -> None:
        work = self.root / "cli-work"
        results = self.root / "cli-results.json"
        return_code = verifier.main([
            "--binary",
            str(self.make_browser()),
            "--work-dir",
            str(work),
            "--results-json",
            str(results),
            "--timeout",
            "5",
        ])

        self.assertEqual(return_code, 0)
        self.assertTrue(json.loads(results.read_text(encoding="utf-8"))["success"])

    def test_cli_rejects_mnt_backed_work_path_and_records_fatal_result(self) -> None:
        results = self.root / "mnt-fatal.json"
        return_code = verifier.main([
            "--binary",
            str(self.make_browser()),
            "--work-dir",
            "/mnt/c/floorp-2601-verifier-test",
            "--results-json",
            str(results),
        ])

        self.assertEqual(return_code, 2)
        fatal = json.loads(results.read_text(encoding="utf-8"))
        self.assertEqual(fatal["status"], "fatal")
        self.assertIn("not under /mnt", fatal["fatal_error"])

    def test_cli_rejects_relative_work_path(self) -> None:
        results = self.root / "relative-fatal.json"
        return_code = verifier.main([
            "--binary",
            str(self.make_browser()),
            "--work-dir",
            "relative-work",
            "--results-json",
            str(results),
        ])

        self.assertEqual(return_code, 2)
        fatal = json.loads(results.read_text(encoding="utf-8"))
        self.assertIn("must be absolute", fatal["fatal_error"])


if __name__ == "__main__":
    unittest.main()
