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
state = {"names": list(BASE), "streaming": None, "extra_turns": 0}
clients = []
lock = threading.Lock()


def sessions():
    out = []
    for n in state["names"]:
        out.append({
            "name": n,
            "status": "streaming" if n == state["streaming"] else "idle",
            "cwd": f"/home/daphen/work/lovable.daphen-{n}",
        })
    return out


def entries_for(sid):
    """A linear parent-linked chain of alternating user/assistant messages."""
    ents, parent = [], None
    n = 12 + state["extra_turns"]
    for i in range(n):
        role = "user" if i % 2 == 0 else "assistant"
        eid = f"{sid}-e{i}"
        text = (f"user message {i//2} in {sid}" if role == "user"
                else f"assistant reply {i//2} in {sid} — " + ("body line. " * 6))
        ents.append({
            "id": eid, "parentId": parent, "type": "message",
            "message": {"role": role, "content": [{"type": "text", "text": text}]},
        })
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
            if t == "get_entries":
                sid = m.get("session")
                ents, leaf = entries_for(sid)
                send(conn, {"type": "response", "command": "get_entries",
                            "session": sid, "data": {"entries": ents, "leafId": leaf}})
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
            elif c == "grow":
                state["extra_turns"] += 2
                broadcast({"type": "message_delta", "session": "every-9001"})
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
