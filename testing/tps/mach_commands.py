# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.


import json
import os
import re
import socket
import sys
import time

from mach.decorators import Command, CommandArgument
from mozpack.copier import Jarrer
from mozpack.files import FileFinder

PHASE_TIMEOUT_SECONDS = 600
TPS_STARTUP_TIMEOUT_SECONDS = 30
TPS_CLEANUP_TIMEOUT_SECONDS = 60
TPS_OAUTH_TIMEOUT_MS = 300000
TPS_PHASE_SHUTDOWN_MARGIN_SECONDS = 30
TPS_ENV = {
    "MOZ_CRASHREPORTER_DISABLE": "1",
    "GNOME_DISABLE_CRASH_DIALOG": "1",
    "XRE_NO_WINDOWS_CRASH_DIALOG": "1",
    "XPCOM_DEBUG_BREAK": "warn",
}
TPS_PREFERENCES = {
    "app.update.checkInstallTime": False,
    "app.update.disabledForTesting": True,
    "security.turn_off_all_security_so_that_viruses_can_take_over_this_computer": True,
    "browser.dom.window.dump.enabled": True,
    "devtools.console.stdout.chrome": True,
    "browser.sessionstore.resume_from_crash": False,
    "browser.shell.checkDefaultBrowser": False,
    "browser.tabs.warnOnClose": False,
    "browser.warnOnQuit": False,
    "extensions.autoDisableScopes": 10,
    "extensions.getAddons.get.url": "http://127.0.0.1:4567/addons/api/%IDS%.json",
    "extensions.getAddons.cache.enabled": False,
    "extensions.install.requireSecureOrigin": False,
    "extensions.update.enabled": False,
    "extensions.update.notifyUser": False,
    "services.sync.firstSync": "notReady",
    "services.sync.lastversion": "1.0",
    "toolkit.startup.max_resumed_crashes": -1,
    "xpinstall.signatures.required": False,
    "services.sync.testing.tps": True,
    "services.sync.engine.tabs.filteredSchemes": "about|resource|chrome|file|blob|moz-extension",
    "engine.bookmarks.repair.enabled": False,
    "extensions.experiments.enabled": True,
    "webextensions.storage.sync.kinto": False,
    # Marionette's generic recommended prefs redirect FxA to a dummy host.
    # TPS exercises real FxA/Sync endpoints, so preserve this profile's URLs.
    "remote.prefs.recommended": False,
    "testing.tps.oauthTimeoutMs": TPS_OAUTH_TIMEOUT_MS,
}
TPS_DEBUG_PREFERENCES = {
    "services.sync.log.appender.console": "Trace",
    "services.sync.log.appender.dump": "Trace",
    "services.sync.log.appender.file.level": "Trace",
    "services.sync.log.appender.file.logOnSuccess": True,
    "services.sync.log.logger": "Trace",
    "services.sync.log.logger.engine": "Trace",
}


def _build_tps_xpi(command_context, dest=None):
    """Internal helper to build TPS XPI and return the path."""
    src = os.path.join(
        command_context.topsrcdir, "services", "sync", "tps", "extensions", "tps"
    )
    dest = os.path.join(
        dest or os.path.join(command_context.topobjdir, "services", "sync"),
        "tps.xpi",
    )

    if not os.path.exists(os.path.dirname(dest)):
        os.makedirs(os.path.dirname(dest))

    if os.path.isfile(dest):
        os.unlink(dest)

    jarrer = Jarrer()
    for p, f in FileFinder(src).find("*"):
        jarrer.add(p, f)
    jarrer.copy(dest)

    return dest


@Command("tps-build", category="testing", description="Build TPS add-on.")
@CommandArgument("--dest", default=None, help="Where to write add-on.")
def build(command_context, dest):
    dest_path = _build_tps_xpi(command_context, dest)
    print(f"Built TPS add-on as {dest_path}")
    return 0


def _resolve_test_target(topsrcdir, testfile):
    if testfile:
        return os.path.abspath(os.path.join(topsrcdir, testfile))
    return os.path.join(topsrcdir, "services", "sync", "tests", "tps", "all_tests.json")


def _load_test_list(test_target):
    if not os.path.exists(test_target):
        raise FileNotFoundError(f"Test file not found: {test_target}")

    if test_target.endswith(".json"):
        with open(test_target) as f:
            test_config = json.load(f)
        tests = test_config.get("tests")
        if not isinstance(tests, dict):
            raise ValueError(
                f"Invalid TPS test config (missing tests object): {test_target}"
            )
        test_dir = os.path.dirname(test_target)
        test_files = []
        for filename, meta in tests.items():
            test_meta = meta or {}
            if test_meta.get("disabled"):
                print(f"Skipping test {filename} - {test_meta['disabled']}")
                continue
            test_path = os.path.join(test_dir, filename)
            if not os.path.exists(test_path):
                raise FileNotFoundError(f"Test file not found: {test_path}")
            test_files.append(test_path)
        return test_files

    return [test_target]


def _load_test_phases(testfile):
    import yaml

    with open(testfile) as f:
        testcontent = f.read()

    phases_match = re.search(r"\b(?:var|let|const)\s+phases\s*=\s*\{", testcontent)
    if not phases_match:
        raise ValueError(f"Could not find 'var phases' definition in {testfile}")
    phases_start = phases_match.end() - 1
    phases_end = testcontent.find("};", phases_start)
    if phases_end == -1:
        raise ValueError(f"Could not parse phases block in {testfile}")
    phases_str = testcontent[phases_start : phases_end + 1]
    return yaml.safe_load(phases_str)


def _resolve_fxa_credentials(
    username, password, environ, *, allow_argument_credentials=True
):
    env_username = environ.get("TPS_FXA_USERNAME")
    env_password = environ.get("TPS_FXA_PASSWORD")
    argument_credentials = bool(username or password)
    environment_credentials = bool(env_username or env_password)

    if argument_credentials and environment_credentials:
        raise ValueError(
            "FxA argument credentials and environment credentials must not be mixed"
        )
    if argument_credentials:
        if not allow_argument_credentials:
            raise ValueError(
                "FxA production credentials must be supplied through the environment"
            )
        if not username or not password:
            raise ValueError("--username and --password must both be set")
        return username, password
    if environment_credentials:
        if not env_username or not env_password:
            raise ValueError("TPS_FXA_USERNAME and TPS_FXA_PASSWORD must both be set")
        return env_username, env_password
    raise ValueError(
        "Either --auto-account, --username with --password, or "
        "TPS_FXA_USERNAME with TPS_FXA_PASSWORD is required"
    )


def _resolve_fxa_ci_token(environ, *, fxa_staging):
    if not fxa_staging:
        return None
    return environ.get("TPS_FXA_CI_TOKEN")


def _prepare_tps_preferences(config, *, fxa_ci_token, debug):
    preferences = TPS_PREFERENCES.copy()
    preferences["tps.config"] = json.dumps(config)
    if fxa_ci_token:
        preferences["tps.fxa.bypassToken"] = fxa_ci_token
    if debug:
        preferences.update(TPS_DEBUG_PREFERENCES)
    return preferences


def _prepare_tps_environment(environ, topsrcdir, *, platform_name=None):
    env = environ.copy()
    env.pop("TPS_FXA_USERNAME", None)
    env.pop("TPS_FXA_PASSWORD", None)
    env.pop("TPS_FXA_CI_TOKEN", None)
    env.update(TPS_ENV)
    if (platform_name or sys.platform) == "darwin":
        env["MOZ_DEVELOPER_REPO_DIR"] = os.path.abspath(topsrcdir)
    return env


def _cleanup_tps_resources(profiles, addon_server):
    succeeded = True
    try:
        for profile in profiles:
            try:
                profile.cleanup()
            except Exception as error:
                succeeded = False
                print(f"ERROR: Failed to clean up TPS profile: {error}")
    finally:
        addon_server.stop()
    return succeeded


def _extract_phase_status(logfile, testname, phase_name):
    found_test = False

    if os.path.exists(logfile):
        with open(logfile) as f:
            for line in f:
                if not found_test:
                    if f"Running test {testname}" in line:
                        found_test = True
                    continue

                match = re.match(
                    r"^(.*?)test phase (?P<phase>[^\s]+): (?P<status>.*)$",
                    line,
                )
                if match and match.group("phase") == phase_name:
                    return match.group("status"), None

                if "CROSSWEAVE ERROR: " in line:
                    return "FAIL", line.split("CROSSWEAVE ERROR: ")[1].strip()

    return None, None


def _allocate_marionette_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def _wait_for_tps_startup(logfile, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(logfile):
            with open(logfile) as log:
                if "Sync version:" in log.read():
                    return True
        time.sleep(0.1)
    return False


def _oauth_timeout_for_phase(phase_timeout):
    if phase_timeout <= 0:
        raise ValueError("TPS phase timeout must be greater than zero")
    shutdown_margin = min(TPS_PHASE_SHUTDOWN_MARGIN_SECONDS, phase_timeout / 2)
    available_ms = max(1, int((phase_timeout - shutdown_margin) * 1000))
    return min(TPS_OAUTH_TIMEOUT_MS, available_ms)


def _run_tps_phase(
    profile,
    current_testfile,
    phase_name,
    testname,
    logfile,
    binary,
    env,
    tps_xpi,
    phase_timeout=PHASE_TIMEOUT_SECONDS,
    startup_timeout=TPS_STARTUP_TIMEOUT_SECONDS,
    marionette_port=None,
    runner_cls=None,
    marionette_cls=None,
    addons_cls=None,
    monotonic=time.monotonic,
    startup_waiter=_wait_for_tps_startup,
):
    if runner_cls is None:
        from mozrunner import FirefoxRunner

        runner_cls = FirefoxRunner
    if marionette_cls is None:
        from marionette_driver.marionette import Marionette

        marionette_cls = Marionette
    if addons_cls is None:
        from marionette_driver.addons import Addons

        addons_cls = Addons

    try:
        oauth_timeout_ms = _oauth_timeout_for_phase(phase_timeout)
    except ValueError as error:
        return "FAIL", f"invalid TPS phase timeout: {error}"

    deadline = monotonic() + phase_timeout

    def remaining(stage):
        seconds = deadline - monotonic()
        if seconds <= 0:
            raise TimeoutError(
                f"TPS phase timed out after {phase_timeout} seconds during {stage}"
            )
        return seconds

    port = marionette_port or _allocate_marionette_port()
    profile.set_preferences({
        "testing.tps.testFile": current_testfile,
        "testing.tps.testPhase": phase_name,
        "testing.tps.logFile": logfile,
        "testing.tps.ignoreUnusedEngines": False,
        "testing.tps.oauthTimeoutMs": oauth_timeout_ms,
        "marionette.port": port,
    })

    runner = runner_cls(
        binary=binary,
        profile=profile,
        env=env,
        cmdargs=["-marionette", "-remote-allow-system-access"],
        process_args=[],
    )
    marionette = None
    try:
        runner.start(timeout=remaining("Firefox startup"))
        session_timeout = min(startup_timeout, remaining("Marionette startup"))
        marionette = marionette_cls(
            host="127.0.0.1",
            port=port,
            startup_timeout=session_timeout,
            socket_timeout=remaining("Marionette connection"),
        )
        marionette.start_session(timeout=session_timeout)
        install_timeout = remaining("TPS add-on installation")
        marionette.socket_timeout = install_timeout
        if getattr(marionette, "client", None) is not None:
            marionette.client.socket_timeout = install_timeout
        addon_id = addons_cls(marionette).install(tps_xpi, temp=True)
        if addon_id != "tps@mozilla.org":
            return "FAIL", f"temporary TPS add-on returned unexpected id: {addon_id}"
        startup_wait_timeout = min(startup_timeout, remaining("TPS add-on startup"))
        if not startup_waiter(logfile, startup_wait_timeout):
            return "FAIL", (
                f"TPS add-on did not start within {startup_wait_timeout:g} seconds"
            )

        process_wait_timeout = remaining("TPS process completion")
        returncode = runner.wait(timeout=process_wait_timeout)
        if returncode is None:
            runner.stop()
            return "FAIL", f"TPS phase timed out after {phase_timeout} seconds"
        return _extract_phase_status(logfile, testname, phase_name)
    except TimeoutError as error:
        return "FAIL", str(error)
    except Exception as error:
        return "FAIL", f"phase execution failed: {error}"
    finally:
        if marionette is not None:
            try:
                marionette.delete_session()
            except Exception:
                pass
        runner.stop()


def _run_tps_cleanup_phases(
    *,
    profiles,
    used_profiles,
    successful_profiles,
    current_testfile,
    testname,
    logfile,
    binary,
    env,
    tps_xpi,
    phase_runner=None,
):
    if phase_runner is None:
        phase_runner = _run_tps_phase

    cleanup_failed = False
    print("Running cleanup phases...")
    for profile_name in sorted(used_profiles):
        if profile_name not in successful_profiles:
            print(f"Cleanup: {profile_name} (skipped; no successful phase)")
            continue

        profile = profiles[profile_name]
        cleanup_phase = f"cleanup-{profile_name}"
        print(f"Cleanup: {profile_name}")
        status, error_line = phase_runner(
            profile,
            current_testfile,
            cleanup_phase,
            testname,
            logfile,
            binary,
            env,
            tps_xpi,
            phase_timeout=TPS_CLEANUP_TIMEOUT_SECONDS,
        )
        if status != "PASS":
            cleanup_failed = True
            if error_line:
                print(f"   Cleanup ERROR: {error_line}")
            print(f"   Cleanup FAIL (status: {status})")

    return cleanup_failed


@Command(
    "tps-test",
    category="testing",
    description="Run TPS tests.",
)
@CommandArgument(
    "--testfile",
    required=False,
    default=None,
    help=(
        "Path to a TPS .js test file or .json test list "
        "(default: services/sync/tests/tps/all_tests.json)"
    ),
)
@CommandArgument("--username", required=False, help="Firefox Account username")
@CommandArgument("--password", required=False, help="Firefox Account password")
@CommandArgument(
    "--auto-account",
    action="store_true",
    help="Automatically create a pre-verified test account (default: staging)",
)
@CommandArgument("--fxa-staging", action="store_true", help="Use FxA staging server")
@CommandArgument(
    "--fxa-production",
    action="store_true",
    help="Use FxA production server (not recommended for testing)",
)
@CommandArgument(
    "--binary", default=None, help="Path to Firefox binary (default: use objdir build)"
)
@CommandArgument("--logfile", default="tps.log", help="Path to log file")
@CommandArgument("--debug", action="store_true", help="Enable debug logging")
def run_tps(
    command_context,
    testfile,
    username,
    password,
    auto_account,
    fxa_staging,
    fxa_production,
    binary,
    logfile,
    debug,
):
    """Run TPS tests with a simple command-line interface."""
    from mozprofile import Profile
    from wptserve import server

    print("Starting TPS test runner...")

    # Determine FxA server URL (Default staging)
    if fxa_staging or auto_account:
        fxa_url = "https://api-accounts.stage.mozaws.net/v1"
        fxa_staging = True
    elif fxa_production:
        fxa_url = "https://api.accounts.firefox.com/v1"
        fxa_staging = False
        print("WARNING: Using FxA PRODUCTION server")
    else:
        fxa_url = "https://api-accounts.stage.mozaws.net/v1"
        fxa_staging = True

    # FxA stage has a WAF that requires a bypass token for automation.
    fxa_ci_token = _resolve_fxa_ci_token(os.environ, fxa_staging=fxa_staging)
    if fxa_staging and not fxa_ci_token:
        print(
            "ERROR: TPS_FXA_CI_TOKEN env var is required for FxA staging.\n"
            "       See testing/tps/README for how to obtain a token."
        )
        return 1

    # Handle account creation or validate credentials
    if auto_account:
        import secrets

        username = f"tps-test-{secrets.token_hex(8)}@restmail.net"
        password = secrets.token_urlsafe(16)
        print(f"   Account credentials generated: {username}")
    else:
        try:
            username, password = _resolve_fxa_credentials(
                username,
                password,
                os.environ,
                allow_argument_credentials=not fxa_production,
            )
        except ValueError as error:
            print(f"ERROR: {error}")
            return 1

    # Build TPS extension
    print("Building TPS extension...")
    tps_xpi = _build_tps_xpi(command_context, None)

    # Determine binary path
    if not binary:
        binary = command_context.get_binary_path()
    print(f"Using Firefox binary: {binary}")

    # Resolve test target and files
    try:
        test_target = _resolve_test_target(command_context.topsrcdir, testfile)
        testfiles = _load_test_list(test_target)
    except (FileNotFoundError, ValueError, json.JSONDecodeError) as e:
        print(f"ERROR: {e}")
        return 1

    if not testfiles:
        print("ERROR: No enabled tests found")
        return 1
    print(f"Test target: {test_target}")
    print(f"Found {len(testfiles)} test file(s)")

    # Set up paths
    extensiondir = os.path.join(
        command_context.topsrcdir, "services", "sync", "tps", "extensions"
    )
    testdir = os.path.join(
        command_context.topsrcdir, "services", "sync", "tests", "tps"
    )
    logfile = os.path.abspath(logfile)
    if os.path.exists(logfile):
        os.remove(logfile)

    # Create TPS config
    config = {
        "fx_account": {
            "username": username,
            "password": password,
        },
        "auth_type": "fx_account",
        "fxaStaging": fxa_staging,
        "fxaApiUrl": fxa_url,
        "autoCreateAccount": auto_account,
        "extensiondir": extensiondir,
        "testdir": testdir,
    }

    if fxa_staging:
        print("Using FxA staging server")

    preferences = _prepare_tps_preferences(
        config, fxa_ci_token=fxa_ci_token, debug=debug
    )
    if debug:
        print("Debug logging enabled")

    env = _prepare_tps_environment(os.environ, command_context.topsrcdir)

    addon_server = server.WebTestHttpd(port=4567, doc_root=testdir)
    addon_server.start()

    failed_tests = []
    passed_tests = []
    all_profiles = []
    profile_cleanup_failed = False
    try:
        for index, current_testfile in enumerate(testfiles, start=1):
            testname = os.path.basename(current_testfile)
            print(f"\nTest {index}/{len(testfiles)}: {testname}")

            try:
                test_phases = _load_test_phases(current_testfile)
            except Exception as e:
                print(f"   FAIL (phase parse failed: {e})")
                failed_tests.append(testname)
                continue

            if not isinstance(test_phases, dict) or not test_phases:
                print("   FAIL (no phases found)")
                failed_tests.append(testname)
                continue

            print(
                f"   Phases ({len(test_phases)}): {', '.join(sorted(test_phases.keys()))}"
            )

            with open(logfile, "a") as f:
                f.write(f"Running test {testname}\n")

            test_preferences = preferences.copy()
            test_preferences["tps.seconds_since_epoch"] = int(time.time())

            profiles = {}
            used_profiles = set()
            successful_profiles = set()
            phase_list = []
            for phase_name, profile_name in sorted(test_phases.items()):
                if profile_name not in profiles:
                    profile = Profile(preferences=test_preferences.copy())
                    profiles[profile_name] = profile
                    all_profiles.append(profile)
                phase_list.append((phase_name, profile_name, profiles[profile_name]))

            test_failed = False
            for phase_name, profile_name, profile in phase_list:
                used_profiles.add(profile_name)
                print(f"Phase: {phase_name}")
                status, error_line = _run_tps_phase(
                    profile,
                    current_testfile,
                    phase_name,
                    testname,
                    logfile,
                    binary,
                    env,
                    tps_xpi,
                    phase_timeout=PHASE_TIMEOUT_SECONDS,
                )
                if error_line:
                    print(f"   ERROR: {error_line}")

                if status == "PASS":
                    successful_profiles.add(profile_name)
                    print("   PASS\n")
                else:
                    print(f"   FAIL (status: {status})\n")
                    test_failed = True
                    break

            if _run_tps_cleanup_phases(
                profiles=profiles,
                used_profiles=used_profiles,
                successful_profiles=successful_profiles,
                current_testfile=current_testfile,
                testname=testname,
                logfile=logfile,
                binary=binary,
                env=env,
                tps_xpi=tps_xpi,
            ):
                test_failed = True

            if test_failed:
                failed_tests.append(testname)
            else:
                passed_tests.append(testname)
    finally:
        profile_cleanup_failed = not _cleanup_tps_resources(all_profiles, addon_server)

    if profile_cleanup_failed:
        failed_tests.append("profile cleanup")

    # Final results
    print("\n" + "=" * 50)
    print(f"Passed: {len(passed_tests)}")
    print(f"Failed: {len(failed_tests)}")
    if failed_tests:
        print(f"Failed tests: {', '.join(failed_tests)}")
        print("TEST FAILED")
        print(f"Full log: {logfile}")
        return 1
    else:
        print("ALL TESTS PASSED")
        print(f"Full log: {logfile}")
        return 0
