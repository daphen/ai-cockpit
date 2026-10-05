import { afterAll, expect, test } from "bun:test"
const originals = Object.fromEntries(["window","location","localStorage","WebSocket","fetch"].map(key => [key,Object.getOwnPropertyDescriptor(globalThis,key)]))
const sockets = []
class Socket {
  static OPEN = 1
  static CONNECTING = 0
  readyState = 1
  sent = []
  constructor() { sockets.push(this) }
  send(text) { this.sent.push(JSON.parse(text)) }
  close() {}
  receive(message) { this.onmessage({data:JSON.stringify(message)}) }
}
Object.assign(globalThis, {
  window: {setTimeout:()=>0,clearTimeout(){},setInterval:()=>0,clearInterval(){}},
  location: {origin:"https://example.test"}, localStorage: {getItem:()=>null,setItem(){}}, WebSocket:Socket,
  fetch:async url => new Response(JSON.stringify(["personal"]),{status:String(url).startsWith("https://example.test/") ? 200 : 503}),
})
afterAll(() => { for (const [key,descriptor] of Object.entries(originals)) { if (descriptor) Object.defineProperty(globalThis,key,descriptor); else delete globalThis[key] } })
const { AgentdStore } = await import("../src/agentd.ts")
async function fixture() {
  const store = new AgentdStore()
  await store.connect("fixture-token")
  const socket = sockets.at(-1)
  socket.onopen()
  socket.receive({type:"roster",sessions:[{name:"ticket",cwd:"/tmp",status:"idle"}]})
  store.select("personal/ticket")
  const receive = message => socket.receive({...message,session:"ticket"})
  const feed = () => store.getSnapshot().feeds["personal/ticket"]
  receive({type:"response",command:"get_entries",data:{entries:[]}})
  return {store,socket,receive,feed}
}
test("history preserves content order and full tool results on the selected branch",async () => {
  const {receive,feed} = await fixture()
  const content = [{type:"text",text:"Before"},{type:"thinking",thinking:"Reasoning"},{type:"toolCall",id:"read",name:"read",arguments:{path:"file.ts"}},{type:"text",text:"After"}]
  const entries = [
    {id:"user",type:"message",message:{role:"user",content:[{type:"text",text:"⇄ worker (user-approved)\nHandoff"}]}},
    {id:"assistant",parentId:"user",type:"message",message:{role:"assistant",timestamp:1,content}},
    {id:"result",parentId:"assistant",type:"message",message:{role:"toolResult",toolCallId:"read",content:[{type:"text",text:"Whole file"}],details:{lineCount:4}}},
    {id:"excluded",parentId:"user",type:"message",message:{role:"assistant",content:[{type:"text",text:"Wrong branch"}]}},
  ]
  receive({type:"response",command:"get_entries",data:{entries,leafId:"result"}})
  expect(feed()[0]).toMatchObject({kind:"user",sender:"worker",text:"Handoff"})
  expect(feed()[1].items.map(item=>item.kind)).toEqual(["text","thinking","activity","text"])
  expect(feed()[1].items[2].activity).toMatchObject({args:{path:"file.ts"},result:"Whole file",details:{lineCount:4},partial:false})
  expect(feed()).toHaveLength(2)
})
test("live assistant updates replace in place and tool completion survives later deltas",async () => {
  const {receive,feed} = await fixture()
  const message = {role:"assistant",timestamp:10,content:[{type:"text",text:"Starting"},{type:"toolCall",id:"run",name:"bash",arguments:{command:"pwd"}}]}
  receive({type:"message_start",message})
  receive({type:"message_update",message:{...message,content:[{...message.content[0],text:"Starting now"},message.content[1]]}})
  receive({type:"tool_execution_start",toolCallId:"run",toolName:"bash",args:{command:"pwd"}})
  receive({type:"tool_execution_update",toolCallId:"run",partialResult:{content:[{type:"text",text:"partial"}]}})
  expect(feed()[0].items[1].activity.result).toBe("partial")
  receive({type:"tool_execution_end",toolCallId:"run",result:{content:[{type:"text",text:"/tmp"}],details:{exitCode:0}}})
  receive({type:"message_end",message})
  expect(feed()).toHaveLength(1)
  expect(feed()[0].items[1].activity).toMatchObject({label:"pwd",result:"/tmp",partial:false,details:{exitCode:0}})
})
test("accepted prompts appear once and history never appends a stale optimistic echo",async () => {
  const {store,receive,feed} = await fixture()
  store.submit("personal/ticket","Unique steer")
  expect(feed()).toHaveLength(0)
  receive({type:"prompt_accepted",message:"Unique steer",steered:true})
  expect(feed()).toHaveLength(1)
  expect(feed()[0].steered).toBe(true)
  receive({type:"response",command:"get_entries",data:{entries:[{id:"native-user",message:{role:"user",content:[{type:"text",text:"Unique steer"}]}}]}})
  expect(feed()).toHaveLength(1)
})
test("answer completes only after acknowledgment, and rejected answers retain the question",async () => {
  const {store,receive} = await fixture()
  receive({type:"extension_ui_request",method:"confirm",id:"ask-1",title:"Continue?"})
  let accepted = false
  const answer = store.answer("personal/ticket",{approved:true}).then(()=>{accepted=true})
  await Promise.resolve()
  expect(accepted).toBe(false)
  receive({type:"ask_answered"})
  await answer
  expect(accepted).toBe(true)
  expect(store.getSnapshot().asks["personal/ticket"]).toBeUndefined()
  receive({type:"extension_ui_request",method:"confirm",id:"ask-2",title:"Try again?"})
  const rejected = store.answer("personal/ticket",{approved:true})
  receive({type:"error",error:"Not accepted"})
  await expect(rejected).rejects.toThrow("Not accepted")
  expect(store.getSnapshot().asks["personal/ticket"].title).toBe("Try again?")
})
