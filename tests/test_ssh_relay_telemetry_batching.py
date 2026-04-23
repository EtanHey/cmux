#!/usr/bin/env python3
"""
Regression: relay-backed command-start telemetry should batch TTY reporting and
ports kicks into one child CLI invocation instead of two back-to-back RPCs.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SHELL_DIR = ROOT / "Resources" / "shell-integration"


def _write_executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


def _run_case(shell: str, shell_args: list[str], integration_path: Path, invoke: str) -> tuple[int, str, list[str]]:
    with tempfile.TemporaryDirectory(prefix="cmux-ssh-relay-telemetry-batching-") as td:
        root = Path(td)
        bin_dir = root / "bin"
        bin_dir.mkdir(parents=True, exist_ok=True)
        log_path = root / "relay.log"

        _write_executable(
            bin_dir / "cmux",
            """#!/bin/sh
printf '%s\n' "$*" >> "$CMUX_TEST_LOG"
printf '%s\n' '{"ok":true,"result":{"queued":true}}'
""",
        )

        env = dict(os.environ)
        env.update(
            {
                "PATH": f"{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": "127.0.0.1:64011",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_TAB_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_TEST_LOG": str(log_path),
            }
        )

        command = f"""
source "{integration_path}"
PATH="{bin_dir}:$PATH"
hash -r 2>/dev/null || true
: > "{log_path}"
_CMUX_TTY_NAME=ttys777
_CMUX_TTY_REPORTED=0
{invoke}
sleep 0.3
cat "{log_path}"
""".strip()

        result = subprocess.run(
            [shell, *shell_args, command],
            capture_output=True,
            text=True,
            env=env,
            timeout=10,
            check=False,
        )
        lines = [line.strip() for line in (log_path.read_text(encoding="utf-8") if log_path.exists() else "").splitlines() if line.strip()]
        return result.returncode, ((result.stdout or "") + (result.stderr or "")).strip(), lines


def main() -> int:
    failures: list[str] = []

    cases = [
        (
            "zsh",
            ["-f", "-c"],
            SHELL_DIR / "cmux-zsh-integration.zsh",
            '_cmux_preexec "node server.js"',
        ),
        (
            "bash",
            ["--noprofile", "--norc", "-c"],
            SHELL_DIR / "cmux-bash-integration.bash",
            '_cmux_preexec_command "node server.js"',
        ),
    ]

    for shell, shell_args, integration_path, invoke in cases:
        code, output, log_lines = _run_case(shell, shell_args, integration_path, invoke)
        if code != 0:
            failures.append(f"{shell} exited {code}: {output}")
            continue
        if len(log_lines) != 1:
            failures.append(f"{shell} expected one relay telemetry child, got {log_lines!r}")
            continue
        line = log_lines[0]
        if "surface.telemetry" not in line:
            failures.append(f"{shell} expected surface.telemetry call, got {line!r}")
        if "surface.report_tty" in line or "surface.ports_kick" in line:
            failures.append(f"{shell} expected batched relay telemetry, got legacy calls {line!r}")

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1

    print("PASS: relay shell command-start telemetry uses one batched child invocation")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
