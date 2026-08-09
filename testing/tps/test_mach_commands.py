# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

import importlib.util
import os
import shutil
import subprocess
import tempfile
import unittest

from mach.registrar import Registrar

if "testing" not in Registrar.categories:
    Registrar.register_category("testing", "Testing", "Run tests", 60)

MODULE_PATH = os.path.join(os.path.dirname(__file__), "mach_commands.py")
SPEC = importlib.util.spec_from_file_location("tps_mach_commands", MODULE_PATH)
TPS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TPS)


class FakeProfile:
    def __init__(self):
        self.preferences = []

    def set_preferences(self, preferences):
        self.preferences.append(preferences)


class FakeRunner:
    wait_result = 0
    instances = []

    def __init__(self, **kwargs):
        self.kwargs = kwargs
        self.started = False
        self.stop_calls = 0
        type(self).instances.append(self)

    def start(self, timeout=None):
        self.started = True
        self.start_timeout = timeout

    def wait(self, timeout):
        self.wait_timeout = timeout
        return type(self).wait_result

    def stop(self):
        self.stop_calls += 1


class FakeMarionette:
    instances = []

    def __init__(self, **kwargs):
        self.kwargs = kwargs
        self.started = False
        self.deleted = False
        type(self).instances.append(self)

    def start_session(self, timeout):
        self.started = True
        self.start_timeout = timeout

    def delete_session(self):
        self.deleted = True


class FakeAddons:
    logfile = None
    phase_status = None
    installs = []

    def __init__(self, marionette):
        self.marionette = marionette

    def install(self, path, temp):
        type(self).installs.append((path, temp))
        with open(type(self).logfile, "a") as log:
            log.write("TPS INFO | Sync version: test\n")
            if type(self).phase_status:
                log.write(f"2026-01-01 test phase phase1: {type(self).phase_status}\n")
        return "tps@mozilla.org"


class RunTPSPhaseTests(unittest.TestCase):
    def setUp(self):
        FakeRunner.instances.clear()
        FakeRunner.wait_result = 0
        FakeMarionette.instances.clear()
        FakeAddons.installs.clear()
        FakeAddons.phase_status = None

    def run_phase(self, logfile):
        FakeAddons.logfile = logfile
        with open(logfile, "w") as log:
            log.write("Running test test_floorp_notes.js\n")
        return TPS._run_tps_phase(
            profile=FakeProfile(),
            current_testfile="/tmp/test_floorp_notes.js",
            phase_name="phase1",
            testname="test_floorp_notes.js",
            logfile=logfile,
            binary="/tmp/firefox",
            env={},
            tps_xpi="/tmp/tps.xpi",
            phase_timeout=17,
            startup_timeout=3,
            marionette_port=2828,
            runner_cls=FakeRunner,
            marionette_cls=FakeMarionette,
            addons_cls=FakeAddons,
        )

    def test_installs_tps_as_temporary_addon_and_returns_phase_status(self):
        FakeAddons.phase_status = "PASS"
        with tempfile.TemporaryDirectory() as tempdir:
            status, error = self.run_phase(os.path.join(tempdir, "tps.log"))

        self.assertEqual((status, error), ("PASS", None))
        self.assertEqual(FakeAddons.installs, [("/tmp/tps.xpi", True)])
        runner = FakeRunner.instances[0]
        self.assertIn("-marionette", runner.kwargs["cmdargs"])
        self.assertIn("-remote-allow-system-access", runner.kwargs["cmdargs"])
        self.assertTrue(FakeMarionette.instances[0].started)

    def test_stops_runner_when_phase_wait_times_out(self):
        FakeRunner.wait_result = None
        with tempfile.TemporaryDirectory() as tempdir:
            status, error = self.run_phase(os.path.join(tempdir, "tps.log"))

        self.assertEqual(status, "FAIL")
        self.assertIn("timed out after 17 seconds", error)
        self.assertGreaterEqual(FakeRunner.instances[0].stop_calls, 1)

    def test_rejects_nonpositive_timeout_before_starting_firefox(self):
        status, error = TPS._run_tps_phase(
            profile=FakeProfile(),
            current_testfile="/tmp/test_floorp_notes.js",
            phase_name="phase1",
            testname="test_floorp_notes.js",
            logfile="/tmp/tps.log",
            binary="/tmp/firefox",
            env={},
            tps_xpi="/tmp/tps.xpi",
            phase_timeout=0,
            marionette_port=2828,
            runner_cls=FakeRunner,
            marionette_cls=FakeMarionette,
            addons_cls=FakeAddons,
        )

        self.assertEqual(status, "FAIL")
        self.assertIn("must be greater than zero", error)
        self.assertEqual(FakeRunner.instances, [])

    def test_phase_timeout_is_an_overall_deadline(self):
        class FakeClock:
            now = 0.0

            def __call__(self):
                return self.now

        clock = FakeClock()

        class BudgetRunner(FakeRunner):
            def start(self, timeout=None):
                super().start(timeout=timeout)
                clock.now += 2

        class BudgetMarionette(FakeMarionette):
            def start_session(self, timeout):
                super().start_session(timeout)
                clock.now += 3

        class BudgetAddons(FakeAddons):
            def install(self, path, temp):
                result = super().install(path, temp)
                clock.now += 4
                return result

        def startup_waiter(_logfile, timeout):
            self.assertLessEqual(timeout, 3)
            clock.now += 1
            return True

        FakeAddons.phase_status = "PASS"
        with tempfile.TemporaryDirectory() as tempdir:
            logfile = os.path.join(tempdir, "tps.log")
            FakeAddons.logfile = logfile
            with open(logfile, "w") as log:
                log.write("Running test test_floorp_notes.js\n")
            status, error = TPS._run_tps_phase(
                profile=FakeProfile(),
                current_testfile="/tmp/test_floorp_notes.js",
                phase_name="phase1",
                testname="test_floorp_notes.js",
                logfile=logfile,
                binary="/tmp/firefox",
                env={},
                tps_xpi="/tmp/tps.xpi",
                phase_timeout=12,
                startup_timeout=5,
                marionette_port=2828,
                runner_cls=BudgetRunner,
                marionette_cls=BudgetMarionette,
                addons_cls=BudgetAddons,
                monotonic=clock,
                startup_waiter=startup_waiter,
            )

        self.assertEqual((status, error), ("PASS", None))
        self.assertGreater(BudgetRunner.instances[0].start_timeout, 0)
        self.assertLessEqual(BudgetRunner.instances[0].start_timeout, 12)
        self.assertGreater(BudgetMarionette.instances[0].socket_timeout, 0)
        self.assertLessEqual(BudgetMarionette.instances[0].socket_timeout, 7)
        self.assertGreater(BudgetRunner.instances[0].wait_timeout, 0)
        self.assertLessEqual(BudgetRunner.instances[0].wait_timeout, 2)

    def test_deadline_exhausted_during_start_stops_before_marionette(self):
        class FakeClock:
            now = 0.0

            def __call__(self):
                return self.now

        clock = FakeClock()

        class SlowStartRunner(FakeRunner):
            def start(self, timeout=None):
                super().start(timeout=timeout)
                clock.now = 6

        with tempfile.TemporaryDirectory() as tempdir:
            logfile = os.path.join(tempdir, "tps.log")
            with open(logfile, "w") as log:
                log.write("Running test test_floorp_notes.js\n")
            status, error = TPS._run_tps_phase(
                profile=FakeProfile(),
                current_testfile="/tmp/test_floorp_notes.js",
                phase_name="phase1",
                testname="test_floorp_notes.js",
                logfile=logfile,
                binary="/tmp/firefox",
                env={},
                tps_xpi="/tmp/tps.xpi",
                phase_timeout=5,
                startup_timeout=3,
                marionette_port=2828,
                runner_cls=SlowStartRunner,
                marionette_cls=FakeMarionette,
                addons_cls=FakeAddons,
                monotonic=clock,
            )

        self.assertEqual(status, "FAIL")
        self.assertIn("during Marionette startup", error)
        self.assertEqual(FakeMarionette.instances, [])
        self.assertGreaterEqual(SlowStartRunner.instances[0].stop_calls, 1)

    def test_cleanup_phase_uses_short_oauth_timeout(self):
        FakeAddons.phase_status = "PASS"
        profile = FakeProfile()
        with tempfile.TemporaryDirectory() as tempdir:
            logfile = os.path.join(tempdir, "tps.log")
            FakeAddons.logfile = logfile
            with open(logfile, "w") as log:
                log.write("Running test test_floorp_notes.js\n")
            status, error = TPS._run_tps_phase(
                profile=profile,
                current_testfile="/tmp/test_floorp_notes.js",
                phase_name="phase1",
                testname="test_floorp_notes.js",
                logfile=logfile,
                binary="/tmp/firefox",
                env={},
                tps_xpi="/tmp/tps.xpi",
                phase_timeout=TPS.TPS_CLEANUP_TIMEOUT_SECONDS,
                startup_timeout=3,
                marionette_port=2828,
                runner_cls=FakeRunner,
                marionette_cls=FakeMarionette,
                addons_cls=FakeAddons,
            )

        self.assertEqual((status, error), ("PASS", None))
        self.assertEqual(profile.preferences[-1]["testing.tps.oauthTimeoutMs"], 30000)


class PhaseTimeoutPolicyTests(unittest.TestCase):
    def test_oauth_timeout_reserves_phase_shutdown_margin(self):
        self.assertEqual(TPS._oauth_timeout_for_phase(600), 300000)
        self.assertEqual(TPS._oauth_timeout_for_phase(60), 30000)
        for phase_timeout in (60, 300, 600):
            self.assertLess(
                TPS._oauth_timeout_for_phase(phase_timeout), phase_timeout * 1000
            )


class RemoteCleanupPhaseTests(unittest.TestCase):
    def test_skips_remote_cleanup_without_a_successful_phase(self):
        calls = []

        def phase_runner(
            profile,
            current_testfile,
            phase_name,
            testname,
            logfile,
            binary,
            env,
            tps_xpi,
            **kwargs,
        ):
            calls.append((profile, phase_name, kwargs["phase_timeout"]))
            return "PASS", None

        profiles = {"failed": FakeProfile(), "passed": FakeProfile()}
        failed = TPS._run_tps_cleanup_phases(
            profiles=profiles,
            used_profiles={"failed", "passed"},
            successful_profiles={"passed"},
            current_testfile="/tmp/test_floorp_notes.js",
            testname="test_floorp_notes.js",
            logfile="/tmp/tps.log",
            binary="/tmp/firefox",
            env={},
            tps_xpi="/tmp/tps.xpi",
            phase_runner=phase_runner,
        )

        self.assertFalse(failed)
        self.assertEqual(
            calls,
            [(profiles["passed"], "cleanup-passed", TPS.TPS_CLEANUP_TIMEOUT_SECONDS)],
        )


class ResolveCredentialsTests(unittest.TestCase):
    def test_reads_complete_credentials_from_environment(self):
        username, password = TPS._resolve_fxa_credentials(
            None,
            None,
            {
                "TPS_FXA_USERNAME": "qa@example.test",
                "TPS_FXA_PASSWORD": "secret",
            },
        )

        self.assertEqual(username, "qa@example.test")
        self.assertEqual(password, "secret")

    def test_rejects_partial_environment_credentials(self):
        with self.assertRaisesRegex(ValueError, "must both be set"):
            TPS._resolve_fxa_credentials(
                None,
                None,
                {"TPS_FXA_USERNAME": "qa@example.test"},
            )

    def test_rejects_mixed_argument_and_environment_credentials(self):
        with self.assertRaisesRegex(ValueError, "must not be mixed"):
            TPS._resolve_fxa_credentials(
                "qa@example.test",
                "argument-secret",
                {
                    "TPS_FXA_USERNAME": "qa@example.test",
                    "TPS_FXA_PASSWORD": "environment-secret",
                },
            )

    def test_rejects_argument_credentials_for_production(self):
        with self.assertRaisesRegex(ValueError, "production.*environment"):
            TPS._resolve_fxa_credentials(
                "qa@example.test",
                "argument-secret",
                {},
                allow_argument_credentials=False,
            )


class ResolveFxaCiTokenTests(unittest.TestCase):
    def test_returns_token_for_staging(self):
        self.assertEqual(
            TPS._resolve_fxa_ci_token(
                {"TPS_FXA_CI_TOKEN": "stage-token"}, fxa_staging=True
            ),
            "stage-token",
        )

    def test_discards_token_for_production(self):
        self.assertIsNone(
            TPS._resolve_fxa_ci_token(
                {"TPS_FXA_CI_TOKEN": "stage-token"}, fxa_staging=False
            )
        )


class ProductionBoundaryTests(unittest.TestCase):
    def test_disables_webdriver_recommended_offline_preferences(self):
        self.assertFalse(TPS.TPS_PREFERENCES["remote.prefs.recommended"])

    def test_allows_time_for_manual_production_challenge(self):
        self.assertEqual(TPS.TPS_PREFERENCES["testing.tps.oauthTimeoutMs"], 300000)

    def test_production_preferences_and_child_environment_exclude_secrets(self):
        preferences = TPS._prepare_tps_preferences(
            {"fx_account": {"username": "qa@example.test"}},
            fxa_ci_token=None,
            debug=False,
        )
        self.assertNotIn("tps.fxa.bypassToken", preferences)

        environment = TPS._prepare_tps_environment(
            {
                "TPS_FXA_USERNAME": "qa@example.test",
                "TPS_FXA_PASSWORD": "secret",
                "TPS_FXA_CI_TOKEN": "stage-token",
                "UNRELATED": "retained",
            },
            "/tmp/source",
            platform_name="linux",
        )
        self.assertEqual(environment["UNRELATED"], "retained")
        self.assertNotIn("TPS_FXA_USERNAME", environment)
        self.assertNotIn("TPS_FXA_PASSWORD", environment)
        self.assertNotIn("TPS_FXA_CI_TOKEN", environment)


class CleanupResourcesTests(unittest.TestCase):
    def test_continues_profile_cleanup_and_always_stops_server(self):
        events = []

        class Profile:
            def __init__(self, name, should_fail=False):
                self.name = name
                self.should_fail = should_fail

            def cleanup(self):
                events.append(f"cleanup:{self.name}")
                if self.should_fail:
                    raise RuntimeError("cleanup failed")

        class Server:
            def stop(self):
                events.append("server:stop")

        succeeded = TPS._cleanup_tps_resources(
            [Profile("first", should_fail=True), Profile("second")], Server()
        )

        self.assertFalse(succeeded)
        self.assertEqual(events, ["cleanup:first", "cleanup:second", "server:stop"])


class AutofillActorTests(unittest.TestCase):
    def test_two_step_disabled_submit_and_headless_visibility(self):
        node = shutil.which("node")
        self.assertIsNotNone(node, "Node.js is required for the actor test")
        test_dir = os.path.dirname(__file__)
        actor = os.path.join(
            test_dir,
            "..",
            "..",
            "services",
            "sync",
            "tps",
            "extensions",
            "tps",
            "resource",
            "actors",
            "fxaAutofillChild.sys.mjs",
        )
        subprocess.run(
            [node, os.path.join(test_dir, "test_fxa_autofill_actor.js"), actor],
            check=True,
            capture_output=True,
            text=True,
        )


if __name__ == "__main__":
    unittest.main()
