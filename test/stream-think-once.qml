import QtQuick
import Quickshell
import "."
ShellRoot {
  AgentdState { id: state; selectedSession: "worker"; function send(message) { return true } }
  function ev(m) { state.onLine(JSON.stringify(Object.assign({session:"worker"}, m)), 0) }
  function up(e) { ev({type:"message_update", message:{role:"assistant", model:"m"}, assistantMessageEvent: e}) }
  function kinds() { return (state.feeds["worker"] || []).filter(i => i.kind !== "cmd").map(i => i.kind + (i.kind === "think" ? ":" + i.text : "")).join(" | ") }
  function message(think, text) {
    ev({type:"message_start", message:{role:"assistant",model:"m",content:[]}})
    up({type:"thinking_start", contentIndex:0}); up({type:"thinking_delta", contentIndex:0, delta:"**" + think + "** more"})
    up({type:"text_start", contentIndex:1}); up({type:"text_delta", contentIndex:1, delta:text})
    up({type:"toolcall_start", contentIndex:2, partial:{content:[{},{},{type:"toolCall",name:"bash",arguments:{command:"ls"}}]}})
    ev({type:"message_end", message:{role:"assistant",model:"m",content:[{type:"thinking",thinking:"**" + think + "** more"},{type:"text",text:text},{type:"toolCall",id:think,name:"bash",arguments:{command:"ls"}}]}})
  }
  Component.onCompleted: {
    ev({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"streaming"}]})
    ev({type:"agent_start"})
    message("First", "One")
    message("Second", "Two")
    var want = "think:First | text | think:Second | text", got = kinds()
    if (got !== want) { console.log("Error: reasoning was repeated or reordered when the message finished: " + got); Qt.exit(1); return }
    console.log("PASS: reasoning stays one row above its reply when a message with tool calls finishes")
    Qt.quit()
  }
}
