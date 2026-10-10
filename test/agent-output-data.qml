import QtQuick
import Quickshell
import "."

ShellRoot {
  id: test
  property int phase: 0

  AgentdState {
    id: state
    selectedSession: "worker"
    property var sent: []
    function send(message) { sent.push(message); sent = sent.slice(); return true }
  }

  function check(value, message) { if (!value) throw new Error(message) }
  function event(message) { state.onLine(JSON.stringify(message), 0) }
  function rows() { return state.feedFor("worker") }
  function allItems() {
    var out = [], feed = rows()
    for (var i = 0; i < feed.length; i++) {
      var children = feed[i].cmds || feed[i].items || [feed[i]]
      for (var j = 0; j < children.length; j++) out.push(children[j])
    }
    return out
  }
  function byId(id) {
    var items = allItems()
    for (var i = 0; i < items.length; i++) if (items[i].id === id) return items[i]
    return null
  }
  function idCount(id) {
    var items = allItems(), count = 0
    for (var i = 0; i < items.length; i++) if (items[i].id === id) count++
    return count
  }
  function byKey(key) {
    var feed = rows()
    for (var i = 0; i < feed.length; i++) if (feed[i].feedKey === key) return feed[i]
    return null
  }
  function textPresent(text) {
    var items = allItems()
    for (var i = 0; i < items.length; i++)
      if (String(items[i].text || "").indexOf(text) >= 0 || String(items[i].result || "").indexOf(text) >= 0) return true
    return false
  }
  function sentCount(type) {
    var count = 0
    for (var i = 0; i < state.sent.length; i++) if (state.sent[i].type === type) count++
    return count
  }

  Timer {
    interval: 100
    repeat: true
    running: true
    onTriggered: {
      if (phase === 0) {
        state.select("worker")
        check(sentCount("get_entries") === 1 && sentCount("get_session_stats") === 1 && sentCount("get_changes") === 1,
              "select did not request entries, stats, and changes")
        event({type:"response",command:"get_session_stats",session:"worker",success:true,
          data:{tokens:{total:null,input:null},cost:null,contextUsage:{tokens:null,contextWindow:200000,percent:null}}})
        check(!byKey("session-usage"), "missing stats response showed a false usage success row")
        event({type:"response",command:"get_session_stats",session:"worker",success:true,data:{
          tokens:{input:50000,output:10000,cacheRead:40000,cacheWrite:5000,total:105000},cost:0.45,
          contextUsage:{tokens:60000,contextWindow:200000,percent:30}}})
        var usage = byKey("session-usage")
        check(usage && usage.kind === "sys" && usage.tool === "usage", "stats response did not create one usage row")
        check(usage.text.indexOf("105,000 tokens") >= 0 && usage.text.indexOf("$0.4500") >= 0
              && usage.text.indexOf("context 60,000 / 200,000 (30%)") >= 0
              && usage.text.indexOf("input 50,000") >= 0 && usage.text.indexOf("cache write 5,000") >= 0,
              "usage row omitted token, cost, context, or breakdown fields")
        event({type:"tool_execution_start",session:"worker",toolCallId:"mcp-live",toolName:"mcp",
          args:{server:"notes",tool:"lookup",args:{query:"full payload"}}})
        var started = byId("mcp-live")
        check(started && started.partial === true, "tool start did not expose live partial state")
        check(started.argumentsText.indexOf("full payload") >= 0, "tool start lost full JSON arguments")
        event({type:"tool_execution_update",session:"worker",toolCallId:"mcp-live",
          partialResult:{content:[{type:"text",text:"accumulated so far"}],details:{page:1}}})
        var updated = byId("mcp-live")
        check(updated.result === "accumulated so far" && updated.partial === true, "tool update did not replace accumulated result")
        check(updated.detailsText.indexOf("page") >= 0, "tool update lost details")
        event({type:"response",command:"get_entries",session:"worker",data:{leafId:null,entries:[]}})
        check(byId("mcp-live") && byId("mcp-live").result === "accumulated so far", "snapshot refresh dropped live tool progress")
        event({type:"response",command:"get_entries",session:"worker",data:{leafId:"live-a",entries:[
          {type:"message",id:"live-a",parentId:null,message:{role:"assistant",content:[
            {type:"toolCall",id:"mcp-live",name:"mcp",arguments:{server:"notes",tool:"lookup",args:{query:"full payload"}}}
          ]}}
        ]}})
        check(idCount("mcp-live") === 1 && byId("mcp-live").partial === true
              && byId("mcp-live").result === "accumulated so far",
              "snapshot overlap duplicated the live tool or discarded its progress")
        event({type:"tool_execution_end",session:"worker",toolCallId:"mcp-live",toolName:"mcp",isError:false,
          result:{content:[{type:"text",text:"authoritative end"},{type:"record",value:{ok:true}},
                           {type:"image",data:"SECRET_BASE64",mimeType:"image/png",width:40}],details:{page:2}}})
        var ended = byId("mcp-live")
        check(ended.result.indexOf("authoritative end") >= 0 && ended.result.indexOf("record") >= 0, "tool end lost text or structured content")
        check(ended.result.indexOf("SECRET_BASE64") < 0 && ended.result.indexOf("image/png") >= 0, "image result leaked base64 or lost metadata")
        check(ended.detailsText.indexOf("\"page\":2") >= 0 && ended.partial === false && ended.failed === false,
              "tool end fields were not authoritative")
      } else if (phase === 1) {
        event({type:"tool_execution_start",session:"worker",toolCallId:"edit-live",toolName:"edit",
          args:{path:"/tmp/a.qml",edits:[{oldText:"a",newText:"b"}]}})
        event({type:"tool_execution_end",session:"worker",toolCallId:"edit-live",toolName:"edit",isError:true,
          result:{content:[{type:"text",text:"edit failed readably"}],details:{reason:"conflict"}}})
        var edit = byId("edit-live")
        check(edit && edit.kind === "edit" && edit.failed === true && edit.result.indexOf("edit failed") >= 0,
              "edit result/error row was not retained")
        event({type:"message_start",session:"worker",message:{role:"assistant"}})
        event({type:"message_update",session:"worker",assistantMessageEvent:{type:"thinking_start",contentIndex:0}})
        event({type:"message_update",session:"worker",assistantMessageEvent:{type:"thinking_delta",contentIndex:0,delta:"**Inspect contract**\nLive reasoning"}})
        var thought = rows().filter(function(item) { return item.kind === "think" && item.liveThink })[0]
        check(thought && thought.full.indexOf("Live reasoning") >= 0, "thinking delta has no live expandable item")
      } else if (phase === 2) {
        event({type:"extension_ui_request",session:"worker",id:"n",method:"notify",message:"visible notice",notifyType:"warning"})
        event({type:"extension_ui_request",session:"worker",id:"s1",method:"setStatus",statusKey:"build",statusText:"building"})
        event({type:"extension_ui_request",session:"worker",id:"s2",method:"setStatus",statusKey:"build",statusText:"done"})
        event({type:"extension_ui_request",session:"worker",id:"w1",method:"setWidget",widgetKey:"summary",widgetLines:["one","two"],widgetPlacement:"aboveEditor"})
        event({type:"extension_ui_request",session:"worker",id:"t",method:"setTitle",title:"Extension title"})
        event({type:"queue_update",session:"worker",steering:["change direction"],followUp:["afterwards"]})
        check(byKey("extension-status:build").text === "done", "status update appended instead of replacing")
        check(byKey("extension-widget:summary").text === "one\ntwo", "widget content was not visible")
        check(byKey("pi-queue").command.indexOf("change direction") >= 0, "queued message text was lost")
        event({type:"extension_ui_request",session:"worker",id:"w2",method:"setWidget",widgetKey:"summary"})
        check(!byKey("extension-widget:summary"), "cleared widget remained visible")
      } else if (phase === 3) {
        var entries = [
          {type:"message",id:"u",parentId:null,message:{role:"user",content:[{type:"text",text:"snapshot"}]}},
          {type:"message",id:"a",parentId:"u",message:{role:"assistant",content:[
            {type:"toolCall",id:"read-1",name:"read",arguments:{path:"one"}},
            {type:"toolCall",id:"read-2",name:"read",arguments:{path:"two"}},
            {type:"toolCall",id:"read-3",name:"read",arguments:{path:"three"}},
            {type:"toolCall",id:"write-1",name:"write",arguments:{path:"out.txt",content:"hello"}},
            {type:"toolCall",id:"ask-1",name:"ask_user",arguments:{kind:"confirm",title:"Proceed?"}}
          ]}},
          {type:"message",id:"r1",parentId:"a",message:{role:"toolResult",toolCallId:"read-1",content:[{type:"text",text:"first"}],details:{source:1}}},
          {type:"message",id:"r2",parentId:"r1",message:{role:"toolResult",toolCallId:"read-2",content:[{type:"json",value:{second:true}}]}},
          {type:"message",id:"r3",parentId:"r2",message:{role:"toolResult",toolCallId:"read-3",content:[{type:"text",text:"third"}],isError:true}},
          {type:"message",id:"rw",parentId:"r3",message:{role:"toolResult",toolCallId:"write-1",content:[{type:"text",text:"wrote file"}],details:{bytes:5}}},
          {type:"message",id:"ra",parentId:"rw",message:{role:"toolResult",toolCallId:"ask-1",content:[{type:"text",text:"{\"confirmed\":true}"}]}},
          {type:"custom_message",id:"cv",parentId:"ra",customType:"visible",content:"custom visible",details:{tone:"blue"},display:true},
          {type:"custom_message",id:"ch",parentId:"cv",customType:"hidden",content:"custom hidden",display:false},
          {type:"message",id:"bc",parentId:"ch",message:{role:"bashExecution",command:"printf ok",output:"ok\n",exitCode:0,cancelled:false,truncated:false}},
          {type:"message",id:"hidden-role",parentId:"bc",message:{role:"custom",content:"role hidden",displayToUser:false}}
        ]
        event({type:"response",command:"get_entries",session:"worker",data:{leafId:"hidden-role",entries:entries}})
        var first = byId("read-1"), second = byId("read-2"), third = byId("read-3"), write = byId("write-1"), ask = byId("ask-1")
        check(first && second && third, "coalescing dropped grouped tool ids")
        check(first.result === "first" && first.detailsText.indexOf("source") >= 0, "snapshot tool result/details missing")
        check(second.result.indexOf("second") >= 0 && third.failed === true, "structured snapshot result or failure missing")
        check(write && write.kind === "edit" && write.result === "wrote file" && write.detailsText.indexOf("bytes") >= 0,
              "snapshot write result missing")
        check(ask && ask.result.indexOf("confirmed") >= 0 && ask.text.indexOf("approved") >= 0,
              "ask result was not associated with its call")
        check(textPresent("custom visible") && !textPresent("custom hidden") && !textPresent("role hidden"),
              "custom display visibility contract failed")
        var bash = allItems().filter(function(item) { return item.tool === "bash" && item.command === "printf ok" })[0]
        check(bash && bash.result === "ok\n" && bash.failed === false, "bashExecution snapshot output missing")
        check(byKey("extension-status:build") && byKey("pi-queue") && byKey("session-usage"),
              "snapshot rebuild discarded live extension, queue, or usage information")
        var statsRequests = sentCount("get_session_stats")
        event({type:"agent_end",session:"worker"})
        check(sentCount("get_session_stats") === statsRequests + 1, "selected agent_end did not refresh session stats")
        console.log("PASS: agent output data preserves live and rebuilt tools, usage, thinking, extension, queue, custom, and bash information")
        Qt.quit()
      }
      phase++
    }
  }
}
