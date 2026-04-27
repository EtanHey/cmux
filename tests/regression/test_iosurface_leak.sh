#!/usr/bin/env bash
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE_PATH="$REPO_ROOT/tests/fixtures/rapid_spawn_kill.sh"

THRESHOLD_MB="${CMUX_LEAK_THRESHOLD_MB:-50}"
ITERATIONS="${CMUX_LEAK_TEST_ITERATIONS:-10}"
READY_TIMEOUT_MS="${CMUX_LEAK_READY_TIMEOUT_MS:-8000}"
APP_PATH="${CMUX_LEAK_APP_PATH:-${CMUX_RAPID_SPAWN_KILL_APP_PATH:-}}"
EXECUTABLE_PATH="${CMUX_LEAK_EXECUTABLE_PATH:-${CMUX_RAPID_SPAWN_KILL_EXECUTABLE_PATH:-}}"
TMP_ROOT="${CMUX_LEAK_TMPDIR:-${TMPDIR:-/tmp}/cmux-iosurface-leak.$$}"
KEEP_OUTPUT="${CMUX_LEAK_KEEP_OUTPUT:-0}"
REQUIRE_IOSURFACE="${CMUX_LEAK_REQUIRE_IOSURFACE:-0}"

log() {
  printf '[iosurface-leak] %s\n' "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

bytes_from_human() {
  local value="$1"
  local trimmed number unit exponent
  trimmed="$(printf '%s' "$value" | tr -d '[:space:],')"
  if [[ -z "$trimmed" || "$trimmed" == "-" ]]; then
    echo 0
    return
  fi
  if [[ "$trimmed" =~ ^([0-9]+([.][0-9]+)?)([KMGTP]?) ]]; then
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[3]}"
  else
    echo 0
    return
  fi

  exponent=0
  case "$unit" in
    K) exponent=1 ;;
    M) exponent=2 ;;
    G) exponent=3 ;;
    T) exponent=4 ;;
    P) exponent=5 ;;
  esac

  awk -v number="$number" -v exponent="$exponent" '
    function power(base, exponent_value,   out, i) {
      out = 1
      for (i = 0; i < exponent_value; i++) out *= base
      return out
    }
    BEGIN { printf "%.0f\n", number * power(1024, exponent) }'
}

bytes_to_mb() {
  local bytes="$1"
  awk -v bytes="$bytes" 'BEGIN { printf "%.2f", bytes / (1024 * 1024) }'
}

mb_to_bytes() {
  local mb="$1"
  awk -v mb="$mb" 'BEGIN { printf "%.0f\n", mb * 1024 * 1024 }'
}

resolve_executable() {
  if [[ -n "$EXECUTABLE_PATH" ]]; then
    [[ -x "$EXECUTABLE_PATH" ]] || die "CMUX_LEAK_EXECUTABLE_PATH is not executable: $EXECUTABLE_PATH"
    printf '%s\n' "$EXECUTABLE_PATH"
    return
  fi

  if [[ -z "$APP_PATH" ]]; then
    APP_PATH="/Applications/cmux.app"
  fi
  [[ -d "$APP_PATH" ]] || die "cmux app not found: $APP_PATH"

  local candidate
  for candidate in \
    "$APP_PATH/Contents/MacOS/cmux DEV" \
    "$APP_PATH/Contents/MacOS/cmux"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  die "no cmux executable found inside $APP_PATH"
}

iosurface_bytes_for_pid() {
  local pid="$1"
  local vmmap_output line resident swapped
  if ! vmmap_output="$(vmmap -summary "$pid" 2>/dev/null)"; then
    echo 0
    return
  fi

  line="$(printf '%s\n' "$vmmap_output" | awk '/^IOSurface[[:space:]]/ {print; exit}')"
  if [[ -z "$line" ]]; then
    echo 0
    return
  fi

  resident="$(awk '{print $3}' <<<"$line")"
  swapped="$(awk '{print $5}' <<<"$line")"
  awk -v resident_bytes="$(bytes_from_human "$resident")" \
      -v swapped_bytes="$(bytes_from_human "$swapped")" \
      'BEGIN { printf "%.0f\n", resident_bytes + swapped_bytes }'
}

parse_fixture_iosurface_mb() {
  local output_path="$1"
  awk -F'= ' '/VM: IOSurface[[:space:]]*=/ {
    value = $2
    sub(/[[:space:]]*MB.*/, "", value)
    print value
  }' "$output_path" | tail -n 1
}

wait_for_iosurface_or_timeout() {
  local pid="$1"
  local deadline iosurface_bytes
  deadline=$((SECONDS + (READY_TIMEOUT_MS / 1000) + 1))
  while kill -0 "$pid" 2>/dev/null; do
    iosurface_bytes="$(iosurface_bytes_for_pid "$pid")"
    if (( iosurface_bytes > 0 )); then
      return 0
    fi
    # Timeout is non-fatal: direct shell runs can report 0 MB while the XCTest
    # host still records positive IOSurface allocation from the same fixture.
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

terminate_pid() {
  local pid="$1"
  kill -TERM "$pid" 2>/dev/null || return 0
  for _ in {1..20}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 0.05
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  local status="$1"
  if [[ "$status" -eq 0 && "$KEEP_OUTPUT" != "1" ]]; then
    rm -rf "$TMP_ROOT"
  else
    log "artifacts kept at $TMP_ROOT"
  fi
}

main() {
  command -v leaks >/dev/null 2>&1 || die "Apple leaks CLI not found"
  command -v vmmap >/dev/null 2>&1 || die "vmmap not found"
  [[ "$THRESHOLD_MB" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "CMUX_LEAK_THRESHOLD_MB must be numeric"
  [[ "$ITERATIONS" =~ ^[0-9]+$ ]] || die "CMUX_LEAK_TEST_ITERATIONS must be an integer"
  [[ "$ITERATIONS" -gt 0 ]] || die "CMUX_LEAK_TEST_ITERATIONS must be greater than zero"
  [[ -x "$FIXTURE_PATH" ]] || die "missing executable fixture: $FIXTURE_PATH"

  local threshold_bytes executable pid fixture_leaks_output live_leaks_output fixture_leaks_status live_leaks_status
  local sentinel_iosurface_bytes fixture_iosurface_mb fixture_iosurface_bytes
  if [[ -z "$APP_PATH" && -z "$EXECUTABLE_PATH" ]]; then
    APP_PATH="/Applications/cmux.app"
  fi

  threshold_bytes="$(mb_to_bytes "$THRESHOLD_MB")"
  executable="$(resolve_executable)"

  mkdir -p "$TMP_ROOT"
  trap 'status=$?; if [[ -n "${pid:-}" ]]; then terminate_pid "$pid"; fi; cleanup "$status"' EXIT

  fixture_leaks_output="$TMP_ROOT/rapid_spawn_kill.leaks.out"
  log "running rapid_spawn_kill.sh under leaks --atExit iterations=$ITERATIONS"
  if [[ -n "$APP_PATH" ]]; then
    CMUX_RAPID_SPAWN_KILL_APP_PATH="$APP_PATH" \
    CMUX_RAPID_SPAWN_KILL_ITERATIONS="$ITERATIONS" \
    CMUX_RAPID_SPAWN_KILL_FORCE_WINDOW=1 \
    CMUX_RAPID_SPAWN_KILL_READY_TIMEOUT_MS="$READY_TIMEOUT_MS" \
    CMUX_RAPID_SPAWN_KILL_TMPDIR="$TMP_ROOT/fixture" \
      leaks --quiet --atExit -- /bin/bash "$FIXTURE_PATH" >"$fixture_leaks_output" 2>&1
  else
    CMUX_RAPID_SPAWN_KILL_EXECUTABLE_PATH="$executable" \
    CMUX_RAPID_SPAWN_KILL_ITERATIONS="$ITERATIONS" \
    CMUX_RAPID_SPAWN_KILL_FORCE_WINDOW=1 \
    CMUX_RAPID_SPAWN_KILL_READY_TIMEOUT_MS="$READY_TIMEOUT_MS" \
    CMUX_RAPID_SPAWN_KILL_TMPDIR="$TMP_ROOT/fixture" \
      leaks --quiet --atExit -- /bin/bash "$FIXTURE_PATH" >"$fixture_leaks_output" 2>&1
  fi
  fixture_leaks_status=$?

  fixture_iosurface_mb="$(parse_fixture_iosurface_mb "$fixture_leaks_output")"
  [[ -n "$fixture_iosurface_mb" ]] || die "fixture did not print VM: IOSurface; output saved at $fixture_leaks_output"
  fixture_iosurface_bytes="$(mb_to_bytes "$fixture_iosurface_mb")"

  log "spawning cmux live leaks sentinel"
  CMUX_TAG="iosurface-leak-sentinel-$$" \
  CMUX_SOCKET_PATH="$TMP_ROOT/sentinel.sock" \
  CMUX_RAPID_SPAWN_KILL_FIXTURE=1 \
  CMUX_RAPID_SPAWN_KILL_FORCE_WINDOW=1 \
    "$executable" >"$TMP_ROOT/sentinel.log" 2>&1 &
  pid="$!"

  wait_for_iosurface_or_timeout "$pid" || die "cmux sentinel exited before leaks sampling"

  live_leaks_output="$TMP_ROOT/live-pid.leaks.out"
  log "running leaks pid=$pid"
  leaks --quiet "$pid" >"$live_leaks_output" 2>&1
  live_leaks_status=$?

  sentinel_iosurface_bytes="$(iosurface_bytes_for_pid "$pid")"

  printf 'fixture_leaks_exit_status=%s\n' "$fixture_leaks_status"
  printf 'fixture_leaks_iosurface_lines=%s\n' "$(grep -c 'IOSurface' "$fixture_leaks_output" || true)"
  printf 'live_leaks_exit_status=%s\n' "$live_leaks_status"
  printf 'live_leaks_iosurface_lines=%s\n' "$(grep -c 'IOSurface' "$live_leaks_output" || true)"
  printf 'sentinel_VM_IOSurface_MB=%s\n' "$(bytes_to_mb "$sentinel_iosurface_bytes")"
  printf 'fixture_VM_IOSurface_MB=%s\n' "$fixture_iosurface_mb"
  printf 'threshold_MB=%s\n' "$THRESHOLD_MB"

  if [[ "$fixture_leaks_status" -ne 0 ]]; then
    log "leaks --atExit reported leaked allocations; IOSurface excerpts follow"
    grep 'IOSurface' "$fixture_leaks_output" || true
    exit "$fixture_leaks_status"
  fi

  if [[ "$live_leaks_status" -ne 0 ]]; then
    log "live leaks reported leaked allocations; IOSurface excerpts follow"
    grep 'IOSurface' "$live_leaks_output" || true
    exit "$live_leaks_status"
  fi

  if [[ "$fixture_iosurface_bytes" -eq 0 && "$REQUIRE_IOSURFACE" = "1" ]]; then
    log "FAIL no IOSurface footprint observed; fixture did not exercise the target allocation path"
    exit 1
  fi

  if [[ "$fixture_iosurface_bytes" -gt "$threshold_bytes" ]]; then
    log "FAIL fixture VM: IOSurface ${fixture_iosurface_mb} MB exceeds threshold ${THRESHOLD_MB} MB"
    exit 1
  fi

  log "PASS IOSurface footprint stayed within threshold"
}

main "$@"
