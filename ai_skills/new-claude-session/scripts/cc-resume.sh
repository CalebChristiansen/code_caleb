#!/usr/bin/env bash
# cc-resume — bring a past Claude Code conversation back as a live, detached,
# Remote-Control-armed tmux session, and print the claude.ai/code link.
#
#   cc-resume.sh [opts] <session-uuid | fuzzy query>
#
#   --name NAME     tmux session name (default: resume-<slug of title>)
#   --prompt TEXT   type TEXT into the new session once it is armed
#   --fork          branch a COPY off the conversation instead of continuing
#                   it: same history, new session id, original untouched and
#                   free to keep running. Safe on a live session, including
#                   the one calling this (query "self").
#   --force         resume even if the conversation is already running
#                   somewhere (kills the existing tmux session first)
#   --list [N]      just list the N most recent sessions and exit
#
# Exit codes: 0 ok · 2 ambiguous/no match (candidates on stdout) · 4 already
# live (its link is on stdout — reconnect instead) · 5 untrusted directory.
#
# Why a wrapper rather than `caleb_claude --detach --resume <uuid>`:
#   - `claude --resume` will cheerfully start a SECOND process on a
#     conversation that is already running. Both then write one transcript and
#     both claim the same bridge id, so the phone link becomes a coin flip.
#     Resuming something already live is a reconnect, and a reconnect is just
#     the link it already has.
#   - Resume is not cwd-scoped (a uuid is found from anywhere), but the
#     resumed session inherits the *caller's* cwd, which silently repoints the
#     conversation at a different project. We cd back to where it was.
#   - A resumed session should land in the same directory, under a name that
#     says which conversation it is, without the caller having to think about
#     either.
# (The opening prompt itself is caleb_claude's problem: claude v2.1.270 drops
#  a positional prompt under --remote-control, so CC_PROMPT types it in with
#  send-keys once the bridge is up.)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST="$HERE/cc-sessions.py"
SESSIONS_DIR="$HOME/.claude/sessions"

NAME=""; PROMPT=""; FORCE=0; FORK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --name)   NAME="$2"; shift 2 ;;
        --prompt) PROMPT="$2"; shift 2 ;;
        --fork)   FORK=1; shift ;;
        --force)  FORCE=1; shift ;;
        --list)   shift; exec "$LIST" list -n "${1:-5}" ;;
        --)       shift; break ;;
        -*)       echo "cc-resume: unknown option $1" >&2; exit 64 ;;
        *)        break ;;
    esac
done
[ $# -ge 1 ] || { echo "usage: cc-resume.sh [opts] <uuid|query>" >&2; exit 64; }
QUERY="$*"

# "self"/"this" means the conversation calling this script, found by the tmux
# session it is sitting in. Only forking makes sense there — "continuing"
# yourself is just carrying on typing.
case "$QUERY" in
    self|this|me)
        me="$(tmux display-message -p '#S' 2>/dev/null || true)"
        [ -n "$me" ] || { echo "cc-resume: \"$QUERY\" only works from inside tmux" >&2; exit 64; }
        QUERY="$(SELF_TMUX="$me" python3 "$HERE/cc-sessions.py" self 2>/dev/null || true)"
        [ -n "$QUERY" ] || { echo "cc-resume: cannot tell which conversation this is" >&2; exit 64; }
        FORK=1 ;;
esac

# ---- resolve the query to exactly one conversation -------------------------
# A clear winner is one that outscores the runner-up by a wide margin. Anything
# closer than that is the caller's problem: print the shortlist and let a human
# pick, rather than guessing at a conversation and resuming the wrong one.
ROW="$("$LIST" match "$QUERY" -n 5 --json 2>/dev/null || true)"
RESOLVED="$(python3 - "$ROW" <<'PY'
import json, sys
try:
    rows = json.loads(sys.argv[1] or "[]")
except Exception:
    rows = []
if not rows:
    sys.exit(3)
top = rows[0]
runner = rows[1]["_score"] if len(rows) > 1 else 0.0
# uuid hits score 1000 and are never ambiguous
if top["_score"] < 1000 and runner > 0 and top["_score"] < runner * 1.5:
    sys.exit(2)
print(json.dumps(top))
PY
)" || {
    rc=$?
    if [ "$rc" = 3 ]; then
        echo "No session matches \"$QUERY\". Recent sessions:"
    else
        echo "\"$QUERY\" is a toss-up between these. Pick one by uuid:"
    fi
    "$LIST" match "$QUERY" -n 5 2>/dev/null || "$LIST" list -n 5
    exit 2
}

field() { printf '%s' "$RESOLVED" | python3 -c \
    "import json,sys; v=json.load(sys.stdin).get('$1'); print('' if v is None else v)"; }

UUID="$(field uuid)"; TITLE="$(field title)"; CWD="$(field cwd)"
LIVE="$(field live)"; LINK="$(field link)"; TMUXS="$(field tmux)"

# ---- already running? that is a reconnect, not a resume --------------------
if [ "$LIVE" = "True" ] && [ "$FORCE" = 0 ] && [ "$FORK" = 0 ]; then
    echo "already live: $TITLE"
    echo "session:  ${TMUXS:-?}"
    echo "attach:   tmux attach -t ${TMUXS:-?}"
    if [ -n "$LINK" ]; then
        echo "link:     $LINK"
        # A reconnect that came with an instruction still wants the
        # instruction. Type it at the session that is already there.
        if [ -n "$PROMPT" ] && [ -n "$TMUXS" ]; then
            tmux send-keys -t "$TMUXS" C-u          # drop any restored draft
            sleep 0.3
            tmux send-keys -t "$TMUXS" -l -- "$PROMPT"
            sleep 1
            tmux send-keys -t "$TMUXS" Enter
            echo "prompt:   sent to the running session"
        fi
        echo "(This conversation is already running. That link IS the reconnect;"
        echo " resuming it a second time would put two processes on one transcript."
        echo " Pass --force to kill the running one and resume it fresh.)"
        exit 0
    fi
    echo "link:     none — it is running but its bridge never armed."
    echo "          Look at it (tmux attach -t ${TMUXS:-?}) before resuming;"
    echo "          --force will kill it and resume the conversation fresh."
    exit 4
fi
if [ "$LIVE" = "True" ] && [ "$FORK" = 0 ]; then
    [ -n "$TMUXS" ] && tmux kill-session -t "$TMUXS" 2>/dev/null || true
    sleep 2
fi

# ---- where it was living ---------------------------------------------------
[ -d "$CWD" ] || CWD="$HOME"
# A directory Claude has never been trusted in shows a trust prompt, and a
# detached session has nobody to answer it: it waits forever, never arms, and
# reports NOT ARMED 30 seconds later. Cheaper to find out now.
TRUSTED="$(python3 - "$CWD" <<'PY'
import json, os, sys
try:
    cfg = json.load(open(os.path.expanduser("~/.claude.json")))
except Exception:
    print("unknown"); sys.exit()
p = (cfg.get("projects") or {}).get(sys.argv[1])
print("yes" if p and p.get("hasTrustDialogAccepted") else "no")
PY
)"
if [ "$TRUSTED" = "no" ]; then
    echo "cc-resume: $CWD has never been trusted in this account, so a detached"
    echo "           session there would hang on the trust prompt forever."
    echo "           Accept it once in an attached session, or set"
    echo "           projects['$CWD'].hasTrustDialogAccepted in ~/.claude.json."
    exit 5
fi

# ---- name it after what it is ----------------------------------------------
PREFIX=resume; [ "$FORK" = 1 ] && PREFIX=fork
if [ -z "$NAME" ]; then
    slug="$(printf '%s' "$TITLE" | tr '[:upper:]' '[:lower:]' \
            | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-24)"
    slug="${slug%-}"
    NAME="$PREFIX-${slug:-$(printf '%s' "$UUID" | cut -c1-8)}"
fi
base="$NAME"; n=2
while tmux has-session -t "$NAME" 2>/dev/null; do NAME="$base-$n"; n=$((n+1)); done

# ---- go ---------------------------------------------------------------------
cd "$CWD"
# --fork-session replays the history into a NEW session id, so the original
# transcript is never written to by two processes and the original link keeps
# pointing where it always did.
FORKARG=(); [ "$FORK" = 1 ] && FORKARG=(--fork-session)
# CC_CWD pins the directory explicitly: caleb_claude otherwise starts a fresh
# session in CC_REPO, and a resumed conversation belongs where it grew up.
# (It exempts --resume too; this is the belt to that pair of braces.)
OUT="$(CC_SESSION="$NAME" CC_PROMPT="$PROMPT" CC_CWD="$CWD" \
       caleb_claude --detach --resume "$UUID" "${FORKARG[@]}" 2>&1)" \
    || { echo "$OUT"; exit 1; }
if [ "$FORK" = 1 ]; then
    echo "forked:   $TITLE"
    echo "from:     $UUID — untouched, still its own conversation"
else
    echo "resumed:  $TITLE"
    echo "uuid:     $UUID"
fi
echo "$OUT"
