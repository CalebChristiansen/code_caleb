#!/usr/bin/env python3
"""List / fuzzy-match past Claude Code sessions on this box.

Every conversation leaves a transcript at
~/.claude/projects/<slugified-cwd>/<session-uuid>.jsonl, and every *live*
process leaves a state file at ~/.claude/sessions/<pid>.json. This joins the
two so a session can be named by its title rather than by a UUID nobody has
ever typed from memory.

  cc-sessions.py list  [-n N] [--json]     most-recent-first
  cc-sessions.py match <query> [-n N] [--json]
  cc-sessions.py self                     uuid of the conversation running in
                                          tmux session $SELF_TMUX (or $TMUX)

`match` prints the ranked candidates; the caller decides whether the top one
won by enough to act on it. Exit 0 with rows, 3 with none.
"""
import json, os, re, sys, time, argparse, difflib, subprocess

HOME = os.path.expanduser("~")
PROJECTS = os.path.join(HOME, ".claude", "projects")
SESSIONS = os.path.join(HOME, ".claude", "sessions")

# Transcripts from the nightly `claude -p` usage probe are not conversations
# anyone wants back.
SKIP_DIR = re.compile(r"^-tmp-claude-usage-|^-$")

# Lines worth JSON-parsing. The rest of a 3 MB transcript is tool output.
WANTED = ('"ai-title"', '"last-prompt"', '"bridge-session"',
          '"queue-operation"', '"type":"user"', '"summary"')


def live_sessions():
    """pid state files -> {session-uuid: {...}} for processes still alive."""
    out = {}
    if not os.path.isdir(SESSIONS):
        return out
    for fn in os.listdir(SESSIONS):
        if not fn.endswith(".json"):
            continue
        try:
            with open(os.path.join(SESSIONS, fn)) as fh:
                st = json.load(fh)
        except Exception:
            continue
        pid = st.get("pid")
        try:
            os.kill(int(pid), 0)          # signal 0: "does this pid exist"
        except Exception:
            continue                       # stale state file, process is gone
        sid = st.get("sessionId")
        if not sid:
            continue
        tmux = (st.get("tmux") or "").split(":")[0]
        out[sid] = {
            "pid": pid,
            "tmux": tmux,
            "name": st.get("name"),
            "status": st.get("status"),
            "bridge": st.get("bridgeSessionId"),
        }
    return out


def scan(path):
    """Pull the handful of interesting facts out of one transcript."""
    info = {"title": None, "last_prompt": None, "first_prompt": None,
            "bridge": None, "cwd": None, "branch": None, "turns": 0,
            "any_prompt": None}
    try:
        with open(path, errors="replace") as fh:
            for line in fh:
                if not any(w in line for w in WANTED):
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                t = rec.get("type")
                if t == "ai-title":
                    info["title"] = rec.get("aiTitle") or info["title"]
                elif t == "last-prompt":
                    info["last_prompt"] = rec.get("lastPrompt")
                elif t == "summary" and not info["title"]:
                    info["title"] = rec.get("summary")
                elif t == "bridge-session":
                    info["bridge"] = rec.get("bridgeSessionId") or info["bridge"]
                elif t == "queue-operation" and rec.get("operation") == "enqueue":
                    c = rec.get("content") or ""
                    info["any_prompt"] = info["any_prompt"] or c
                    if not info["first_prompt"] and not c.startswith("/"):
                        info["first_prompt"] = c
                elif t == "user":
                    info["turns"] += 1
                    if not info["cwd"]:
                        info["cwd"] = rec.get("cwd")
                        info["branch"] = rec.get("gitBranch")
                    if not info["first_prompt"]:
                        c = (rec.get("message") or {}).get("content")
                        if isinstance(c, str):
                            txt = c
                        elif isinstance(c, list):
                            txt = " ".join(b.get("text", "") for b in c
                                           if isinstance(b, dict) and b.get("type") == "text")
                        else:
                            txt = ""
                        txt = re.sub(r"<[^>]+>", " ", txt)       # strip system-reminder tags
                        txt = " ".join(txt.split())
                        if txt and not txt.startswith("Caveat:"):
                            info["any_prompt"] = info["any_prompt"] or txt
                            if not txt.startswith("/"):
                                info["first_prompt"] = txt
    except OSError:
        pass
    return info


def unslug(dirname):
    """'-home-user-project' -> '/home/user/project' (best effort: the
    slug is lossy, real dashes and separators look identical)."""
    return dirname.replace("-", "/") if dirname.startswith("-") else dirname


def collect(limit):
    live = live_sessions()
    files = []
    if os.path.isdir(PROJECTS):
        for d in os.listdir(PROJECTS):
            if SKIP_DIR.match(d):
                continue
            p = os.path.join(PROJECTS, d)
            if not os.path.isdir(p):
                continue
            for fn in os.listdir(p):
                if fn.endswith(".jsonl"):
                    f = os.path.join(p, fn)
                    try:
                        files.append((os.path.getmtime(f), f, d, fn[:-6]))
                    except OSError:
                        pass
    files.sort(reverse=True)

    rows = []
    for mtime, path, d, uuid in files:
        if len(rows) >= limit:
            break
        info = scan(path)
        if info["turns"] == 0:
            continue                       # empty / aborted, nothing to resume
        l = live.get(uuid)
        rows.append({
            "uuid": uuid,
            "mtime": mtime,
            "when": time.strftime("%Y-%m-%d %H:%M", time.localtime(mtime)),
            "ago": ago(mtime),
            "cwd": info["cwd"] or unslug(d),
            "branch": info["branch"],
            "title": pick_title(info),
            "last_prompt": trunc(clean_prompt(info["last_prompt"]
                                 or info["first_prompt"]
                                 or info["any_prompt"]), 110),
            "turns": info["turns"],
            "was_remote": bool(info["bridge"]),
            "live": bool(l),
            "tmux": (l or {}).get("tmux"),
            "live_name": (l or {}).get("name"),
            "live_status": (l or {}).get("status"),
            "link": ("https://claude.ai/code/" + l["bridge"])
                    if l and l.get("bridge") else None,
        })
    return rows


def pick_title(info):
    """`ai-title` is usually right, but a session opened with a slash command
    gets titled after the command — "/clear clear" describes nothing. Fall
    back to the first prompt that was actually a sentence."""
    t = (info["title"] or "").strip()
    if t and not t.startswith("/"):
        return trunc(t, 70)
    for cand in (info["first_prompt"], info["last_prompt"], t,
                 info["any_prompt"]):
        cand = clean_prompt(cand)
        if cand:
            return trunc(cand, 70)
    return "(untitled)"


def clean_prompt(s):
    """A skill invocation arrives as <command-name>/foo</command-name> plus
    echoes of itself; stripping the tags leaves "foo /foo". Collapse that back
    to the command, which at least names what the session was doing."""
    s = " ".join((s or "").split())
    m = re.match(r"^(\S+)\s+/\1\b(.*)$", s)
    if m:
        s = ("/" + m.group(1) + " " + m.group(2)).strip()
    return s


def ago(ts):
    s = max(0, time.time() - ts)
    for unit, n in (("d", 86400), ("h", 3600), ("m", 60)):
        if s >= n:
            return "%d%s ago" % (s // n, unit)
    return "just now"


def trunc(s, n):
    s = " ".join((s or "").split())
    return s if len(s) <= n else s[: n - 1] + "…"


def _best_ratio(tok, words):
    """Closest fuzzy match for one token among a bag of words."""
    best = 0.0
    for w in words:
        if len(w) < 3:
            continue
        r = difflib.SequenceMatcher(None, tok, w).ratio()
        if r > best:
            best = r
    return best


def _words(s):
    return [w for w in re.split(r"[^a-z0-9]+", (s or "").lower()) if w]


def score(row, query):
    """Cheap fuzzy rank. Substring hits beat fuzzy hits; the session's own
    name and title beat anything dredged out of the prompt text; recency only
    breaks ties. Typos and half-remembered names are the normal input here —
    'jellyswarm' has to find 'Jellyswarrm' — so exact matching alone is not
    enough."""
    q = query.lower().strip()
    if not q:
        return 0.0
    hay_title = (row["title"] or "").lower()
    hay_name = " ".join(filter(None, [row.get("live_name") or "",
                                      row.get("tmux") or ""])).lower()
    hay_rest = " ".join([row.get("last_prompt") or "", row.get("cwd") or ""]).lower()

    if q == row["uuid"] or row["uuid"].startswith(q):
        return 1000.0

    s = 0.0
    if q in hay_name:
        s += 60
    if q in hay_title:
        s += 50
    if q in hay_rest:
        s += 15

    w_name, w_title, w_rest = _words(hay_name), _words(hay_title), _words(hay_rest)
    for t in [t for t in _words(q) if len(t) > 2]:
        if t in w_name:
            s += 20
        elif _best_ratio(t, w_name) >= 0.78:
            s += 12
        if t in w_title:
            s += 14
        else:
            r = _best_ratio(t, w_title)
            if r >= 0.82:
                s += 11          # 'jellyswarm' -> 'jellyswarrm'
            elif r >= 0.7:
                s += 5           # 'debug' -> 'debugging'
        if t in w_rest:
            s += 3
        elif _best_ratio(t, w_rest) >= 0.85:
            s += 1

    if s:
        s += min(5.0, 5.0 / (1 + (time.time() - row["mtime"]) / 86400))
    return s


def fmt(rows, show_score=False):
    out = []
    for i, r in enumerate(rows, 1):
        flags = []
        if r["live"]:
            flags.append("LIVE" + (" " + r["tmux"] if r["tmux"] else ""))
        if r["link"]:
            flags.append("armed")
        elif r["was_remote"]:
            flags.append("was-remote")
        tag = ("  [" + ", ".join(flags) + "]") if flags else ""
        sc = ("  (%.0f)" % r["_score"]) if show_score and "_score" in r else ""
        out.append("%d. %s%s%s" % (i, r["title"], tag, sc))
        out.append("   %s · %s · %s · %d turns · %s"
                   % (r["ago"], r["when"], r["cwd"], r["turns"], r["uuid"]))
        if r["last_prompt"]:
            out.append("   last: %s" % r["last_prompt"])
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["list", "match", "self"])
    ap.add_argument("query", nargs="*")
    ap.add_argument("-n", type=int, default=5)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    if a.cmd == "self":
        # Which conversation is calling? The tmux session name is the only
        # handle a shell inside the pane reliably has on itself.
        want = os.environ.get("SELF_TMUX")
        if not want:
            try:
                want = subprocess.run(["tmux", "display-message", "-p", "#S"],
                                      capture_output=True, text=True,
                                      timeout=5).stdout.strip()
            except Exception:
                want = ""
        for sid, st in live_sessions().items():
            if st["tmux"] and st["tmux"] == want:
                print(sid)
                return 0
        return 3

    # Scan a wider pool than we return: the best title match may not be the
    # most recent thing on disk.
    rows = collect(max(a.n, 40))

    if a.cmd == "match":
        q = " ".join(a.query)
        for r in rows:
            r["_score"] = score(r, q)
        rows = [r for r in rows if r["_score"] > 0]
        rows.sort(key=lambda r: (-r["_score"], -r["mtime"]))
    rows = rows[: a.n]

    if a.json:
        print(json.dumps(rows, indent=2))
    else:
        print(fmt(rows, show_score=(a.cmd == "match")))
    return 0 if rows else 3


if __name__ == "__main__":
    sys.exit(main())
