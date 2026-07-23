#!/usr/bin/env python3

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import verify_full_version as verifier


EXPECTED = "20260723010203"


class FullVersionParserTests(unittest.TestCase):
    def test_accepts_exact_adjacent_application_and_platform_ids(self) -> None:
        identity = verifier.verify_full_version(
            f"Floorp 153.0 {EXPECTED} {EXPECTED}, Mozilla\n", EXPECTED
        )
        self.assertEqual(identity.application_build_id, EXPECTED)
        self.assertEqual(identity.platform_build_id, EXPECTED)

    def test_accepts_line_break_as_adjacency(self) -> None:
        identity = verifier.verify_full_version(
            f"Floorp 153.0 {EXPECTED}\n{EXPECTED}\n", EXPECTED
        )
        self.assertEqual(identity.application_build_id, EXPECTED)

    def test_rejects_empty_or_missing_ids(self) -> None:
        for output in ("", "Floorp 153.0", f"Floorp 153.0 {EXPECTED}"):
            with self.subTest(output=output), self.assertRaises(
                verifier.FullVersionError
            ):
                verifier.verify_full_version(output, EXPECTED)

    def test_rejects_nonadjacent_ids(self) -> None:
        with self.assertRaisesRegex(verifier.FullVersionError, "adjacent"):
            verifier.verify_full_version(
                f"Floorp {EXPECTED} separator {EXPECTED}", EXPECTED
            )

    def test_rejects_extra_build_id(self) -> None:
        with self.assertRaisesRegex(verifier.FullVersionError, "exactly two"):
            verifier.verify_full_version(
                f"Floorp {EXPECTED} {EXPECTED} 20260723010204", EXPECTED
            )

    def test_rejects_application_or_platform_mismatch(self) -> None:
        for output in (
            f"Floorp 20260723010204 {EXPECTED}",
            f"Floorp {EXPECTED} 20260723010204",
        ):
            with self.subTest(output=output), self.assertRaises(
                verifier.FullVersionError
            ):
                verifier.verify_full_version(output, EXPECTED)

    def test_does_not_parse_ids_embedded_in_longer_numbers(self) -> None:
        with self.assertRaisesRegex(verifier.FullVersionError, "exactly two"):
            verifier.verify_full_version(
                f"Floorp 1{EXPECTED} {EXPECTED}", EXPECTED
            )

    def test_expected_build_id_is_strict_and_calendar_valid(self) -> None:
        for expected in ("", "20260230010203", "２０２６０７２３０１０２０３"):
            with self.subTest(expected=expected), self.assertRaises(
                verifier.FullVersionError
            ):
                verifier.verify_full_version(
                    f"Floorp {EXPECTED} {EXPECTED}", expected
                )

    def test_cli_reads_utf8_file_and_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "full-version.txt"
            output.write_text(
                f"Floorp 153.0 {EXPECTED} {EXPECTED}\n", encoding="utf-8"
            )
            self.assertEqual(
                verifier.main(
                    [
                        "--expected-build-id",
                        EXPECTED,
                        "--output-file",
                        str(output),
                    ]
                ),
                0,
            )
            output.write_text(f"Floorp {EXPECTED}\n", encoding="utf-8")
            self.assertEqual(
                verifier.main(
                    [
                        "--expected-build-id",
                        EXPECTED,
                        "--output-file",
                        str(output),
                    ]
                ),
                1,
            )

    def test_workflow_uses_immutable_download_and_static_app_data(self) -> None:
        workflow = (
            Path(__file__).resolve().parents[1] / "verify-runtime-artifact.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("source-workflow-run-id:", workflow)
        self.assertIn("if: inputs.source-workflow-run-id != ''", workflow)
        self.assertIn("github.rest.actions.getWorkflowRun", workflow)
        self.assertIn("github.rest.actions.listWorkflowRunArtifacts", workflow)
        self.assertIn('run.created_at.replace(/[-:TZ]/g, "")', workflow)
        self.assertIn("selected source artifact is expired", workflow)
        self.assertIn("artifact-ids: ${{ inputs.artifact-id }}", workflow)
        self.assertIn("merge-multiple: true", workflow)
        self.assertIn("run-id: ${{ inputs.source-workflow-run-id || github.run_id }}", workflow)
        self.assertIn("actions: read", workflow)
        self.assertIn("Environment.Remove('XUL_APP_FILE')", workflow)
        self.assertGreaterEqual(workflow.count("unset XUL_APP_FILE"), 2)
        self.assertIn("subprocess.run(", workflow)
        self.assertIn("timeout=30", workflow)
        self.assertNotIn('full_version="$("$app_binary" --full-version', workflow)
        self.assertNotIn(" -app ", workflow)


if __name__ == "__main__":
    unittest.main()
