# cmux Regression Tests

## test_iosurface_leak.sh

`test_iosurface_leak.sh` runs the Phase 2e `rapid_spawn_kill.sh` fixture under Apple's `/usr/bin/leaks --atExit`, then samples a live cmux process with `leaks $PID`. It parses the fixture's `VM: IOSurface = <N> MB` line and fails when the value exceeds `CMUX_LEAK_THRESHOLD_MB` (default: `50`).

Useful environment variables:

- `CMUX_LEAK_APP_PATH`: cmux `.app` bundle to test. `scripts/run_tests.sh` sets this to the app built by Xcode.
- `CMUX_LEAK_EXECUTABLE_PATH`: direct cmux executable override when an app bundle is unavailable.
- `CMUX_LEAK_TEST_ITERATIONS`: rapid spawn/kill loop count. Defaults to `10`; `scripts/run_tests.sh` uses `3`.
- `CMUX_LEAK_THRESHOLD_MB`: IOSurface threshold in MB. Defaults to `50`.
- `CMUX_LEAK_REQUIRE_IOSURFACE`: set to `1` for manual debugging when the shell context must prove a nonzero IOSurface sample. The top-level gate leaves this off because `RapidSpawnKillFixtureTests` already enforces positive IOSurface allocation from the XCTest host.
- `CMUX_LEAK_KEEP_OUTPUT`: set to `1` to retain raw `leaks` and fixture output under the temp directory.
