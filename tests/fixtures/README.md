# cmux Test Fixtures

## rapid_spawn_kill.sh

`rapid_spawn_kill.sh` is a stress fixture for the cmux IOSurface regression harness. It repeatedly launches a fresh cmux app process, waits only long enough for the child process to expose `vmmap -summary` data, samples the `IOSurface` resident + swapped footprint, terminates the child, and immediately starts the next iteration.

The default loop count is 100 to force Mach-port and IOSurface churn without inter-iteration settle time. XCTest uses a lower count for targeted verification so the fixture remains practical in local and CI runs.

Useful environment variables:

- `CMUX_RAPID_SPAWN_KILL_APP_PATH`: path to the cmux `.app` bundle. Defaults to `/Applications/cmux.app`.
- `CMUX_RAPID_SPAWN_KILL_EXECUTABLE_PATH`: direct cmux executable override.
- `CMUX_RAPID_SPAWN_KILL_ITERATIONS`: loop count. Defaults to `100`.
- `CMUX_RAPID_SPAWN_KILL_READY_TIMEOUT_MS`: maximum per-child startup sampling wait. Defaults to `2500`.
- `CMUX_RAPID_SPAWN_KILL_TMPDIR`: scratch directory for per-iteration sockets and logs.

Example:

```bash
CMUX_RAPID_SPAWN_KILL_APP_PATH="/Applications/cmux.app" \
CMUX_RAPID_SPAWN_KILL_ITERATIONS=100 \
tests/fixtures/rapid_spawn_kill.sh
```

The fixture prints `VM: IOSurface = <N> MB`; `RapidSpawnKillFixtureTests` runs it under `leaks --atExit` and asserts that value stays under the configured threshold.
