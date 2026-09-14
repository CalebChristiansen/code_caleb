---
name: new-claude-session
description: Start, resume, reconnect to, or fork a Claude Code session detached in tmux and hand back a claude.ai/code Remote Control link a phone can reach. Use when asked to "open a new shell for Claude", "start another session", "spin up another one", "give me a new session", "I need a second Claude", "run this in a separate session", or when a session link is needed to drive work from a phone. Also for "resume <session>", "reconnect to <session>", "pick up where we left off", "get me back into that <thing> session", "fork this session", "branch this conversation", "make a copy of <session>" — including when the session is named vaguely, wrongly, or not at all. Covers naming sessions, passing an opening prompt, listing and killing sessions, and the failure modes that make a session look alive but be unreachable.
---

# Start, resume, or fork a Claude session

Three verbs, one link at the end of each:

| you want | command |
|---|---|
| a **new** session | `caleb_claude --detach` |
| **that one from earlier**, continued | `scripts/cc-resume.sh "<whatever they called it>"` |
| **a copy** of a session, original left running | `scripts/cc-resume.sh --fork "<name>"` |

Every one of them prints a `https://claude.ai/code/session_…` line. That link is the
whole handoff: tap it and you're talking to the session.

## Install

`scripts/caleb_claude` is the launcher. **Symlink at it, don't copy it** — a copy is
a second thing to fix when something here turns out to be wrong:

```bash
ln -sf "$PWD/scripts/caleb_claude" ~/.local/bin/caleb_claude
ln -sf "$PWD/scripts/caleb_claude" ~/.local/bin/cclaude       # muscle-memory alias
```

It pins the CLI at `$HOME/.npm-global/bin/claude` rather than trusting `PATH` —
override with `CC_CLAUDE_BIN`. Never let it resolve a bare `claude`: a stale
system-wide copy without `--remote-control` dies instantly on an unknown option, the
pane exits, and the failure reads as "the session won't arm".

Everything machine-specific goes in a defaults file, which is why the launcher can be
a symlink to one shared copy. It reads the first of `$CC_CONFIG`,
`~/.config/caleb_claude/config`, `/etc/caleb_claude.conf` that exists, and no file at
all is a supported state:

```bash
# ~/.config/caleb_claude/config — or a symlink to it from wherever you keep such things
CC_REPO="${CC_REPO:-/srv/your-repo}"
```

Every line is a *default*: the `${VAR:-value}` form means an exported variable still
wins, so `CC_REPO=/elsewhere caleb_claude --detach` works for a one-off. `CC_REPO` is
the repo whose `CLAUDE.md` describes the machine — it needs `hasTrustDialogAccepted`
first, see the failure modes below.

It has to be a file rather than something exported from a shell profile, because the
contexts that launch sessions are exactly the ones with no environment worth the name:
cron's threadbare `PATH`, tmux's `/bin/sh -c`, and agent shells, which skip `.bashrc`
entirely. A variable set in `.bashrc` is a variable that is absent everywhere it
matters.

`scripts/cc-resume.sh` and `scripts/cc-sessions.py` stay in the skill directory and are
run by path; they only need `caleb_claude` on `PATH` and `python3`.

If you run a second Claude account on the same machine, it wants its own session
prefix and its own keepalive session name — the two must never collide, because several
long-lived Remote Control processes under one account rotate each other's OAuth refresh
tokens (see the failure modes below). Point it at *this* launcher with its own defaults
file rather than forking a near-twin: the accounts differ in their config, not in their
code. Where the accounts cannot read each other's files a second install is forced on
you, and then **a fix to one has to be hand-carried to the other** — so write down that
it exists, somewhere the drift is visible.

## New session

```bash
caleb_claude --detach
```

Called from `$HOME` — which is where an agent almost always is — it comes up in
**`$CC_REPO`** instead. `CLAUDE.md` is only read from the directory claude actually
starts in, so a session that starts anywhere else is a session that has to be told what
machine it is on. Called from anywhere but `$HOME` it stays put: a deliberate cwd is a
deliberate choice about which project you are in. `CC_CWD=/some/path` overrides either
way and `CC_CWD=.` stays exactly where you are.

Memory is per-directory as well — `~/.claude/projects/<slugged-cwd>/memory` — so moving
where sessions start also moves which memories load, silently and with no error to read.
Symlink the new directory's `memory` at the old one and both share a store.

Name it after what it's for — `caleb_claude-4` tells nobody anything:

```bash
CC_SESSION=vpn-debug caleb_claude --detach "start by reading the wg logs"
```

With `CC_SESSION`, an existing session of that name is **attached to**, not recreated —
a reattach, not a new session, and from inside tmux it fails rather than doing anything
useful. Use a fresh name when you mean a fresh session. Without `CC_SESSION`, each bare
launch grabs the first free `caleb_claude[-N]`.

A trailing non-flag argument is an opening instruction, typed in with `send-keys` once
the bridge arms (claude drops a positional prompt under `--remote-control`; see below).
`CC_PROMPT=…` sets one without relying on argument position.

## Resume / reconnect

```bash
scripts/cc-resume.sh "that auth thing"
```

Takes a session UUID or whatever the session was actually called, which is rarely its
name. It searches every transcript under `~/.claude/projects/`, matches fuzzily against
the AI-generated title, tmux name, last prompt and directory, then resumes the winner in
a fresh detached tmux session — in the **original working directory** (a conversation
belongs where it grew up, so the new-session redirect does not apply), under a name
derived from the title.

The whole conversation comes back: history replayed into the pane, full context, **and
the same claude.ai/code link it had before.** A resumed session keeps its bridge id, so
an old link that is still open starts working again.

```bash
scripts/cc-resume.sh --prompt "carry on with step 3" "the drive one"
scripts/cc-resume.sh --list 8
scripts/cc-resume.sh --name debug-redux "silo downloads"
```

**If it's still running, it says so and hands back the existing link instead** — that
*is* the reconnect. Do not work around this: `claude --resume` will cheerfully start a
second process on a live conversation, and then two processes write one transcript and
both claim one bridge. The phone ends up connected to a coin flip, and the loser prints
*"Remote Control disconnected — another connection took over"*. `--force` kills the
running one first, when that is genuinely what's wanted.

If nothing matches, or two candidates are too close to call, it prints the shortlist and
exits 2 without launching anything. That is the cue to ask rather than guess — a wrong
guess resumes the wrong conversation, which is worse than a question. Same when the
request is just "resume" with nothing after it: `--list 5` and let a human pick.

Exit codes: `0` done · `2` no match or a toss-up (shortlist on stdout) · `4` live but
its bridge never armed · `5` the directory has never been trusted.

## Fork

```bash
scripts/cc-resume.sh --fork "the reorg one"
scripts/cc-resume.sh --fork self --prompt "explore the second option instead"
```

A fork replays the history into a **new session id**: same memory, separate life. The
original is untouched, keeps its own link, and carries right on — so unlike a resume,
forking something that is currently running is not only safe, it's the point. Use it to
try a second approach without spending the first one, or to hand a long,
expensively-built context to a session that is about to go somewhere risky.

`self` (or `this`) means the session running the command. A session can fork itself; the
copy wakes up knowing everything the original knew a moment ago, including its own tool
history, and the original never notices. `--fork` is implied for `self`, because
"continuing" yourself is just carrying on typing.

## Listing and cleaning up

```bash
scripts/cc-resume.sh --list 10        # sessions with titles, links and live flags
tmux ls
tmux attach -t caleb_claude-2
tmux kill-session -t caleb_claude-2
```

`cc-sessions.py` is the lister underneath, for anything machine-readable:

```bash
scripts/cc-sessions.py list -n 10 --json
scripts/cc-sessions.py match "drive health" -n 5     # ranked, with scores
scripts/cc-sessions.py self                          # uuid of the calling session
```

## The parts that will catch you out

- **`--detach` is not optional when an agent is the caller.** A bare `caleb_claude` is
  for a human at a terminal. Inside a session `$TMUX` is set, so without `--detach` the
  script execs claude into a pipe with no TTY — no session, no link, a confusing hang.
- **It takes up to ~30 seconds.** The command polls until Remote Control arms the
  bridge, because a session without a bridge is invisible to the phone. On timeout it
  prints `NOT ARMED` and exits 1 — say so plainly rather than handing over a dead link.
- **A positional prompt does not reach claude.** As of v2.1.270, a prompt passed as an
  argument under `--remote-control` is silently discarded: the session comes up armed,
  empty and waiting, which looks exactly like success until you notice nothing has
  happened. Both scripts route opening instructions through `tmux send-keys`, clearing
  the input box with `C-u` first — claude restores the last unsent *draft* for a
  directory and send-keys appends, so without that the new prompt gets welded onto the
  tail of whatever was abandoned there and both go in as one sentence.
- **A directory Claude has never seen shows a trust prompt** ("Is this a project you
  trust?"). Attached, a human answers it. Detached, nobody does, and it waits forever:
  no state file, no bridge, `NOT ARMED`. The flag lives in `~/.claude.json` under
  `projects → <dir> → hasTrustDialogAccepted`. `caleb_claude` checks it before moving
  anywhere and stays put with a warning rather than launching into a hole;
  `cc-resume.sh` checks it up front and refuses with exit 5 rather than letting you
  watch a pane do nothing for half a minute. **Anywhere you point `CC_CWD` needs the
  flag set first.**
- **Resume is not directory-scoped, but the resumed session still inherits a cwd.**
  `--resume <uuid>` finds the conversation from anywhere, then drops it in whatever
  directory you happened to be standing in — quietly repointing it at a different
  project. `cc-resume.sh` cds back to where the conversation actually lived.
- **Never type `/remote-control` at a session to fix it.** That command *toggles*. Aimed
  at a session that armed a little late, it switches a working bridge off, and the
  result is indistinguishable from an upstream outage.
- **Leave the cron-managed session alone.** If you keep an always-on session, it is
  respawned by a keepalive every five minutes, so killing it accomplishes nothing and
  fighting it accomplishes less. Manual sessions are named `caleb_claude[-N]`,
  `resume-…`, `fork-…` and never collide with it.
- **Keep the number of live sessions sane.** Several long-lived Remote Control processes
  under one account rotate each other's OAuth refresh tokens, and whichever refreshes
  last leaves the others holding a dead one. Two or three is fine. A dozen is an evening
  spent reading logs in which nothing is wrong. Kill resumes and forks when they've
  served their purpose.

## If it comes up NOT ARMED

In order of likelihood: the trust prompt (above); a stale OAuth token, which only a
fresh process fixes; or a Remote Control outage upstream. Attach and look before
theorising — `tmux attach -t <name>` shows the pane, and the answer is usually sitting
on it in plain text.

`references/failure-modes.md` has the engineering detail behind each of these — why the
pid walk exists, why the arming loop polls instead of sleeping, and why there is no
`/remote-control` fallback.
