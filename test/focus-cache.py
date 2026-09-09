#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time

nvim, keymaps = sys.argv[1:3]
source = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="cockpit-focus-") as temp:
    root = Path(temp)
    runtime = root / "run"
    runtime.mkdir(mode=0o700)
    fallback = root / ".config/niri/scripts/cockpit-cross"
    fallback.parent.mkdir(parents=True)
    fallback.write_text('#!/bin/sh\ntouch "$HOME/fallback-used"\n')
    fallback.chmod(0o700)
    ns = runtime / "nvim-test.sock"
    cache = runtime / "cockpit-ipc.nvim-test.sock.id"
    shutil.copy(source / "qs-shell/FocusCache.qml", root)
    (root / "shell.qml").write_text('''import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
  id: shell
  property string position: "nvim"
  FocusCache { nvimSocket: Quickshell.env("NVIM_LISTEN_ADDRESS") }
  IpcHandler {
    target: "cockpit"
    function focusRight(): string { shell.position = "rail"; return "consumed" }
    function pane(): string { return shell.position }
    function identity(): string { return Quickshell.instanceId }
  }
}
''')
    env = dict(os.environ, HOME=temp, XDG_RUNTIME_DIR=str(runtime), QT_QPA_PLATFORM="offscreen",
               COCKPIT_COCKPIT="1", NVIM_LISTEN_ADDRESS=str(ns))
    env.pop("WAYLAND_DISPLAY", None)
    def call(identity, method):
        def q(value):
            data = value.encode("utf-16-be")
            return struct.pack(">I", len(data)) + data
        with socket.socket(socket.AF_UNIX) as conn:
            conn.settimeout(.5)
            conn.connect(str(runtime / "quickshell/by-id" / identity / "ipc.sock"))
            conn.sendall(b"\3" + q("cockpit") + q(method) + b"\0\0\0\0")
            data = conn.recv(4096)
            assert data[0] == 5, data
            return data[6:].decode("utf-16-be")
    def wait(test):
        end = time.monotonic() + 5
        while time.monotonic() < end:
            try:
                value = test()
                if value:
                    return value
            except (OSError, AssertionError):
                pass
            time.sleep(.01)
        raise AssertionError("timed out")
    with open(root / "nvim.log", "w") as log:
        editor = subprocess.Popen([nvim, "--headless", "-u", "NONE", "--listen", str(ns),
                                   "--cmd", "let $NVIM_LISTEN_ADDRESS = v:servername", "-c", "lua dofile(" + json.dumps(keymaps) + ")"], env=env, stdout=log, stderr=log)
        try:
            wait(ns.exists)
            previous = "dead-instance"
            cache.write_text(previous)
            for cycle in range(2):
                with open(root / "qs.log", "w") as output:
                    shell = subprocess.Popen(["qs", "-p", temp], env=env, stdout=output, stderr=output)
                    try:
                        identity = wait(lambda: cache.read_text().strip() != previous and cache.read_text().strip())
                        wait(lambda: call(identity, "identity") == identity)
                        subprocess.run([nvim, "--server", str(ns), "--remote-send", "<C-l>"], env=env, check=True)
                        wait(lambda: call(identity, "pane") == "rail")
                        assert not (root / "fallback-used").exists(), "Ctrl+L used slow fallback"
                        print("PASS: " + ("cold launch" if cycle == 0 else "restart") + " published current ID; real Ctrl+L used direct IPC")
                        previous = identity
                    finally:
                        shell.terminate()
                        shell.wait(timeout=5)
        finally:
            editor.terminate()
            editor.wait(timeout=5)
