import QtQuick
import QtTest
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  property string opened: ""
  AgentdState { id: state; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow {
    visible: true; width: 720; height: 1200
    Rail {
      id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; instanceName: "stream-landing-test"; focused: true
      onRequestFocus: forceActiveFocus()
      function openFileRef(path) { test.opened = String(path) }
      TestEvent { id: input }
    }
  }
  TestCase { id: gui; when: false }
  function check(value,message) { if (!value) { console.log("Error: " + message); Qt.exit(1); throw new Error(message) } }
  function find(item,predicate) {
    if (!item || !item.visible) return null
    if (predicate(item)) return item
    for (var child of item.children || []) { var match = find(child,predicate); if (match) return match }
    return null
  }
  function named(prefix) { return find(rail,item => String(item.objectName || "").indexOf(prefix) === 0) }
  function key(k) { gui.wait(20); input.keyClick(k,Qt.NoModifier,0) }
  function event(message) { state.onLine(JSON.stringify(Object.assign({session:"worker"},message)),0) }
  property int before: 0
  function update(ev, extra) { event(Object.assign({type:"message_update", message:{role:"assistant", model:"anthropic/claude-opus-5-5"}, assistantMessageEvent: ev}, extra || {})) }
  readonly property var a1: ({role:"assistant", model:"anthropic/claude-opus-5-5", content:[{type:"thinking", thinking:"**Looking at the file** I should list it."},{type:"text", text:longText},{type:"toolCall", id:"t1", name:"bash", arguments:{command:"ls"}}]})
  readonly property var a2: ({role:"assistant", model:"anthropic/claude-opus-5-5", content:[{type:"text", text:"All done, the file is fine."}]})
  function transcript(done) {
    var e = [{type:"message",id:"u1",parentId:null,message:{role:"user",content:[{type:"text",text:"look at it"}]}},
             {type:"message",id:"x1",parentId:"u1",message:a1},
             {type:"message",id:"r1",parentId:"x1",message:{role:"toolResult",toolCallId:"t1",toolName:"bash",content:[{type:"text",text:"a\nb"}]}}]
    if (done) e.push({type:"message",id:"x2",parentId:"r1",message:a2})
    return {type:"response",command:"get_entries",data:{leafId: done ? "x2" : "r1", entries:e}}
  }
  readonly property string longText: "Checking the file first. " + Array.from({length: 12}, (_, n) => "This sentence " + n + " explains a little more.").join(" ")
  function cards(item, out) {
    if (!item) return out
    if (item.waitsForProse !== undefined && item.turn !== undefined) out.push(item)
    for (var c of item.children || []) cards(c, out)
    return out
  }
  property int overlap: 0
  property int shrank: 0
  property bool detailsSeen: false
  property bool detailsEarly: false
  function shown(item) { for (var i = item; i; i = i.parent) if (!i.visible) return false; return true }
  function details(item, out) {
    if (!item) return out
    if (String(item.objectName).indexOf("work-details:") === 0 && shown(item)) out.push(item)
    for (var c of item.children || []) details(c, out)
    return out
  }
  property var lastLen: ({})
  function reveals(item, out, think) {
    if (!item) return out
    if (item.reveal !== undefined && item.reveal && (think ? item.reveal.counted !== undefined && item.parts === undefined : item.parts !== undefined)) out.push(item.reveal)
    for (var c of item.children || []) reveals(c, out, think)
    return out
  }
  function typing(r) { return r.text.length > 0 && r.shown < r.full.length }
  Timer {
    interval: 16; repeat: true; running: test.phase >= 4 && test.phase < 40
    onTriggered: {
      var prose = test.reveals(rail, [], false), thinks = test.reveals(rail, [], true)
      if (prose.some(test.typing) && thinks.some(test.typing)) test.overlap++
      if (!test.detailsSeen && test.details(rail, []).length) { test.detailsSeen = true; test.detailsEarly = thinks.some(test.typing) }
      var lens = {}
      prose.forEach((r, i) => { lens[i] = r.text.length; if (test.lastLen[i] !== undefined && r.full.length >= r.text.length && r.text.length < test.lastLen[i] && r.full.startsWith(r.text)) test.shrank++ })
      test.lastLen = lens
    }
  }
  property string reply: ""
  Timer {
    interval: 120; repeat: true; running: true
    onTriggered: {
      var p = phase++
      if (p === 0) {
        for (var k = 0; k < 14; k++) reply += "This first reply is long enough to keep typing for a while after it lands. "
        event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"}]})
        rail.jumpToSession("worker")
        event({type:"response",command:"get_entries",data:{leafId:"u1",entries:[{type:"message",id:"u1",parentId:null,message:{role:"user",content:[{type:"text",text:"look at it"}]}}]}})
      } else if (p === 4) {
        event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"streaming"}]})
        event({type:"agent_start"}); event({type:"message_start", message:{role:"assistant",model:"anthropic/claude-opus-5-5",content:[]}})
        update({type:"thinking_start", contentIndex:0})
        update({type:"thinking_delta", contentIndex:0, delta:"**Looking at the file** I should list it first, then check every entry against what the plan expects, note anything surprising, and only then decide whether the rest of the work needs to change at all."})
      } else if (p === 6) {
        update({type:"text_start", contentIndex:1})
        update({type:"text_delta", contentIndex:1, delta:reply})
        update({type:"toolcall_start", contentIndex:2, partial:{content:[{},{},{type:"toolCall",name:"bash",arguments:{command:"ls"}}]}})
        event({type:"message_end", message:{role:"assistant",model:"anthropic/claude-opus-5-5",content:[{type:"thinking",thinking:"**Looking at the file** I should list it first, then check every entry against what the plan expects, note anything surprising, and only then decide whether the rest of the work needs to change at all."},{type:"text",text:reply},{type:"toolCall",id:"t1",name:"bash",arguments:{command:"ls"}}]}})
        event({type:"tool_execution_start", toolCallId:"t1", toolName:"bash", args:{command:"ls"}})
        event({type:"tool_execution_end", toolCallId:"t1", toolName:"bash", result:{content:[{type:"text",text:"a"}]}})
        event({type:"message_start", message:{role:"assistant",model:"anthropic/claude-opus-5-5",content:[]}})
        update({type:"thinking_start", contentIndex:0})
        update({type:"thinking_delta", contentIndex:0, delta:"**Checking the result** The listing shows one file, which is what I expected to see here."})
      } else if (p === 9) {
        update({type:"text_start", contentIndex:1})
        update({type:"text_delta", contentIndex:1, delta:"All done, the file is fine."})
      } else if (p === 11) {
        event({type:"message_end", message:{role:"assistant",model:"anthropic/claude-opus-5-5",content:[{type:"thinking",thinking:"**Checking the result** The listing shows one file, which is what I expected to see here."},{type:"text",text:"All done, the file is fine."}]}})
        event({type:"agent_end"})
        event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle"}]})
      } else if (p === 40) {
        check(shrank === 0, "a reply already on screen was blanked and retyped (" + shrank + " frames)")
        check(detailsSeen, "setup: the Work details row never appeared")
        check(!detailsEarly, "the tool rows appeared while the reasoning above them was still typing")
        check(overlap === 0, "reasoning and the reply typed at the same time (" + overlap + " frames)")
        console.log("PASS: across a whole turn, reasoning and the reply never type at the same time, and tools wait for the reasoning")
        Qt.quit()
      }
    }
  }
}
