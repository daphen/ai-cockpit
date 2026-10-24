#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

source = Path(__file__).resolve().parents[1]
hook = Path.home() / "nixos/dotfiles/claude/.claude/hooks/notify-with-context.sh"
with tempfile.TemporaryDirectory(prefix="cockpit-notification-focus-") as temp:
    root = Path(temp)
    runtime = root / "run"
    runtime.mkdir(mode=0o700)
    home = root / "home"
    home.mkdir()
    tools = root / "bin"
    tools.mkdir()
    notify = tools / "notify-send"
    notify.write_text('#!/bin/sh\necho delivered >> "$HOME/notifications"\n')
    notify.chmod(0o700)
    env = dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=str(runtime),
               QT_QPA_PLATFORM="offscreen", PATH=str(tools) + ":" + os.environ["PATH"])
    env.pop("WAYLAND_DISPLAY", None)
    marker = runtime / "agent-rail-focused"
    processes = []

    def wait(check):
        end = time.monotonic() + 5
        while time.monotonic() < end:
            if check():
                return
            time.sleep(.02)
        raise AssertionError("focus marker did not update")

    def call(process, method, *args):
        result = subprocess.run(["qs", "ipc", "--pid", str(process.pid), "call", "test", method, *args],
                                env=env, capture_output=True, text=True, timeout=5)
        assert result.returncode == 0, result.stderr

    def notified(session, expected):
        result = subprocess.run([str(hook)], input=json.dumps({"session_id": session, "app": "Test",
                                      "cwd": str(home), "message": "Test notification"}),
                                env=env, capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stderr
        log = home / "notifications"
        count = len(log.read_text().splitlines()) if log.exists() else 0
        assert count == expected, (session, count, expected)

    try:
        for name in ("first", "second"):
            config = root / name
            config.mkdir()
            shutil.copy(source / "qs-shell/NotificationFocus.qml", config)
            (config / "shell.qml").write_text('''import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
  id: root
  property bool viewing: false
  property string selected: ""
  NotificationFocus { active: root.viewing; session: root.selected }
  IpcHandler {
    target: "test"
    function view(session: string): string { root.selected = session; root.viewing = true; return "ok" }
    function leave(): string { root.viewing = false; return "ok" }
  }
}
''')
            output = open(config / "log", "w")
            process = subprocess.Popen(["qs", "-p", str(config)], env=env, stdout=output, stderr=output)
            output.close()
            processes.append(process)
            wait(lambda: (runtime / "quickshell/by-pid" / str(process.pid)).exists() or process.poll() is not None)
            assert process.poll() is None, (config / "log").read_text()
        first, second = processes
        call(first, "view", "selected")
        wait(lambda: marker.exists() and marker.read_text().splitlines() == [str(first.pid), "selected"])
        notified("selected", 0)
        notified("background", 1)
        call(first, "view", "background")
        wait(lambda: marker.read_text().splitlines() == [str(first.pid), "background"])
        notified("selected", 2)
        call(second, "view", "second-session")
        wait(lambda: marker.read_text().splitlines() == [str(second.pid), "second-session"])
        call(first, "leave")
        time.sleep(.1)
        notified("second-session", 2)
        call(second, "leave")
        wait(lambda: marker.read_text() == "")
        notified("second-session", 3)
        call(second, "view", "second-session")
        wait(lambda: marker.read_text().splitlines() == [str(second.pid), "second-session"])
        second.terminate()
        second.wait(timeout=5)
        notified("second-session", 4)
        print("PASS: selected session stays silent; background and blurred sessions notify; instance handoff and dead PID are safe")
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
        for log in root.glob("*/log"):
            text = log.read_text()
            assert "Failed to load configuration" not in text, text
            assert "ReferenceError" not in text and "TypeError" not in text, text
