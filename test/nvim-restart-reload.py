#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
NVIM = shutil.which("nvim")
QS = shutil.which("qs")


def wait_for(check, seconds=8):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            value = check()
            if value:
                return value
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
        time.sleep(0.05)
    raise AssertionError("timed out waiting for editor lifecycle")


with tempfile.TemporaryDirectory(prefix="cockpit-restart-test-") as directory:
    work = Path(directory)
    runtime = work / "run"
    runtime.mkdir(mode=0o700)
    (work / "bin").mkdir()
    wrapper = work / "bin/nvim"
    wrapper.write_text(f'#!/bin/sh\nexec "{NVIM}" -u NONE -i NONE "$@"\n')
    wrapper.chmod(0o700)
    shell = work / "shell.qml"
    shell.write_text('import QtQuick\nimport Quickshell\nimport Heidr\nShellRoot { FloatingWindow { visible: true; implicitWidth: 640; implicitHeight: 480; TermView { anchors.fill: parent } } }\n')
    env = {k: v for k, v in os.environ.items() if not k.startswith(("COCKPIT_", "HEIDR_")) and k != "WAYLAND_DISPLAY"}
    env.update(HOME=str(work), XDG_RUNTIME_DIR=str(runtime), QT_QPA_PLATFORM="offscreen",
               COCKPIT_INSTANCE="restart-test", PATH=str(work / "bin") + ":" + os.environ["PATH"],
               QML_IMPORT_PATH=str(ROOT / "build/qml"), QML2_IMPORT_PATH=str(ROOT / "build/qml"),
               LD_LIBRARY_PATH=str(ROOT / "build"))
    sock = runtime / "cockpit-nvim-restart-test.sock"
    processes, editors = [], set()

    def rpc(lua):
        result = subprocess.run([NVIM, "--server", str(sock), "--remote-expr", "luaeval(" + json.dumps(lua) + ")"],
                                capture_output=True, text=True, check=True, timeout=2)
        return result.stdout.strip()

    def state():
        return json.loads(rpc('vim.json.encode({pid=vim.fn.getpid(),uis=#vim.api.nvim_list_uis(),text=vim.api.nvim_get_current_line(),modified=vim.bo.modified})'))

    try:
        with (work / "qs.log").open("w") as log:
            process = subprocess.Popen([QS, "-p", str(work)], env=env, stdout=log, stderr=log)
            processes.append(process)
            before = wait_for(lambda: (s if (s := state())["uis"] == 1 else None))
            editors.add(before["pid"])
            rpc('(function() vim.defer_fn(function() vim.cmd("restart") end, 100); return "scheduled" end)()')
            after = wait_for(lambda: (s if (s := state())["pid"] != before["pid"] and s["uis"] == 1 else None))
            editors.add(after["pid"])
            rpc('(function() vim.api.nvim_buf_set_lines(0,0,-1,false,{"unsaved after restart"}); return true end)()')
            loaded = (work / "qs.log").read_text().count("Configuration Loaded")
            with shell.open("a") as file:
                file.write("\n")
            wait_for(lambda: (work / "qs.log").read_text().count("Configuration Loaded") > loaded
                     or "refused live" in (work / "qs.log").read_text() or process.poll() is not None)
            time.sleep(0.3)
            assert process.poll() is None, (work / "qs.log").read_text()
            restored = wait_for(lambda: (s if (s := state())["uis"] == 1 else None))
            assert restored["pid"] == after["pid"] and restored["text"] == "unsaved after restart" and restored["modified"], restored
            assert "refused live" not in (work / "qs.log").read_text(), (work / "qs.log").read_text()
            with (work / "foreign.log").open("w") as foreign_log:
                foreign = subprocess.Popen([QS, "-p", str(work)], env=env, stdout=foreign_log, stderr=foreign_log)
                processes.append(foreign)
                wait_for(lambda: "refused live" in (work / "foreign.log").read_text())
                assert state()["pid"] == after["pid"], "foreign owner replaced the editor"
            print("PASS: native restart → QML reload kept the replacement editor, attached UI and unsaved text; foreign socket still refused")
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for pid in editors:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
