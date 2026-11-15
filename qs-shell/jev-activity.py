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


def score(card, key):
    lines = []
    for f in card["files"]:
        name = f["path"].rsplit("/", 1)[-1]
        lines += [f"[{name}] {t}" for t in f["lines"]]
    question = ("This piece of agent work is important for someone reviewing what happened today: a new capability, a changed interface, "
                "or a fix of a user-visible bug, rather than a cosmetic tweak, rename, test-only edit, notes or constant nudge.")
    state = {"ask": card.get("ask", ""), "outcome": card.get("outcome", ""),
             "files": sorted({f["path"] for f in card["files"]}), "diff": lines[:MAX_LINES]}
    request = urllib.request.Request("https://api.typesafe.ai/v1/systemone", method="POST",
                                     data=json.dumps({"model": "jev-latest", "state": state,
                                                      "questions": {"key": {"type": "noul", "instructions": question}}}).encode(),
                                     headers={"authorization": f"Bearer {key}", "content-type": "application/json"})
    return {"key": json.load(urllib.request.urlopen(request, timeout=20))["answers"]["key"]["noul"]}


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
