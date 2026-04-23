#!/usr/bin/env python3
"""
Regression harness for Phase 2 hot-path pooling.

Launches 100 parallel cmux CLI invocations against a fake app socket and
asserts the workload stays bounded:
1. active cmux process count stays low because requests are forwarded through a
   shared broker instead of each process blocking on the app socket;
2. app-side concurrent socket connections stay low, which is our proxy for
   bounded Mach-port/socket fan-out.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


class FakeJSONRPCSocketServer:
    def __init__(self, socket_path: str, response_delay: float) -> None:
        self.socket_path = socket_path
        self.response_delay = response_delay
        self._ready = threading.Event()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._lock = threading.Lock()
        self.total_connections = 0
        self.active_connections = 0
        self.max_active_connections = 0
        self.methods: list[str] = []
        self._listener: socket.socket | None = None

    def start(self) -> None:
        self._thread.start()
        if not self._ready.wait(timeout=5.0):
            raise RuntimeError("fake socket server did not start in time")

    def stop(self) -> None:
        self._stop.set()
        if self._listener is not None:
            try:
                self._listener.close()
            except OSError:
                pass
        self._thread.join(timeout=5.0)

    def _serve(self) -> None:
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._listener = listener
        listener.bind(self.socket_path)
        listener.listen(128)
        listener.settimeout(0.1)
        self._ready.set()

        while not self._stop.is_set():
            try:
                conn, _ = listener.accept()
            except TimeoutError:
                continue
            except OSError:
                if self._stop.is_set():
                    break
                continue

            with self._lock:
                self.total_connections += 1
                self.active_connections += 1
                self.max_active_connections = max(
                    self.max_active_connections,
                    self.active_connections,
                )

            thread = threading.Thread(target=self._handle_conn, args=(conn,), daemon=True)
            thread.start()

    def _handle_conn(self, conn: socket.socket) -> None:
        buffer = b""
        try:
            while not self._stop.is_set():
                chunk = conn.recv(4096)
                if not chunk:
                    break
                buffer += chunk
                while b"\n" in buffer:
                    raw_line, buffer = buffer.split(b"\n", 1)
                    line = raw_line.strip()
                    if not line:
                        continue
                    request = json.loads(line.decode("utf-8"))
                    method = str(request.get("method", ""))
                    with self._lock:
                        self.methods.append(method)
                    if self.response_delay > 0:
                        time.sleep(self.response_delay)
                    response = {
                        "id": request.get("id"),
                        "ok": True,
                        "result": {"queued": True},
                    }
                    conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
        finally:
            try:
                conn.close()
            except OSError:
                pass
            with self._lock:
                self.active_connections = max(0, self.active_connections - 1)


def count_matching_processes(cli_path: str, broker_socket: str) -> int:
    result = subprocess.run(
        ["ps", "-axo", "command="],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return 0
    lines = [line for line in (result.stdout or "").splitlines() if line.strip()]
    return sum(1 for line in lines if cli_path in line and broker_socket in line)


def main() -> int:
    failures: list[str] = []
    cli_path = resolve_cmux_cli()

    with tempfile.TemporaryDirectory(prefix="cmux-hot-path-pool-") as td:
        root = Path(td)
        app_socket = str(root / "cmux.sock")
        broker_socket = str(root / "hot-path-broker.sock")
        server = FakeJSONRPCSocketServer(socket_path=app_socket, response_delay=0.02)
        server.start()
        try:
            params = json.dumps(
                {
                    "workspace_id": "11111111-1111-1111-1111-111111111111",
                    "surface_id": "22222222-2222-2222-2222-222222222222",
                    "tty_name": "ttys777",
                    "reason": "command",
                }
            )

            procs: list[subprocess.Popen[str]] = []
            for _ in range(100):
                procs.append(
                    subprocess.Popen(
                        [
                            cli_path,
                            "--socket",
                            app_socket,
                            "__hot-path",
                            "--broker-socket",
                            broker_socket,
                            "rpc",
                            "surface.telemetry",
                            params,
                        ],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                    )
                )

            time.sleep(0.15)
            active_processes = count_matching_processes(cli_path, broker_socket)

            for index, proc in enumerate(procs):
                try:
                    stdout, stderr = proc.communicate(timeout=15.0)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    stdout, stderr = proc.communicate()
                    failures.append(f"request {index} timed out: stdout={stdout!r} stderr={stderr!r}")
                    continue
                if proc.returncode != 0:
                    failures.append(
                        f"request {index} exited {proc.returncode}: stdout={stdout!r} stderr={stderr!r}"
                    )

            if active_processes > 8:
                failures.append(
                    f"expected <=8 active cmux processes during 100-call burst, saw {active_processes}"
                )

            if server.max_active_connections > 4:
                failures.append(
                    "expected <=4 concurrent app socket connections during pooled burst, "
                    f"saw {server.max_active_connections}"
                )

            if not server.methods:
                failures.append("fake app socket did not receive any methods")
            elif set(server.methods) != {"surface.telemetry"}:
                failures.append(f"expected only surface.telemetry, got {server.methods!r}")
        finally:
            server.stop()

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1

    print("PASS: hot-path broker bounds cmux proc count and app socket fan-out under 100 parallel calls")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
