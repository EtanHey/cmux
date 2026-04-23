#!/usr/bin/env python3
"""
Regression: tmux compatibility list-panes/display context should come from a
batched workspace snapshot instead of fan-out across workspace/surface current
queries.
"""

from __future__ import annotations

import json
import socket
import subprocess
import tempfile
import threading
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


WORKSPACE_ID = "11111111-1111-1111-1111-111111111111"
WINDOW_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
PANE_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
SURFACE_ID = "cccccccc-cccc-cccc-cccc-cccccccccccc"


class FakeTmuxBatchServer:
    def __init__(self, socket_path: str) -> None:
        self.socket_path = socket_path
        self._ready = threading.Event()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._listener: socket.socket | None = None
        self.methods: list[str] = []

    def start(self) -> None:
        self._thread.start()
        if not self._ready.wait(timeout=5.0):
            raise RuntimeError("fake tmux batch server did not start")

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
        listener.listen(16)
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
                    self.methods.append(method)
                    response = self._response_for(method)
                    envelope = {
                        "id": request.get("id"),
                        "ok": True,
                        "result": response,
                    }
                    conn.sendall((json.dumps(envelope) + "\n").encode("utf-8"))
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def _response_for(self, method: str) -> dict:
        if method == "system.tree":
            return {
                "active": {
                    "window_id": WINDOW_ID,
                    "window_ref": "window:1",
                    "workspace_id": WORKSPACE_ID,
                    "workspace_ref": "workspace:1",
                    "pane_id": PANE_ID,
                    "pane_ref": "pane:1",
                    "surface_id": SURFACE_ID,
                    "surface_ref": "surface:1",
                },
                "caller": None,
                "windows": [
                    {
                        "id": WINDOW_ID,
                        "ref": "window:1",
                        "index": 0,
                        "key": True,
                        "visible": True,
                        "workspace_count": 1,
                        "selected_workspace_id": WORKSPACE_ID,
                        "selected_workspace_ref": "workspace:1",
                        "workspaces": [
                            {
                                "id": WORKSPACE_ID,
                                "ref": "workspace:1",
                                "index": 0,
                                "title": "Agents",
                                "selected": True,
                                "pinned": False,
                                "panes": [
                                    {
                                        "id": PANE_ID,
                                        "ref": "pane:1",
                                        "index": 0,
                                        "focused": True,
                                        "selected_surface_id": SURFACE_ID,
                                        "selected_surface_ref": "surface:1",
                                        "surface_count": 1,
                                        "surfaces": [
                                            {
                                                "id": SURFACE_ID,
                                                "ref": "surface:1",
                                                "index": 0,
                                                "type": "terminal",
                                                "title": "Leader",
                                                "focused": True,
                                                "selected": True,
                                                "selected_in_pane": True,
                                                "pane_id": PANE_ID,
                                                "pane_ref": "pane:1",
                                                "index_in_pane": 0,
                                                "tty": "ttys001",
                                            }
                                        ],
                                    }
                                ],
                            }
                        ],
                    }
                ],
            }
        if method == "pane.list":
            return {
                "panes": [
                    {
                        "id": PANE_ID,
                        "ref": "pane:1",
                        "index": 0,
                        "focused": True,
                        "columns": 120,
                        "rows": 40,
                        "cell_width_px": 10,
                        "cell_height_px": 20,
                        "pixel_frame": {"x": 0, "y": 0, "width": 1200, "height": 800},
                    }
                ],
                "container_frame": {"x": 0, "y": 0, "width": 1200, "height": 800},
            }
        raise RuntimeError(f"unexpected method: {method}")


def main() -> int:
    failures: list[str] = []
    cli_path = resolve_cmux_cli()

    with tempfile.TemporaryDirectory(prefix="cmux-tmux-tree-batch-") as td:
        root = Path(td)
        socket_path = str(root / "cmux.sock")
        server = FakeTmuxBatchServer(socket_path)
        server.start()
        try:
            result = subprocess.run(
                [
                    cli_path,
                    "--socket",
                    socket_path,
                    "__tmux-compat",
                    "list-panes",
                    "-t",
                    WORKSPACE_ID,
                    "-F",
                    "#{pane_id}|#{window_name}|#{pane_title}|#{pane_width}x#{pane_height}",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
        finally:
            server.stop()

    if result.returncode != 0:
        failures.append(
            f"list-panes exited {result.returncode}: stdout={result.stdout!r} stderr={result.stderr!r}"
        )

    expected_output = f"%{PANE_ID}|Agents|Leader|120x40"
    actual_output = (result.stdout or "").strip()
    if actual_output != expected_output:
        failures.append(f"expected output {expected_output!r}, got {actual_output!r}")

    unexpected_methods = [
        method for method in server.methods if method in {"workspace.list", "surface.current", "surface.list", "window.list"}
    ]
    if unexpected_methods:
        failures.append(f"expected batched tmux snapshot, got fan-out methods {unexpected_methods!r}")

    if server.methods.count("system.tree") != 1:
        failures.append(f"expected one system.tree call, got {server.methods!r}")

    if server.methods.count("pane.list") != 1:
        failures.append(f"expected one pane.list geometry call, got {server.methods!r}")

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1

    print("PASS: tmux list-panes renders from batched system.tree + pane geometry only")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
