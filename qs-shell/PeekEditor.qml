import QtQuick
import Quickshell
import Quickshell.Io
import QsLib
import Heidr

// A floating read-only Neovim of its own, kept warm so a file opens instantly; q closes it.
Item {
  id: peek
  property string instanceName: "main"
  property color ground: Theme.bg
  property bool warm: false
  property bool open: false
  readonly property string runtime: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
  readonly property string socket: runtime + "/cockpit-peek-" + instanceName + ".sock"
  readonly property string closeFile: runtime + "/cockpit-peek-" + instanceName + ".close"
  property var request: null
  property int attempts: 0
  signal closed()
  visible: open

  function show(file, line) {
    warm = true
    request = { file: file, line: Math.max(1, Number(line) || 1) }
    attempts = 0
    send()
    open = true
    if (term.item) term.item.forceActiveFocus()
  }
  function hide() {
    if (!open) return
    open = false
    closed()
  }
  function send() {
    var lua = '(function() local p=' + JSON.stringify(request.file.path) + '; local alt=' + JSON.stringify(request.file.alternate || "")
      + '; if vim.fn.filereadable(p)~=1 and alt~="" then p=alt end'
      + '; vim.cmd("silent! edit " .. vim.fn.fnameescape(p)); if not vim.bo.modified then vim.cmd("silent! edit!") end'
      // lualine loads on the first file read and turns the status line back on.
      + '; pcall(function() require("lualine").hide({ unhide = false }) end); vim.o.laststatus = 0'
      + '; pcall(vim.api.nvim_win_set_cursor, 0, {' + request.line + ', 0}); vim.cmd("normal! zz"); return "" end)()'
    opener.command = ["nvim", "--server", socket, "--remote-expr", "luaeval(" + JSON.stringify(lua) + ")"]
    opener.running = true
  }

  Process {
    id: server
    running: peek.warm
    command: ["nvim", "--headless", "--listen", peek.socket, "-c",
      "lua local f = " + JSON.stringify(peek.closeFile) + "; vim.fn.writefile({}, f); vim.o.swapfile = false; vim.o.hidden = true; vim.opt.shortmess:append('IA')"
        + "; vim.keymap.set('n', 'q', function() if vim.bo.modified then vim.notify('Unsaved changes: :w to save, :e! to drop', vim.log.levels.WARN) return end"
        + " vim.fn.writefile({tostring(vim.uv.hrtime())}, f) end)"]
    environment: ({ COCKPIT_COCKPIT: null, HEIDR_COCKPIT: null, NVIM: null, NVIM_LISTEN_ADDRESS: null,
                    COCKPIT_NVIM_SOCK: null, TERM: "xterm-256color", COLORTERM: "truecolor" })
    // A reload starts the new peek before the old one exits, so the socket can be briefly taken.
    onRunningChanged: if (!running && peek.warm) restart.start()
  }
  Timer { id: restart; interval: 500; onTriggered: server.running = true }
  Process {
    id: opener
    onExited: code => { if (code !== 0 && peek.open && ++peek.attempts < 20) retry.start() }
  }
  Timer { id: retry; interval: 150; onTriggered: peek.send() }
  FileView {
    path: peek.closeFile
    watchChanges: true
    printErrors: false
    onFileChanged: peek.hide()
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.alpha(peek.ground, 0.75)
    TapHandler { onTapped: peek.hide() }
  }
  Rectangle {
    id: panel
    objectName: "peekPanel"
    width: Math.min(parent.width - 64, 1400); height: parent.height - 48
    anchors.centerIn: parent
    radius: 14
    color: peek.ground
    border.width: 1; border.color: Qt.alpha(Theme.fg, 0.14)
    Loader {
      id: term
      anchors { fill: parent; margins: 10 }
      active: peek.warm
      sourceComponent: TermView {
        nvimSocket: peek.socket
        active: activeFocus
      }
    }
  }
}
