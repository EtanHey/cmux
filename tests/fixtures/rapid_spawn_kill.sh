#!/usr/bin/env bash
set -euo pipefail
set +m 2>/dev/null || true

ITERATIONS="${CMUX_RAPID_SPAWN_KILL_ITERATIONS:-100}"
READY_TIMEOUT_MS="${CMUX_RAPID_SPAWN_KILL_READY_TIMEOUT_MS:-2500}"
APP_PATH="${CMUX_RAPID_SPAWN_KILL_APP_PATH:-}"
EXECUTABLE_PATH="${CMUX_RAPID_SPAWN_KILL_EXECUTABLE_PATH:-}"
TMP_ROOT="${CMUX_RAPID_SPAWN_KILL_TMPDIR:-${TMPDIR:-/tmp}/cmux-rapid-spawn-kill.$$}"

log() {
  printf '[rapid-spawn-kill] %s\n' "$*" >&2
}

die() {
  log "ERROR: $*"
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

resolve_executable() {
  if [[ -n "$EXECUTABLE_PATH" ]]; then
    [[ -x "$EXECUTABLE_PATH" ]] || die "CMUX_RAPID_SPAWN_KILL_EXECUTABLE_PATH is not executable: $EXECUTABLE_PATH"
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

wait_for_child_ready() {
  local pid="$1"
  local deadline
  deadline=$((SECONDS + (READY_TIMEOUT_MS / 1000) + 1))
  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$(iosurface_bytes_for_pid "$pid")" != "0" ]]; then
      return 0
    fi
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      return 0
    fi
  done
  return 1
}

terminate_child() {
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

main() {
  [[ "$ITERATIONS" =~ ^[0-9]+$ ]] || die "CMUX_RAPID_SPAWN_KILL_ITERATIONS must be an integer"
  [[ "$ITERATIONS" -gt 0 ]] || die "CMUX_RAPID_SPAWN_KILL_ITERATIONS must be greater than zero"

  local executable
  executable="$(resolve_executable)"
  mkdir -p "$TMP_ROOT"
  trap 'rm -rf "$TMP_ROOT"' EXIT

  local max_iosurface_bytes=0
  local spawned=0
  local iteration pid sample_bytes
  for ((iteration = 1; iteration <= ITERATIONS; iteration++)); do
    CMUX_TAG="rapid-spawn-kill-$iteration-$$" \
    CMUX_SOCKET_PATH="$TMP_ROOT/socket-$iteration.sock" \
    CMUX_RAPID_SPAWN_KILL_FIXTURE=1 \
      "$executable" >"$TMP_ROOT/cmux-$iteration.log" 2>&1 &
    pid="$!"
    spawned=$((spawned + 1))

    wait_for_child_ready "$pid" || true
    sample_bytes="$(iosurface_bytes_for_pid "$pid")"
    printf 'rapid_spawn_kill_sample iteration=%s pid=%s iosurface_mb=%s\n' \
      "$iteration" "$pid" "$(bytes_to_mb "$sample_bytes")"
    if [[ "$sample_bytes" -gt "$max_iosurface_bytes" ]]; then
      max_iosurface_bytes="$sample_bytes"
    fi
    terminate_child "$pid"
  done

  printf 'rapid_spawn_kill_iterations=%s\n' "$ITERATIONS"
  printf 'rapid_spawn_kill_spawned=%s\n' "$spawned"
  printf 'VM: IOSurface = %s MB\n' "$(bytes_to_mb "$max_iosurface_bytes")"
}

main "$@"
