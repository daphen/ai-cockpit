import concurrent.futures
import json
import os
import pathlib
import subprocess
import sys
import urllib.request

CACHE = pathlib.Path(os.environ.get("XDG_CACHE_HOME") or pathlib.Path.home() / ".cache") / "cockpit" / "jev-activity.json"
MAX_LINES = 40


def api_key():
    key = os.environ.get("TYPESAFEAI_API_KEY", "").strip()
    if key:
        return key
    try:
        return subprocess.run(["fish", "--no-config", "-c",
                               "source ~/.config/fish/secrets.fish >/dev/null 2>/dev/null; or exit 1; printf '%s' \"$TYPESAFEAI_API_KEY\""],
                              capture_output=True, text=True, timeout=3).stdout.strip()
    except Exception:
        return ""


def score(change, key):
    lines = []
    for fi, f in enumerate(change["files"]):
        for li, text in f["lines"]:
            if len(lines) < MAX_LINES:
                lines.append((fi, li, text))
    questions = {"key": {"type": "noul", "instructions":
                         "This change is important for someone reviewing what an agent did today: a new capability, a changed interface, "
                         "or a fix of a user-visible bug, rather than a cosmetic tweak, rename, test-only edit or constant nudge."}}
    for i, _ in enumerate(lines):
        questions[f"l{i}"] = {"type": "noul", "instructions":
                              f"Diff line {i} is one of the two or three lines that best show what this change does, given its reason; "
                              "not supporting, mechanical or incidental."}
    state = {"reason": change.get("why", ""), "files": [f["path"] for f in change["files"]],
             "diff": [f"{i}: [{change['files'][fi]['path'].rsplit('/', 1)[-1]}] {t}" for i, (fi, _, t) in enumerate(lines)]}
    request = urllib.request.Request("https://api.typesafe.ai/v1/systemone", method="POST",
                                     data=json.dumps({"model": "jev-latest", "state": state, "questions": questions}).encode(),
                                     headers={"authorization": f"Bearer {key}", "content-type": "application/json"})
    answers = json.load(urllib.request.urlopen(request, timeout=20))["answers"]
    picks = sorted(((answers[f"l{i}"]["noul"], fi, li) for i, (fi, li, _) in enumerate(lines)), reverse=True)[:3]
    return {"key": answers["key"]["noul"], "picks": [[fi, li] for p, fi, li in picks if p >= 0.5]}


def main():
    changes = json.loads(sys.argv[1])
    try:
        cache = json.loads(CACHE.read_text())
    except Exception:
        cache = {}
    todo = [c for c in changes if c["id"] not in cache]
    key = api_key() if todo else ""
    if key:
        with concurrent.futures.ThreadPoolExecutor(8) as pool:
            for c, result in zip(todo, pool.map(lambda c: _safe(score, c, key), todo)):
                if result:
                    cache[c["id"]] = result
        CACHE.parent.mkdir(parents=True, exist_ok=True)
        tmp = CACHE.with_suffix(".tmp")
        tmp.write_text(json.dumps(cache))
        tmp.replace(CACHE)
    print(json.dumps({c["id"]: cache[c["id"]] for c in changes if c["id"] in cache}))


def _safe(fn, *args):
    try:
        return fn(*args)
    except Exception:
        return None


if __name__ == "__main__":
    main()
