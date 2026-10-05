import {cpSync, mkdirSync} from 'node:fs'
import {spawnSync} from 'node:child_process'
import {resolve} from 'node:path'
const base=process.env.CDP_BASE
const origin=process.env.PWA_TEST_ORIGIN
const served=process.env.PWA_TEST_DIR
if(!base||!origin||!served)throw new Error('Set CDP_BASE, PWA_TEST_ORIGIN and PWA_TEST_DIR to an isolated browser and static test server')
const version=await(await fetch(base+'/json/version')).json()
const ws=new WebSocket(version.webSocketDebuggerUrl)
let id=0
const pending=new Map()
ws.onmessage=event=>{const message=JSON.parse(event.data);if(message.id){pending.get(message.id)?.(message);pending.delete(message.id)}}
await new Promise(resolve=>ws.onopen=resolve)
const call=(method,params={},sessionId)=>new Promise((resolve,reject)=>{const request=++id;pending.set(request,message=>message.error?reject(new Error(JSON.stringify(message.error))):resolve(message.result));ws.send(JSON.stringify({id:request,method,params,...(sessionId?{sessionId}:{})}))})
const {browserContextId}=await call('Target.createBrowserContext')
const {targetId}=await call('Target.createTarget',{url:'about:blank',browserContextId})
const {sessionId}=await call('Target.attachToTarget',{targetId,flatten:true})
const evaluate=async expression=>{const result=await call('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true},sessionId);if(result.exceptionDetails)throw new Error(JSON.stringify(result.exceptionDetails));return result.result.value}
const waitFor=async expression=>{for(let n=0;n<100;n++){if(await evaluate(expression))return;await new Promise(resolve=>setTimeout(resolve,100))}throw new Error('Timeout: '+expression)}
try{
 await call('Page.navigate',{url:origin},sessionId)
 await waitFor('Boolean(navigator.serviceWorker.controller)')
 const first=await evaluate('navigator.serviceWorker.controller.scriptURL')
 if(!first.endsWith('/sw.js'))throw new Error('Worker URL is not stable: '+first)
 const build=spawnSync('npm',['run','build'],{cwd:resolve('web'),stdio:'inherit'})
 if(build.status!==0)throw new Error('Second production build failed')
 mkdirSync(served,{recursive:true});cpSync(resolve('web/dist'),served,{recursive:true})
 await evaluate('window.dispatchEvent(new PageTransitionEvent("pageshow",{persisted:true}))')
 await waitFor('Boolean(document.querySelector(".update-toast"))')
 await waitFor('navigator.serviceWorker.getRegistration().then(registration=>Boolean(registration.waiting))')
 await evaluate('document.querySelector(".update-toast button").click()')
 await waitFor('navigator.serviceWorker.getRegistration().then(registration=>Boolean(registration?.active)&&!registration.waiting&&!registration.installing&&!document.querySelector(".update-toast"))')
 console.log('PASS: production PWA detects a new build on resume, shows update & reload, activates the waiting worker and reloads')
}finally{await call('Target.disposeBrowserContext',{browserContextId});ws.close()}
