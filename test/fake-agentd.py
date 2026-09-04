#!/usr/bin/env python3
"""A fake agentd, so the rail can be tested deterministically.

Speaks just enough of the protocol for AgentdState.qml: a roster, get_entries
responses, and streaming events. Runs a scripted timeline so a test can assert
what the cursor does when a session APPEARS BEFORE the anchored one — the exact
condition that made an index-based cursor slide onto the wrong session.
"""
import json, os, socket, sys, threading, time

SOCK = sys.argv[1] if len(sys.argv) > 1 else "/tmp/fake-agentd.sock"

BASE = ["alpha-1000", "every-9001", "zulu-9999"]
state = {"names": list(BASE), "streaming": None, "extra_turns": 0, "entry_delay": 0.0, "transcript_ask": None,
         "live_ask": None, "user_bash": None}
clients = []
lock = threading.Lock()


def sessions():
    out = []
    for n in state["names"]:
        session = {
            "name": n,
            "status": "streaming" if n == state["streaming"] else "idle",
            "cwd": f"/home/daphen/work/lovable.daphen-{n}",
        }
        if n == "every-9001" and state["live_ask"]:
            session["ask"] = state["live_ask"]
        out.append(session)
    return out


def entries_for(sid):
    """A linear parent-linked chain of alternating user/assistant messages."""
    ents, parent = [], None
    n = 12 + state["extra_turns"]
    for i in range(n):
        role = "user" if i % 2 == 0 else "assistant"
        eid = f"{sid}-e{i}"
        text = (f"user message {i//2} in {sid}" if role == "user"
                else f"assistant reply {i//2} in {sid} — see https://example.com/pr-{i} and `inline{i}` — " + ("body line. " * 6))
        ents.append({
            "id": eid, "parentId": parent, "type": "message",
            "message": {"role": role, "content": [{"type": "text", "text": text}]},
        })
        parent = eid
    # An ask_user living in the TRANSCRIPT (with or without its result) — what the rail's
    # stale-notice recovery walks. Distinct from the live extension_ui_request event.
    if state["transcript_ask"]:
        eid = f"{sid}-ask"
        ents.append({"id": eid, "parentId": parent, "type": "message",
                     "message": {"role": "assistant", "content": [{
                         "type": "toolCall", "id": "call_fake_ask", "name": "ask_user",
                         "arguments": {"title": "T-stale: proceed?", "message": "from transcript"}}]}})
        parent = eid
        if state["transcript_ask"] == "answered":
            eid = f"{sid}-askr"
            ents.append({"id": eid, "parentId": parent, "type": "message",
                         "message": {"role": "user", "content": [{
                             "type": "toolResult", "toolCallId": "call_fake_ask",
                             "content": [{"type": "text", "text": "approved"}]}]}})
            parent = eid
    if state["user_bash"] in ("approved", "declined"):
        eid = f"{sid}-user-bash"
        ents.append({"id": eid, "parentId": parent, "type": "message",
                     "message": {"role": "assistant", "content": [{
                         "type": "toolCall", "id": "call_fake_user_bash", "name": "request_user_bash",
                         "arguments": {"command": "printf immutable-command", "reason": "prove exact execution"}}]}})
        parent = eid
        if state["user_bash"] == "approved":
            eid = f"{sid}-user-bash-approval"
            ents.append({"id": eid, "parentId": parent, "type": "custom",
                         "customType": "cockpit-user-bash-approval",
                         "data": {"command": "printf immutable-command", "decision": "approved"}})
            parent = eid
        eid = f"{sid}-user-bash-result"
        result = "Command completed with exit status 0.\nimmutable-command" if state["user_bash"] == "approved" else "Command declined; nothing was executed."
        ents.append({"id": eid, "parentId": parent, "type": "message",
                     "message": {"role": "toolResult", "toolCallId": "call_fake_user_bash",
                                 "content": [{"type": "text", "text": result}], "isError": False}})
        parent = eid
    return ents, parent


def send(conn, obj):
    try:
        conn.sendall((json.dumps(obj) + "\n").encode())
    except OSError:
        pass


def broadcast(obj):
    with lock:
        for c in list(clients):
            send(c, obj)


def push_roster():
    broadcast({"type": "roster", "sessions": sessions()})


def serve(conn):
    with lock:
        clients.append(conn)
    send(conn, {"type": "roster", "sessions": sessions()})
    buf = b""
    while True:
        try:
            data = conn.recv(1 << 16)
        except OSError:
            break
        if not data:
            break
        buf += data
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if not line.strip():
                continue
            try:
                m = json.loads(line)
            except ValueError:
                continue
            t = m.get("type")
            if t in ("prompt", "steer"):
                with open(SOCK + ".answers", "a") as fh:
                    fh.write(json.dumps(m) + "\n")
            if t == "stop":
                with open(SOCK + ".answers", "a") as fh:
                    fh.write(json.dumps(m) + "\n")
                sid = m.get("session", "")
                state["names"] = [n for n in state["names"] if n != sid]
                if state["streaming"] == sid:
                    state["streaming"] = None
                push_roster()
            if t == "abort":
                with open(SOCK + ".answers", "a") as fh:
                    fh.write(json.dumps(m) + "\n")
                state["streaming"] = None
                broadcast({"type": "agent_end", "session": m.get("session", "")})
                push_roster()
            if t in ("answer", "extension_ui_response"):
                with open(SOCK + ".answers", "a") as fh:
                    fh.write(json.dumps(m) + "\n")
                sid = m.get("session", "every-9001")
                response = m.get("response", m)
                if response.get("confirmed") is not None and state["user_bash"] == "pending":
                    state["user_bash"] = "approved" if response.get("confirmed") else "declined"
                state["live_ask"] = None
                answered = {"type": "ask_answered", "session": sid}
                for key in ("confirmed", "value", "cancelled"):
                    if key in response:
                        answered[key] = response[key]
                broadcast(answered)
                broadcast({"type": "turn_end", "session": sid})
                push_roster()
            if t == "get_entries":
                sid = m.get("session")

                def answer(sid=sid, conn=conn, d=state["entry_delay"]):
                    # Off-thread so the delay widens the WINDOW without stalling this
                    # connection: the point is to keep stream ticks arriving while the
                    # switched-to session still has no rows, which is when the rail used
                    # to spend its jump-to-end on a roster row.
                    if d:
                        time.sleep(d)
                    ents, leaf = entries_for(sid)
                    send(conn, {"type": "response", "command": "get_entries",
                                "session": sid, "data": {"entries": ents, "leafId": leaf}})

                threading.Thread(target=answer, daemon=True).start()
    with lock:
        if conn in clients:
            clients.remove(conn)


CMD = SOCK + ".cmd"


def driver():
    """Poll a command file so a test drives each phase and asserts between them —
    fixed sleeps raced the client's connect and made the phases uncorrelated."""
    open(CMD, "w").close()
    pos = 0
    while True:
        time.sleep(0.2)
        try:
            with open(CMD) as f:
                f.seek(pos)
                lines = f.readlines()
                pos = f.tell()
        except OSError:
            continue
        for line in lines:
            c = line.strip()
            if not c:
                continue
            if c == "insert":
                state["names"] = ["aaa-inserted"] + list(BASE)
            elif c == "remove":
                state["names"] = list(BASE)
            elif c == "stream_on":
                state["streaming"] = "every-9001"
            elif c == "stream_off":
                state["streaming"] = None
            elif c == "long_user":
                text = "\n".join([
                    "Pasted review notes for the implementation:",
                    "First line keeps the existing public behavior.",
                    "Second line removes the duplicate state path.",
                    "Third line verifies the current production caller.",
                    "Fourth line covers the failed response branch.",
                    "Fifth line preserves the existing authorization check.",
                    "Sixth line keeps the test at the public boundary.",
                    "Seventh line avoids adding another protocol.",
                    "Screenshots: @.heidr-pastes/img7.png and @.heidr-pastes/img8.png",
                ])
                broadcast({"type": "prompt_accepted", "session": "every-9001", "message": text})
            elif c == "ask":
                state["live_ask"] = {"title": "T-live: proceed?", "method": "confirm"}
                push_roster()
                broadcast({"type": "extension_ui_request", "session": "every-9001",
                           "method": "confirm", "id": "fake-live-1",
                           "title": "T-live: proceed?", "message": "live question"})
            elif c == "user_bash":
                state["user_bash"] = "pending"
                state["live_ask"] = {"title": "__cockpit_user_bash__", "method": "confirm"}
                push_roster()
                broadcast({"type": "extension_ui_request", "session": "every-9001",
                           "method": "confirm", "id": "fake-user-bash-1",
                           "title": "__cockpit_user_bash__",
                           "message": json.dumps({"command": "printf immutable-command",
                                                  "cwd": "/tmp/exact cwd", "host": "vm-test",
                                                  "reason": "prove exact execution"})})
            elif c == "ask_in_transcript":
                state["transcript_ask"] = "open"
            elif c == "answer_in_transcript":
                state["transcript_ask"] = "answered"
            elif c.startswith("slow_entries"):
                parts = c.split()
                state["entry_delay"] = float(parts[1]) if len(parts) > 1 else 2.0
            elif c == "tool":
                # the LIVE streaming path: a tool_execution_start lands in the feed as a
                # pushed cmd row inside the streaming turn (what real pi does per tool)
                state.setdefault("tooln", 0)
                state["tooln"] += 1
                broadcast({"type": "tool_execution_start", "session": "every-9001",
                           "toolName": "bash", "toolCallId": f"tc-{state['tooln']}",
                           "args": {"command": f"echo live-tool-{state['tooln']} && sleep 1"}})
            elif c == "plan_metadata":
                for i, path in enumerate(("EVERY-1.progress.json", "EVERY-1.review.json", ".plans/EVERY-1.md", "src/visible.ts")):
                    broadcast({"type": "tool_execution_start", "session": "every-9001",
                               "toolName": "edit", "toolCallId": f"meta-{i}",
                               "args": {"path": path, "oldText": "old", "newText": "new"}})
                    broadcast({"type": "tool_execution_end", "session": "every-9001",
                               "toolCallId": f"meta-{i}", "result": {}})
            elif c == "retry":
                broadcast({"type": "auto_retry_start", "session": "every-9001",
                           "attempt": 1, "maxAttempts": 3, "errorMessage": "529 overloaded_error: Overloaded"})
            elif c == "retry_fail":
                broadcast({"type": "auto_retry_end", "session": "every-9001",
                           "success": False, "attempt": 3, "finalError": "529 overloaded"})
            elif c == "compacting":
                broadcast({"type": "compaction_start", "session": "every-9001"})
                broadcast({"type": "compaction_end", "session": "every-9001"})
            elif c == "toolfail":
                state.setdefault("tooln", 0); state["tooln"] += 1
                tc = f"tf-{state['tooln']}"
                broadcast({"type": "tool_execution_start", "session": "every-9001",
                           "toolName": "bash", "toolCallId": tc, "args": {"command": "false"}})
                broadcast({"type": "tool_execution_end", "session": "every-9001",
                           "toolCallId": tc, "result": {"isError": True}})
            elif c == "grow":
                state["extra_turns"] += 2
                # Both frames, in pi's order. message_delta ALONE is what the fake used to
                # send, and the rail ignores it by design (prose is rebuilt from the
                # authoritative transcript), so new messages only appeared on the rail's 5s
                # safety poll — which reads on screen as "the chat doesn't follow" and is
                # not how a real daemon behaves. turn_end is the frame that lands prose.
                broadcast({"type": "message_delta", "session": "every-9001"})
                broadcast({"type": "turn_end", "session": "every-9001"})
            push_roster()
            print(f"[fake] {c} -> {state['names']} streaming={state['streaming']} turns={12+state['extra_turns']}", flush=True)


if os.path.exists(SOCK):
    os.unlink(SOCK)
srv = socket.socket(socket.AF_UNIX)
srv.bind(SOCK)
srv.listen(8)
print(f"fake agentd on {SOCK}", flush=True)
threading.Thread(target=driver, daemon=True).start()
while True:
    c, _ = srv.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
