import { useEffect, useLayoutEffect, useRef, useState } from "react"
import { AnimatePresence } from "motion/react"
import * as m from "motion/react-m"
import type { Activity, FeedItem, TurnItem } from "./agentd"
import { LoadingIndicator } from "./LoadingIndicator"
import { MessageIcon } from "./MessageIcon"
import { iconSwap, textSwap } from "./motion"

export function Feed({ items, pinToEnd = false }: { items?: FeedItem[]; pinToEnd?: boolean }) {
  const feed = useRef<HTMLDivElement>(null)
  const following = useRef(true)
  const loaded = items !== undefined
  const display: FeedItem[] = []
  for (const item of items ?? []) {
    const previous = display.at(-1)
    if (item.kind === "turn" && previous?.kind === "turn") display[display.length-1] = {...previous,items:[...previous.items,...item.items]}
    else display.push(item)
  }
  const scrollToEnd = () => { const node = feed.current; if (node) node.scrollTop = node.scrollHeight }
  useLayoutEffect(() => { if (following.current) scrollToEnd() }, [items])
  useLayoutEffect(() => {
    if (!pinToEnd) return
    following.current = true
    scrollToEnd()
    requestAnimationFrame(scrollToEnd)
  }, [pinToEnd])
  useEffect(() => {
    const sent = () => { following.current = true; requestAnimationFrame(scrollToEnd) }
    const resized = () => { if (following.current) requestAnimationFrame(scrollToEnd) }
    window.addEventListener("cockpit:message-sent",sent)
    window.addEventListener("cockpit:viewport-change",resized)
    return () => {
      window.removeEventListener("cockpit:message-sent",sent)
      window.removeEventListener("cockpit:viewport-change",resized)
    }
  }, [])
  return (
    <div className={`feed-stage t-skel ${loaded ? "is-revealed" : ""}`} aria-busy={!loaded}>
      <div className="feed-loader t-skel-skeleton" aria-hidden={loaded}><LoadingIndicator label="loading messages" /></div>
      <div className="feed t-skel-content" ref={feed} aria-live="polite" onScroll={() => {
        const node = feed.current
        if (node) following.current = node.scrollHeight - node.scrollTop - node.clientHeight <= 1
      }}>
        <AnimatePresence initial={false}>
          {!items?.length && <m.div className="empty feed-empty" key="empty" variants={textSwap} initial="initial" animate="animate" exit="exit">No messages yet. Start the conversation below.</m.div>}
        </AnimatePresence>
        {display.map(item => item.kind === "user" ? <UserMessage item={item} key={item.key} />
          : item.kind === "system" ? <article className={`system-turn ${item.tone ?? ""}`} key={item.key}><p>{plain(item.text).replace(/^(?:·|🔌)\s*/,"")}</p></article>
          : item.items.length ? <m.article className="turn-card agent-turn" key={item.key} variants={iconSwap} initial="initial" animate="animate"><TurnContent items={item.items} /></m.article> : null)}
        <div className="feed-end-spacer" aria-hidden="true" />
      </div>
    </div>
  )
}

function UserMessage({ item }: { item: Extract<FeedItem,{kind:"user"}> }) {
  const [expanded,setExpanded] = useState(false)
  return <m.article className={`turn-card ${item.sender ? "handoff-turn" : "user-turn"}`} variants={iconSwap} initial="initial" animate="animate">
    <header className="turn-header"><MessageIcon sender={item.sender ? "agent" : "user"} /><strong>{item.sender ? `From ${item.sender}` : "You"}</strong>{item.steered && <span className="steer-cap">steer</span>}</header>
    {item.sender && <button className="handoff-toggle" onClick={() => setExpanded(!expanded)}>{expanded ? "Hide full message" : "Show full message"}</button>}
    <p className={`turn-copy ${item.sender && !expanded ? "handoff-preview" : ""}`}>{item.text}</p>
  </m.article>
}

type FileRow = { path: string; calls: Activity[] }
type RenderRow = TurnItem | {kind:"files"; files: FileRow[]}
const editTools = new Set(["edit","write","create","str_replace"])
function TurnContent({ items }: {items: TurnItem[]}) {
  const rows: RenderRow[] = []
  for (const item of items) {
    if (item.kind !== "activity" || !editTools.has(item.activity.tool)) { rows.push(item); continue }
    const path = String(item.activity.args.path ?? item.activity.args.file_path ?? item.activity.args.filePath ?? "file")
    let last = rows.at(-1)
    if (last?.kind !== "files") { last = {kind:"files",files:[]}; rows.push(last) }
    const file = last.files.find(file => file.path === path)
    if (file) file.calls.push(item.activity)
    else last.files.push({path,calls:[item.activity]})
  }
  return rows.map((row,index) => row.kind === "text" ? <Prose text={row.text} key={index} />
    : row.kind === "thinking" ? <details className="thinking-row" key={index}><summary><ToolIcon tool="thinking" />Reasoning</summary><div className="thinking-copy">{row.text}</div></details>
    : row.kind === "activity" ? <ToolRow activity={row.activity} key={row.activity.id ?? index} />
    : row.files.length === 1 ? <FileChange file={row.files[0]} key={index} />
    : <section className="file-table" key={index}>
      <header><ToolIcon tool="edit" /><span>File changes · {row.files.length} files</span><Diff calls={row.files.flatMap(file => file.calls)} /></header>
      {row.files.map(file => <FileChange file={file} key={file.path} />)}
    </section>)
}

function counts(activity: Activity) {
  if (activity.failed || activity.partial) return [0,0]
  if (typeof activity.details?.diff === "string") {
    const lines = activity.details.diff.split("\n")
    return [lines.filter(line => line.startsWith("+") && !line.startsWith("+++")).length,lines.filter(line => line.startsWith("-") && !line.startsWith("---")).length]
  }
  return [activity.tool === "write" || activity.tool === "create" ? String(activity.args.content ?? "").split("\n").length : 0,0]
}
function Diff({calls}:{calls:Activity[]}) {
  const total = calls.reduce((total,call) => { const [add,del] = counts(call); return [total[0]+add,total[1]+del] },[0,0])
  return <span className="file-diff"><span>+{total[0]}</span><span>−{total[1]}</span></span>
}
function FileChange({file}:{file:FileRow}) {
  const last = file.calls.at(-1)!
  const combined: Activity = {...last,label:file.path,result:file.calls.map(call => call.result).filter(Boolean).join("\n\n"),failed:file.calls.some(call => call.failed),details:file.calls.length > 1 ? {calls:file.calls.map(call => ({tool:call.tool,details:call.details}))} : last.details,args:file.calls.length > 1 ? {path:file.path,edits:file.calls.map(call => call.args)} : last.args}
  return <ToolRow activity={combined} diff={combined.failed ? <span className="file-diff">Failed</span> : <Diff calls={file.calls} />} />
}

function plain(text:string) { return text.replace(/\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\))/g,"").replace(/\r\n?/g,"\n").replace(/[\x00-\x08\x0b-\x1f\x7f]/g,"") }
function failure(activity:Activity) {
  const text = plain(activity.result)
  const json = text.match(/(\{[\s\S]*\})/)
  let message = "", status = "", title = ""
  if (json) { try { const data = JSON.parse(json[1]); message = typeof data.message === "string" ? data.message : ""; title = typeof data.error === "string" ? data.error.replace(/_/g," ") : ""; title = title.charAt(0).toUpperCase()+title.slice(1); status = data.status ? `HTTP ${data.status}` : "" } catch {} }
  if (!message) message = text.split("\n").filter(line => /^\s*(?:(?:\w+\.)*\w*Error:|(?:WARN|ERROR)\b.*?Error:|fatal:|gh:|bash:|rg:|Permission denied|Tool call .*not executed|edits\[\d+\]|Found \d+ occurrences|could not|cannot|timed out|not found)/i.test(line)).at(-1)?.replace(/^.*?Error:\s*/i,"") ?? ""
  if (!message && !["bash","shell","read","edit","write","create","grep","ripgrep"].includes(activity.tool)) message = text.split("\n")[0] ?? ""
  const exit = activity.details?.exitCode ?? text.match(/Command exited with code\s+(-?\d+)/)?.[1]
  return (title ? `${title}\n` : "") + [message || "Command failed",status,exit !== undefined ? `Exit code ${exit}` : ""].filter(Boolean).join(" · ")
}
function formatted(text:string) { try { return JSON.stringify(JSON.parse(plain(text)),null,2) } catch { return plain(text) } }
function ToolRow({activity,diff}:{activity:Activity;diff?:React.ReactNode}) {
  const shell = ["bash","shell"].includes(activity.tool)
  return <div className="tool-entry"><details className={`tool-row ${shell ? "shell-row" : ""} ${activity.failed ? "failed" : ""}`} data-tool-id={activity.id}>
    <summary><ToolIcon tool={activity.tool} /><span className="tool-line" title={activity.label}>{plain(activity.label)}{activity.failed && activity.tool !== "error" && !diff ? " — failed" : ""}</span>{diff}</summary>
    <div className="tool-detail">
      {!!Object.keys(activity.args).length && <details><summary>Arguments</summary><pre>{JSON.stringify(activity.args,null,2)}</pre></details>}
      {activity.result && <><pre className="tool-output">{formatted(activity.result)}</pre>{!["read","read_file"].includes(activity.tool) && <button onClick={() => void navigator.clipboard.writeText(plain(activity.result))}>Copy output</button>}</>}
      {activity.details && <details><summary>Details</summary><pre>{JSON.stringify(activity.details,null,2)}</pre></details>}
    </div>
  </details>{activity.failed && activity.result && <p className="tool-error">{failure(activity)}</p>}</div>
}

function Prose({text}:{text:string}) {
  const blocks = text.split(/(```[^\n]*\n[\s\S]*?(?:```|$))/g)
  return <div className="turn-copy agent-copy">{blocks.map((block,index) => {
    if (block.startsWith("```")) return <pre className="code-block" key={index}><code>{block.replace(/^```[^\n]*\n/,"").replace(/```$/,"")}</code></pre>
    return block.split(/(`[^`\n]+`|\*\*[^*\n]+\*\*)/g).map((part,at) => part.startsWith("`") ? <code key={`${index}-${at}`}>{part.slice(1,-1)}</code> : part.startsWith("**") ? <strong key={`${index}-${at}`}>{part.slice(2,-2)}</strong> : part)
  })}</div>
}
function ToolIcon({tool}:{tool:string}) {
  const path = ["bash","shell"].includes(tool) ? "M2 4h20v16H2z M5 8h2m3 0h2m3 0h2M5 12h2m3 0h2m3 0h2M7 16h10"
    : editTools.has(tool) ? "M4 3h16v18H4z M12 7v10M7 12h10"
    : ["read","read_file"].includes(tool) ? "M5 2h10l4 4v16H5z M9 10h6M9 14h6M9 18h6"
    : tool === "error" ? "M12 3 2 21h20z M12 9v5m0 3v1"
    : tool === "thinking" ? "m9 5 7 7-7 7" : "M12 3v18M3 12h18"
  return <svg className="tool-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={path}/></svg>
}
