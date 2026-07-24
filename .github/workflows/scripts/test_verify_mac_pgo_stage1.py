#!/usr/bin/env python3

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import verify_mac_pgo_stage1 as verifier

EXPECTED = "20260724044918"


class Stage1VerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name) / "stage 1 root"
        self.binary = self._create_app(self.root, "Floorp.app")

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _create_app(self, root: Path, name: str) -> Path:
        binary = root / name / "Contents" / "MacOS" / "floorp"
        resources = root / name / "Contents" / "Resources"
        binary.parent.mkdir(parents=True, exist_ok=True)
        resources.mkdir(parents=True, exist_ok=True)
        binary.write_bytes(b"stage1")
        (resources / "application.ini").write_text(
            f"[App]\nBuildID={EXPECTED}\nName=%PRODUCT%\n",
            encoding="utf-8",
        )
        (resources / "platform.ini").write_text(
            f"[Build]\nBuildID={EXPECTED}\n",
            encoding="utf-8",
        )
        return binary

    def _lipo(
        self,
        stdout: str = "x86_64\n",
        *,
        returncode: int = 0,
        stderr: str = "",
    ):
        def run(command, **kwargs):
            self.assertEqual(command[:2], [verifier.LIPO, "-archs"])
            self.assertFalse(kwargs.get("check"))
            self.assertTrue(kwargs.get("capture_output"))
            return subprocess.CompletedProcess(
                command,
                returncode,
                stdout=stdout,
                stderr=stderr,
            )

        return run

    def _verify(self, arch: str = "x86_64") -> verifier.Stage1Identity:
        return verifier.verify_stage1(
            self.root.parent,
            self.root,
            EXPECTED,
            arch,
            machine=arch,
            lipo_runner=self._lipo(f"{arch}\n"),
            executable_check=lambda _path, mode: mode == os.X_OK,
        )

    def test_accepts_x86_64_bundle_with_space_in_path(self) -> None:
        identity = self._verify()
        self.assertEqual(identity.binary, self.binary.resolve())
        self.assertEqual(identity.application_build_id, EXPECTED)
        self.assertEqual(identity.platform_build_id, EXPECTED)

    def test_accepts_arm64_runner_and_thin_slice(self) -> None:
        identity = self._verify("arm64")
        self.assertEqual(identity.runner_arch, "arm64")
        self.assertEqual(identity.binary_arch, "arm64")

    def test_rejects_invalid_expected_build_id(self) -> None:
        for build_id in ("", "20260230010203", "２０２６０７２４０４４９１８"):
            with self.subTest(build_id=build_id), self.assertRaises(
                verifier.Stage1VerificationError
            ):
                verifier.verify_stage1(
                    self.root.parent,
                    self.root,
                    build_id,
                    "x86_64",
                    machine="x86_64",
                    lipo_runner=self._lipo(),
                    executable_check=lambda _path, _mode: True,
                )

    def test_rejects_missing_or_multiple_direct_child_apps(self) -> None:
        self.binary.unlink()
        with self.assertRaisesRegex(verifier.Stage1VerificationError, "found 0"):
            self._verify()

        self.binary = self._create_app(self.root, "Floorp.app")
        self._create_app(self.root, "Other.app")
        with self.assertRaisesRegex(verifier.Stage1VerificationError, "found 2"):
            self._verify()

    def test_ignores_nested_app(self) -> None:
        self._create_app(self.root / "nested", "Nested.app")
        self.assertEqual(self._verify().binary, self.binary.resolve())

    def test_rejects_non_executable_binary(self) -> None:
        with self.assertRaisesRegex(verifier.Stage1VerificationError, "not executable"):
            verifier.verify_stage1(
                self.root.parent,
                self.root,
                EXPECTED,
                "x86_64",
                machine="x86_64",
                lipo_runner=self._lipo(),
                executable_check=lambda _path, _mode: False,
            )

    def test_rejects_path_outside_root(self) -> None:
        outside = self.root.parent / "outside" / "floorp"
        with self.assertRaisesRegex(verifier.Stage1VerificationError, "escapes"):
            verifier.require_within_root(self.root.resolve(), outside.resolve())

    def test_rejects_symlink_escape_when_supported(self) -> None:
        outside = self.root.parent / "outside-floorp"
        outside.write_bytes(b"outside")
        self.binary.unlink()
        try:
            self.binary.symlink_to(outside)
        except OSError as exc:
            self.skipTest(f"symlinks unavailable: {exc}")
        with self.assertRaisesRegex(
            verifier.Stage1VerificationError, "escapes|symlinks"
        ):
            self._verify()

    def test_rejects_symlinked_search_root_when_supported(self) -> None:
        linked_root = self.root.parent / "linked-root"
        try:
            linked_root.symlink_to(self.root, target_is_directory=True)
        except OSError as exc:
            self.skipTest(f"symlinks unavailable: {exc}")
        with self.assertRaisesRegex(verifier.Stage1VerificationError, "symlinks"):
            verifier.verify_stage1(
                self.root.parent,
                linked_root,
                EXPECTED,
                "x86_64",
                machine="x86_64",
                lipo_runner=self._lipo(),
                executable_check=lambda _path, _mode: True,
            )

    def test_rejects_symlinked_resource_file_when_supported(self) -> None:
        application_ini = self.binary.parent.parent / "Resources" / "application.ini"
        outside = self.root.parent / "outside-application.ini"
        outside.write_text(f"[App]\nBuildID={EXPECTED}\n", encoding="utf-8")
        application_ini.unlink()
        try:
            application_ini.symlink_to(outside)
        except OSError as exc:
            self.skipTest(f"symlinks unavailable: {exc}")
        with self.assertRaisesRegex(
            verifier.Stage1VerificationError, "escapes|symlinks"
        ):
            self._verify()

    def test_rejects_non_regular_resource_file(self) -> None:
        platform_ini = self.binary.parent.parent / "Resources" / "platform.ini"
        platform_ini.unlink()
        platform_ini.mkdir()
        with self.assertRaisesRegex(verifier.Stage1VerificationError, "not a regular"):
            self._verify()

    def test_rejects_wrong_or_unsupported_runner_arch(self) -> None:
        with self.assertRaisesRegex(verifier.Stage1VerificationError, "runner"):
            verifier.verify_stage1(
                self.root.parent,
                self.root,
                EXPECTED,
                "x86_64",
                machine="arm64",
                lipo_runner=self._lipo(),
                executable_check=lambda _path, _mode: True,
            )
        with self.assertRaisesRegex(verifier.Stage1VerificationError, "unsupported"):
            verifier.verify_stage1(
                self.root.parent,
                self.root,
                EXPECTED,
                "aarch64",
                machine="aarch64",
                lipo_runner=self._lipo("aarch64\n"),
                executable_check=lambda _path, _mode: True,
            )

    def test_rejects_lipo_failure_wrong_slice_and_multiple_slices(self) -> None:
        cases = (
            (self._lipo(returncode=1, stderr="invalid"), "exit code"),
            (self._lipo("arm64\n"), "mismatch"),
            (self._lipo("x86_64 arm64\n"), "exactly one"),
            (self._lipo(""), "exactly one"),
        )
        for lipo_runner, message in cases:
            with self.subTest(message=message), self.assertRaisesRegex(
                verifier.Stage1VerificationError, message
            ):
                verifier.verify_stage1(
                    self.root.parent,
                    self.root,
                    EXPECTED,
                    "x86_64",
                    machine="x86_64",
                    lipo_runner=lipo_runner,
                    executable_check=lambda _path, _mode: True,
                )

    def test_rejects_missing_lipo_program(self) -> None:
        def missing_lipo(_command, **_kwargs):
            raise FileNotFoundError(verifier.LIPO)

        with self.assertRaisesRegex(verifier.Stage1VerificationError, "inspect"):
            verifier.verify_stage1(
                self.root.parent,
                self.root,
                EXPECTED,
                "x86_64",
                machine="x86_64",
                lipo_runner=missing_lipo,
                executable_check=lambda _path, _mode: True,
            )

    def test_rejects_missing_or_malformed_ini(self) -> None:
        application_ini = self.binary.parent.parent / "Resources" / "application.ini"
        application_ini.unlink()
        with self.assertRaisesRegex(
            verifier.Stage1VerificationError, "could not resolve"
        ):
            self._verify()

        application_ini.write_text("not-an-ini\n", encoding="utf-8")
        with self.assertRaisesRegex(
            verifier.Stage1VerificationError, "could not parse"
        ):
            self._verify()

    def test_rejects_duplicate_section_or_option(self) -> None:
        application_ini = self.binary.parent.parent / "Resources" / "application.ini"
        for contents in (
            f"[App]\nBuildID={EXPECTED}\n[App]\nName=Floorp\n",
            f"[App]\nBuildID={EXPECTED}\nBuildID={EXPECTED}\n",
        ):
            application_ini.write_text(contents, encoding="utf-8")
            with self.subTest(contents=contents), self.assertRaisesRegex(
                verifier.Stage1VerificationError, "could not parse"
            ):
                self._verify()

    def test_rejects_missing_or_mismatched_ini_build_id(self) -> None:
        resources = self.binary.parent.parent / "Resources"
        application_ini = resources / "application.ini"
        platform_ini = resources / "platform.ini"

        application_ini.write_text("[App]\nName=Floorp\n", encoding="utf-8")
        with self.assertRaisesRegex(verifier.Stage1VerificationError, "missing"):
            self._verify()

        application_ini.write_text(f"[App]\nBuildID={EXPECTED}\n", encoding="utf-8")
        platform_ini.write_text("[Build]\nBuildID=20260724044919\n", encoding="utf-8")
        with self.assertRaisesRegex(verifier.Stage1VerificationError, "mismatch"):
            self._verify()

    def test_writes_exact_output_and_rejects_line_breaks(self) -> None:
        output = Path(self.temporary_directory.name) / "github-output"
        verifier.write_github_output(
            output,
            "app_binary",
            str(self.binary.resolve()),
        )
        self.assertEqual(
            output.read_text(encoding="utf-8"),
            f"app_binary={self.binary.resolve()}\n",
        )
        for value in ("bad\npath", "bad\rpath"):
            with self.subTest(value=value), self.assertRaisesRegex(
                verifier.Stage1VerificationError, "line break"
            ):
                verifier.write_github_output(output, "app_binary", value)

    def test_workflow_preserves_proof_chain(self) -> None:
        workflow = (Path(__file__).resolve().parents[1] / "mac_pgo.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("id: verify_stage1", workflow)
        self.assertIn("verify_mac_pgo_stage1.py", workflow)
        self.assertIn('--workspace-root "$GITHUB_WORKSPACE"', workflow)
        self.assertIn('--expected-arch "${{ matrix.runner-arch }}"', workflow)
        self.assertIn('--github-output "$GITHUB_OUTPUT"', workflow)
        self.assertNotIn("--full-version", workflow)
        self.assertIn(
            "STAGE1_APP_BINARY: ${{ steps.verify_stage1.outputs.app_binary }}",
            workflow,
        )
        self.assertIn('profileserver.py --binary "$STAGE1_APP_BINARY"', workflow)
        self.assertIn('if ! test -s "$output"', workflow)
        self.assertIn('echo "$output byte_size=$bytes"', workflow)


if __name__ == "__main__":
    unittest.main()
