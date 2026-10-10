import QtQuick
import QtTest
import Quickshell
import "."
ShellRoot {
  id: test
  property int phase: 0
  AgentdState { id: state; selectedSession: rail.selectedRaw; function send(message) { return true } }
  FloatingWindow {
    visible: true; width: 720; height: 1000
    Rail {
      id: rail; anchors.fill: parent; agentd: state; scopeMode: "personal"; focused: true
      TestEvent { id: input }
    }
  }
  function check(value, message) { if (!value) throw new Error(message) }
  function find(item, text) {
    if (!item || item.visible === false) return null
    if (item.text === text) return item
    for (var child of item.children || []) { var found = find(child, text); if (found) return found }
    return null
  }
  function label(text) { return find(rail, text) }
  function event(message) { state.onLine(JSON.stringify(message), 0) }
  function click(item) { check(!!item, "missing disclosure"); input.mouseClick(item, 5, item.height/2, Qt.LeftButton, Qt.NoModifier, 0) }
  function live(model, text) {
    event({type:"message_start",session:"worker",message:{role:"assistant",model:model}})
    event({type:"message_update",session:"worker",message:{role:"assistant",model:model},assistantMessageEvent:{type:"thinking_start",contentIndex:0}})
    event({type:"message_update",session:"worker",message:{role:"assistant",model:model},assistantMessageEvent:{type:"thinking_delta",contentIndex:0,delta:text}})
  }
  Timer {
    interval: 250; repeat: true; running: true
    onTriggered: {
      if (test.phase === 0) {
        test.event({type:"roster",sessions:[{id:"worker",name:"worker",cwd:"/tmp",status:"idle",model:"openai/gpt-6.1-sol"}]})
        rail.jumpToSession("worker")
        test.event({type:"response",command:"get_entries",session:"worker",data:{leafId:"gpt",entries:[
          {type:"message",id:"u",parentId:null,message:{role:"user",content:"Mixed history"}},
          {type:"message",id:"claude",parentId:"u",message:{role:"assistant",model:"claude-opus-5-5",content:[{type:"thinking",thinking:"Claude history\nFull historical explanation"}]}},
          {type:"message",id:"gpt",parentId:"claude",message:{role:"assistant",model:"gpt-6.1-sol",content:[{type:"thinking",thinking:"GPT history\nHidden explanation"}]}}
        ]}})
      } else if (test.phase === 2) {
        test.check(test.label("Claude history\nFull historical explanation"), "Claude history is not fully exposed")
        test.check(!test.label("GPT history") && !test.label("GPT history\nHidden explanation"), "GPT history exposed with Claude in the same turn")
        test.click(test.label("Reasoning"))
      } else if (test.phase === 3) {
        test.check(!test.label("Claude history\nFull historical explanation"), "Claude disclosure cannot collapse")
        test.click(test.label("Reasoning"))
      } else if (test.phase === 4) {
        test.check(test.label("Claude history\nFull historical explanation") && test.label("GPT history"), "manual disclosure cannot reveal both models")
        test.event({type:"prompt_accepted",session:"worker",message:"New Claude turn"})
        test.live("claude-sonnet-4-6", "Claude live\nFull streamed explanation")
      } else if (test.phase === 6) {
        test.check(test.label("Claude live\nFull streamed explanation"), "Claude streaming reasoning hidden or truncated")
        test.event({type:"message_end",session:"worker",message:{role:"assistant",model:"claude-sonnet-4-6",content:[{type:"thinking",thinking:"Claude live\nFinal explanation"}]}})
        test.event({type:"prompt_accepted",session:"worker",message:"Switch to GPT"})
        test.live("gpt-6.1-sol", "GPT live\nHidden streamed explanation")
      } else if (test.phase === 8) {
        test.check(test.label("Claude live\nFinal explanation"), "ending or switching models hid the previous Claude thought")
        test.check(!test.label("GPT live") && !test.label("GPT live\nHidden streamed explanation"), "GPT streaming reasoning exposed")
        test.event({type:"message_end",session:"worker",message:{role:"assistant",model:"gpt-6.1-sol",content:[{type:"thinking",thinking:"GPT live\nFinal hidden explanation"}]}})
      } else if (test.phase === 9) {
        test.check(!test.label("GPT live") && !test.label("GPT live\nFinal hidden explanation"), "completed GPT reasoning exposed")
        console.log("PASS: Claude reasoning visible in history and streaming; GPT hidden across mixed messages and model switches; manual disclosure preserved")
        Qt.quit()
      }
      test.phase++
    }
  }
}
