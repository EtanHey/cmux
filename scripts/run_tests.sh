#!/usr/bin/env bash
set -u
set -o pipefail

EXIT_STATUS=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT="${CMUX_RUN_TESTS_PROJECT:-GhosttyTabs.xcodeproj}"
SCHEME="${CMUX_RUN_TESTS_SCHEME:-cmux-unit}"
CONFIGURATION="${CMUX_RUN_TESTS_CONFIGURATION:-Debug}"
DESTINATION="${CMUX_RUN_TESTS_DESTINATION:-platform=macOS,arch=arm64}"
DERIVED_DATA_PATH="${CMUX_RUN_TESTS_DERIVED_DATA_PATH:-/tmp/cmux-run-tests-derived}"
BUILT_APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/cmux DEV.app"
FIXTURE_PATH="$REPO_ROOT/tests/fixtures/rapid_spawn_kill.sh"
LEAK_TEST_PATH="$REPO_ROOT/tests/regression/test_iosurface_leak.sh"
IOSURFACE_LIMIT_MB="${CMUX_RAPID_SPAWN_KILL_IOSURFACE_LIMIT_MB:-50}"
XCTEST_ITERATIONS="${CMUX_RUN_TESTS_XCTEST_ITERATIONS:-3}"
READY_TIMEOUT_MS="${CMUX_RAPID_SPAWN_KILL_READY_TIMEOUT_MS:-8000}"
LEAK_TEST_ITERATIONS="${CMUX_RUN_TESTS_LEAK_ITERATIONS:-3}"
ZIG_015_BIN="${CMUX_RUN_TESTS_ZIG_BIN:-/opt/homebrew/opt/zig@0.15/bin}"

if [ -d "$ZIG_015_BIN" ]; then
  PATH="$ZIG_015_BIN:$PATH"
  export PATH
fi

log() {
  printf '[cmux-run-tests] %s\n' "$*"
}

mark_failure() {
  local mask="$1"
  local label="$2"
  log "FAIL mask=$mask step=$label"
  ((EXIT_STATUS |= mask))
}

run_xcodebuild_fixture_test() {
  log "Running xcodebuild RapidSpawnKillFixtureTests (/usr/bin/leaks --atExit -> rapid_spawn_kill.sh)"
  CMUX_RAPID_SPAWN_KILL_ITERATIONS="$XCTEST_ITERATIONS" \
  CMUX_RAPID_SPAWN_KILL_READY_TIMEOUT_MS="$READY_TIMEOUT_MS" \
  CMUX_RAPID_SPAWN_KILL_IOSURFACE_LIMIT_MB="$IOSURFACE_LIMIT_MB" \
    xcodebuild \
      -quiet \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -destination "$DESTINATION" \
      -derivedDataPath "$DERIVED_DATA_PATH" \
      -only-testing:cmuxTests/RapidSpawnKillFixtureTests/testRapidSpawnKillFixtureKeepsIOSurfaceFootprintUnderBudget \
      test
  return $?
}

run_iosurface_leak_test() {
  log "Running Apple leaks CLI IOSurface regression test"
  CMUX_LEAK_THRESHOLD_MB="$IOSURFACE_LIMIT_MB" \
  CMUX_LEAK_TEST_ITERATIONS="$LEAK_TEST_ITERATIONS" \
  CMUX_LEAK_READY_TIMEOUT_MS="$READY_TIMEOUT_MS" \
  CMUX_LEAK_APP_PATH="$BUILT_APP_PATH" \
    "$LEAK_TEST_PATH"
  return $?
}

cd "$REPO_ROOT" || {
  mark_failure 1 "cd-repo-root"
  exit "$EXIT_STATUS"
}

if [ ! -x "$FIXTURE_PATH" ]; then
  log "Missing executable fixture: $FIXTURE_PATH"
  mark_failure 1 "fixture-present"
elif [ ! -x "$LEAK_TEST_PATH" ]; then
  log "Missing executable regression test: $LEAK_TEST_PATH"
  mark_failure 1 "iosurface-leak-test-present"
else
  if [ ! -d "$REPO_ROOT/GhosttyKit.xcframework" ]; then
    log "GhosttyKit.xcframework missing; initializing submodules and downloading prebuilt framework"
    if ! git submodule update --init --recursive ghostty vendor/bonsplit; then
      mark_failure 2 "submodule-init"
    elif ! "$REPO_ROOT/scripts/download-prebuilt-ghosttykit.sh"; then
      mark_failure 2 "ghosttykit-download"
    fi
  fi

  run_xcodebuild_fixture_test
  xcodebuild_status=$?
  if [ "$xcodebuild_status" -ne 0 ]; then
    mark_failure 4 "xcodebuild-rapid-spawn-kill"
  fi

  run_iosurface_leak_test
  leak_test_status=$?
  if [ "$leak_test_status" -ne 0 ]; then
    mark_failure 8 "leaks-iosurface-regression"
  fi
fi

log "finished with exit status $EXIT_STATUS"

if [ "$EXIT_STATUS" -ne 0 ]; then
  exit "$EXIT_STATUS"
fi
