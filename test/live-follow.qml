import QtQuick
import Quickshell
import Quickshell.Io
import "."

ShellRoot {
  id: test
  property int phase: 0
  property int recoveryWaits: 0
  property var snapshot: null
  property string cwd: Quickshell.env("HOME")
  property string source: cwd + "/source.txt"
  property string other: cwd + "/other.txt"
  FileView { id: sourceFile; path: test.source; blockAllReads: true }
  FileView { id: otherFile; path: test.other; blockAllReads: true }
  AgentdState {
    id: state
    configuredSockPaths: [test.cwd + "/absent.sock"]
    selectedSession: rail.selectedRaw
    function send(message) { return true }
  }
  Rail { id: rail; agentd: state; scopeMode: "personal"; nvimSock: test.cwd + "/nvim.sock"; focused: true }
  Connections {
    target: state
    function onEditMarksSnapshot(sid, path, rows, at, line) { test.snapshot = {path: path, rows: rows, at: at, line: line} }
  }
  Process {
    id: editor
    running: true
    command: ["nvim", "--headless", "-u", "NONE", "--listen", rail.nvimSock, "--cmd",
      'lua package.path=' + JSON.stringify(Quickshell.env("COCKPIT_TEST_LUA") + "/?.lua;" + Quickshell.env("COCKPIT_TEST_LUA") + "/?/init.lua;") + '..package.path; require("cockpit").setup(); vim.o.autoread=true']
  }
  Process {
    id: probe
    property var result: null
    command: ["nvim", "--server", rail.nvimSock, "--remote-expr",
      'luaeval("vim.json.encode({path=vim.api.nvim_buf_get_name(0),row=vim.api.nvim_win_get_cursor(0)[1],text=vim.api.nvim_get_current_line(),modified=vim.bo.modified,mode=vim.fn.mode(),flashes=vim.api.nvim_buf_get_extmarks(0,vim.api.nvim_create_namespace([[cockpit-edit-flash:personal/active]]),0,-1,{details=true})})")']
    stdout: StdioCollector { id: response }
    onExited: (code, status) => {
      if (code === 0 && response.text.trim()) result = JSON.parse(response.text)
    }
  }
  Process {
    id: navigate
    stderr: StdioCollector { id: navigationError }
    onExited: (code, status) => { if (code !== 0) throw new Error(navigationError.text) }
  }
  function receive(message) { state.onLine(JSON.stringify(message), 0) }
  function read(sid, id, path, offset, failed) {
    receive({ type: "tool_execution_start", session: sid, toolName: "read", toolCallId: id, args: {path: path, offset: offset} })
    receive({ type: "tool_execution_end", session: sid, toolName: "read", toolCallId: id, isError: !!failed, result: {} })
  }
  function edit(sid, id, path, line, failed) {
    receive({ type: "tool_execution_start", session: sid, toolName: "edit", toolCallId: id, args: {path: path, edits: []} })
    receive({ type: "tool_execution_end", session: sid, toolName: "edit", toolCallId: id, isError: !!failed,
      result: {details: {firstChangedLine: line}} })
  }
  function check(ok, message) { if (!ok) throw new Error(message + ": " + JSON.stringify(probe.result)) }
  Timer {
    interval: 200; repeat: true; running: true
    onTriggered: {
      if (test.phase === 0) {
        sourceFile.setText(Array.from({length: 100}, (_, i) => "line " + (i + 1)).join("\n"))
        otherFile.setText("other\nsecond\n")
        test.receive({type:"roster",sessions:[{id:"active",name:"active",cwd:test.cwd,status:"streaming"},
          {id:"child",name:"child",cwd:test.cwd,parent:"active",status:"streaming"}]})
        rail.jumpToSession("active")
        probe.running = true
      } else if (test.phase === 1) {
        if (probe.result === null) { if (!probe.running) probe.running = true; return }
        test.edit("active", "edit-source", test.source, 64, false)
      } else if (test.phase === 2) {
        probe.result = null; probe.running = true
      } else if (test.phase === 3) {
        if (probe.result === null) return
        test.check(probe.result.path === test.source && probe.result.row === 64, "selected edit did not position the real cursor")
        test.edit("child", "edit-child", test.other, 2, false)
        test.edit("active", "edit-failed", test.other, 2, true)
        test.read("active", "read-other", test.other, 2, false)
        test.read("active", "read-same-file", test.source, 1, false)
        test.receive({type:"tool_execution_start",session:"active",toolName:"read",toolCallId:"image",args:{path:test.other}})
        test.receive({type:"tool_execution_end",session:"active",toolName:"read",toolCallId:"image",result:{content:[{type:"image",data:"AA==",mimeType:"image/png"}]}})
        test.receive({type:"response",command:"get_entries",session:"active",success:true,data:{entries:[
          {type:"message",message:{role:"assistant",content:[{type:"toolCall",id:"old-history",name:"edit",arguments:{path:test.other}}]}},
          {type:"message",message:{role:"toolResult",toolCallId:"old-history",timestamp:1,details:{firstChangedLine:2}}}
        ]}})
      } else if (test.phase === 4) {
        probe.result = null; probe.running = true
      } else if (test.phase === 5) {
        if (probe.result === null) return
        test.check(probe.result.path === test.source && probe.result.row === 64, "read, child, failed edit, or history moved the cursor")
        sourceFile.setText("one\ntwo\nnew actual edit\nsecond inserted line\nfive\n")
        test.receive({type:"tool_execution_start",session:"active",toolName:"edit",toolCallId:"edit-source",
          args:{path:test.source,edits:[{oldText:"line 3",newText:"new actual edit"}]}})
        test.receive({type:"tool_execution_end",session:"active",toolName:"edit",toolCallId:"edit-source",
          result:{details:{diff:"-3 old line\n+3 new actual edit\n+4 second inserted line",firstChangedLine:4}}})
      } else if (test.phase === 6) {
        probe.result = null; probe.running = true
      } else if (test.phase === 7) {
        if (probe.result === null) return
        test.check(probe.result.row === 3 && probe.result.text === "new actual edit", "successful edit did not reload and position the real buffer")
        test.check(probe.result.mode === "n", "edit highlight changed the editor selection mode")
        test.check(probe.result.flashes.length === 2 && probe.result.flashes[0][1] === 2 && probe.result.flashes[1][1] === 3
          && probe.result.flashes.every(mark => mark[3].sign_text.trim() === "▌" && mark[3].sign_hl_group === "CockpitAgentEdit" && !mark[3].hl_group && !mark[3].line_hl_group),
          "actual added lines did not get a gutter marker without a code background")
        var restore = '(function() require("cockpit").follow_remote(' + JSON.stringify(test.cwd) + ','
          + JSON.stringify(test.source) + ',true,nil,' + JSON.stringify(Qt.btoa("new actual edit"))
          + '); vim.wait(1900); vim.api.nvim_buf_set_lines(0,0,1,false,{[[unsaved local work]]}); return true end)()'
        navigate.command = ["nvim", "--server", rail.nvimSock, "--remote-expr", "luaeval(" + JSON.stringify(restore) + ")"]
        navigate.running = true
      } else if (test.phase === 8) {
        if (navigate.running) return
        test.edit("active", "edit-other", test.other, 2, false)
      } else if (test.phase === 9) {
        probe.result = null; probe.running = true
      } else if (test.phase === 10) {
        if (probe.result === null) return
        test.check(probe.result.path === test.source && probe.result.modified, "live follow replaced an unsaved editor buffer")
        test.check(probe.result.flashes.length === 0, "agent changed files but left orange marks on the protected old file")
        var lua = '(function() vim.bo.modified=false; require("cockpit").workspace("personal","active",'
          + JSON.stringify(test.cwd) + ',"","dashboard"); return "" end)()'
        navigate.command = ["nvim", "--server", rail.nvimSock, "--remote-expr", "luaeval(" + JSON.stringify(lua) + ")"]
        navigate.running = true
      } else if (test.phase === 11) {
        if (navigate.running) return
        test.receive({type:"response",command:"get_entries",session:"active",success:true,data:{entries:[
          {type:"message",message:{role:"assistant",content:[{type:"toolCall",id:"restored-history",name:"edit",arguments:{path:test.other}}]}},
          {type:"message",message:{role:"toolResult",toolCallId:"restored-history",timestamp:Date.now(),details:{firstChangedLine:2}}}
        ]}})
      } else if (test.phase === 12) {
        probe.result = null; probe.running = true
      } else if (test.phase === 13) {
        if (probe.result === null) return
        test.check(probe.result.path === test.other && probe.result.row === 2, "history restored the file without its latest changed-line cursor")
        otherFile.setText("other\nsecond\nedit completed after reload\n")
      } else if (test.phase === 14) {
        test.receive({type:"tool_execution_end",session:"active",toolName:"edit",toolCallId:"missing-start",
          result:{details:{patch:"--- " + test.other + "\n+++ " + test.other + "\n",firstChangedLine:3,diff:"+3 edit completed after reload"}}})
      } else if (test.phase === 15) {
        probe.result = null; probe.running = true
      } else {
        if (probe.result === null) return
        if ((probe.result.row !== 3 || probe.result.flashes.length !== 1) && test.recoveryWaits++ < 10) {
          probe.result = null; probe.running = true; return
        }
        test.check(probe.result.row === 3 && probe.result.text === "edit completed after reload" && probe.result.flashes.length === 1,
                   "reload-lost start event prevented completed edit follow and highlighting")
        test.receive({type:"response",command:"get_entries",session:"active",success:true,data:{entries:[
          {type:"message",message:{role:"assistant",content:[{type:"toolCall",id:"history-a",name:"edit",arguments:{path:test.source}}]}},
          {type:"message",message:{role:"toolResult",toolCallId:"history-a",timestamp:1,details:{diff:"+2 first\n+3 second"}}},
          {type:"message",message:{role:"assistant",content:[{type:"toolCall",id:"history-b",name:"edit",arguments:{path:test.source}}]}},
          {type:"message",message:{role:"toolResult",toolCallId:"history-b",timestamp:2,details:{diff:"-2 first\n+4 last"}}}
        ]}})
        test.check(test.snapshot && test.snapshot.path === test.source && JSON.stringify(test.snapshot.rows) === "[2,4]" && test.snapshot.at === 2,
                   "history did not recover cumulative additions with removed lines rebased")
        test.receive({type:"response",command:"get_entries",session:"active",success:true,data:{entries:[
          {type:"message",message:{role:"assistant",content:[{type:"toolCall",id:"written",name:"write",arguments:{path:test.other,content:"one\ntwo\nthree"}}]}},
          {type:"message",message:{role:"toolResult",toolCallId:"written",timestamp:3}}
        ]}})
        test.check(test.snapshot.path === test.other && JSON.stringify(test.snapshot.rows) === "[1,2,3]" && test.snapshot.line === 1,
                   "Pi write without a diff lost its written-line block")
        console.log("PASS: QML → Neovim cursor follow and session-owned gutter blocks;"
                    + " reload-lost start recovery, selected-agent isolation,"
                    + " reads ignored and unsaved work protected")
        Qt.quit()
      }
      test.phase++
    }
  }
}
