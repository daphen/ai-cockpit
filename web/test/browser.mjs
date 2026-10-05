const base=process.env.CDP_BASE
if(!base)throw new Error('Set CDP_BASE to an isolated test browser')
const version=await(await fetch(base+'/json/version')).json()
const ws=new WebSocket(version.webSocketDebuggerUrl)
let id=0
const pending=new Map()
ws.onmessage=event=>{const message=JSON.parse(event.data);if(message.id){pending.get(message.id)?.(message);pending.delete(message.id)}}
await new Promise(resolve=>ws.onopen=resolve)
const call=(method,params={},sessionId)=>new Promise((resolve,reject)=>{const request=++id;pending.set(request,message=>message.error?reject(new Error(JSON.stringify(message.error))):resolve(message.result));ws.send(JSON.stringify({id:request,method,params,...(sessionId?{sessionId}:{})}))})
try{
for(const scheme of ['light','dark'])for(const url of process.argv.slice(2)){
 const {targetId}=await call('Target.createTarget',{url:'about:blank'})
 const {sessionId}=await call('Target.attachToTarget',{targetId,flatten:true})
 try{
  await call('Emulation.setDeviceMetricsOverride',{width:390,height:844,deviceScaleFactor:1,mobile:true},sessionId)
  await call('Emulation.setEmulatedMedia',{features:[{name:'prefers-color-scheme',value:scheme},{name:'prefers-reduced-motion',value:'reduce'}]},sessionId)
  await call('Page.navigate',{url},sessionId)
  let text=''
  for(let attempt=0;attempt<120;attempt++){
   const result=await call('Runtime.evaluate',{expression:'document.querySelector("#result")?.textContent || "LOADING"',returnByValue:true},sessionId)
   text=result.result?.value??''
   if(text.startsWith('PASS:')||text.startsWith('FAIL:'))break
   await new Promise(resolve=>setTimeout(resolve,100))
  }
  if(!text.startsWith('PASS:'))throw new Error(scheme+' '+url+' '+text)
  console.log(scheme+' '+text)
 }finally{await call('Target.closeTarget',{targetId})}
}
}finally{ws.close()}
