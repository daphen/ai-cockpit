import QtQuick
import Quickshell
import Quickshell.Io
import QsLib

Process {
  required property string nvimSocket
  readonly property string themeMode: Theme.mode
  command: ["nvim", "--server", nvimSocket, "--remote-expr", "luaeval(" + JSON.stringify(
    '(function() local p=os.getenv("XDG_RUNTIME_DIR").."/cockpit-ipc."..vim.v.servername:match("[^/]+$")..".id";'
    + 'local t=p.."."..vim.fn.getpid()..".tmp";local fd=assert(vim.uv.fs_open(t,"w",384));'
    + 'assert(vim.uv.fs_write(fd,' + JSON.stringify(Quickshell.instanceId) + '));vim.uv.fs_close(fd);'
    + 'assert(vim.uv.fs_rename(t,p));vim.g.cockpit_theme_mode=' + JSON.stringify(themeMode) + ';'
    + 'vim.cmd.colorscheme("custom-theme-"..vim.g.cockpit_theme_mode);return "" end)()') + ")"]
  running: false
  Component.onCompleted: Qt.callLater(() => running = nvimSocket.length > 0)
  function refresh() { running = false; Qt.callLater(() => running = nvimSocket.length > 0) }
  onNvimSocketChanged: refresh()
  onThemeModeChanged: refresh()
  stderr: SplitParser { onRead: data => console.warn("Cockpit IPC binding: " + data) }
}
