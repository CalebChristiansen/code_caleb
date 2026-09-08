---
name: new-claude-session
description: Spawn another Claude Code session detached in tmux and hand back a claude.ai/code Remote Control link the phone can reach. Use when asked to "open a new shell for Claude", "start another session", "spin up another one", "give me a new session", "I need a second Claude", "run this in a separate session", or when a session link is needed to drive work from a phone. Covers the one command, naming sessions, passing an opening prompt, listing and killing sessions, and the failure modes that make a session look alive but be unreachable.
---

# Start another Claude session

Spawn a second (third, fourth) Claude Code session that survives an SSH drop or a
phone going to sleep, and hand back a Remote Control link.

From inside a session:

```bash
cd ~ && caleb_claude --detach
```

It prints three lines — session name, attach command, and the
`https://claude.ai/code/session_…` link. **Hand over the link.** That is the whole
handoff: tap it and you're talking to the new session.

## Install

`scripts/caleb_claude` is the launcher. Drop it somewhere on `PATH` and point a
symlink at it:

```bash
install -m 755 scripts/caleb_claude ~/scripts/claude/caleb_claude
ln -sf ~/scripts/claude/caleb_claude ~/.local/bin/caleb_claude
ln -sf ~/scripts/claude/caleb_claude ~/.local/bin/cclaude     # muscle-memory alias
```

It pins the CLI at `$HOME/.npm-global/bin/claude` rather than trusting `PATH` —
override with `CC_CLAUDE_BIN`. Never let it resolve a bare `claude`: a stale
system-wide copy without `--remote-control` dies instantly on an unknown option, the
pane exits, and the failure reads as "the session won't arm".

`scripts/lclaude` is the same launcher for a second, differently-named account
(session prefix `lclaude`, keepalive session `lunate` instead of `phone`). The two
are deliberate near-twins with no shared source — **a fix to one must be hand-carried
to the other.** They live side by side here so the drift is at least visible.

## Naming it

`caleb_claude-4` tells nobody anything. A name says what it's for:

```bash
CC_SESSION=vpn-debug caleb_claude --detach
```

With `CC_SESSION`, an existing session of that name is **attached to**, not recreated —
a reattach, not a new session, and from inside tmux it fails rather than doing anything
useful. Use a fresh name when you mean a fresh session. Without `CC_SESSION`, each bare
launch grabs the first free `caleb_claude[-N]`.

## Handing it an opening instruction

Anything after `--detach` passes straight through to `claude`:

```bash
CC_SESSION=tests caleb_claude --detach "run the healthcheck suite and fix what fails"
```

## Listing and cleaning up

```bash
tmux ls                              # what's running
tmux attach -t caleb_claude-2        # attach from a terminal
tmux kill-session -t caleb_claude-2  # done with it
```

## The parts that will catch you out

- **`--detach` is not optional when an agent is the caller.** A bare `caleb_claude` is
  for a human at a terminal. Inside a session `$TMUX` is set, so without `--detach` the
  script execs claude into a pipe with no TTY — no session, no link, a confusing hang.
- **It takes up to ~30 seconds.** The command polls until Remote Control arms the
  bridge, because a session without a bridge is invisible to the phone. On timeout it
  prints `NOT ARMED` and exits 1 — say so plainly rather than handing over a dead link.
- **`cd ~` first.** The new session inherits the working directory, and a directory
  Claude has never seen shows a trust prompt ("Is this a project you trust?"). Attached,
  a human answers it. Detached, nobody does, and it waits forever: no state file, no
  bridge, `NOT ARMED`. The flag lives in `~/.claude.json` under
  `projects → <dir> → hasTrustDialogAccepted`.
- **Never type `/remote-control` at a session to fix it.** That command *toggles*. Aimed
  at a session that armed a little late, it switches a working bridge off, and the
  result is indistinguishable from an upstream outage.
- **Leave the cron-managed session alone.** The always-on one (`phone`, or `lunate` on
  the other account) is respawned by a keepalive every five minutes. Manual sessions are
  named `caleb_claude[-N]` and never collide with it.
- **Keep the number of live sessions sane.** Several long-lived Remote Control processes
  under one account rotate each other's OAuth refresh tokens, and whichever refreshes
  last leaves the others holding a dead one. Two or three is fine. A dozen is an evening
  spent reading logs in which nothing is wrong.

## If it comes up NOT ARMED

In order of likelihood: the trust prompt (above); a stale OAuth token, which only a
fresh process fixes; or a Remote Control outage upstream. Attach and look before
theorising — `tmux attach -t <name>` shows the pane, and the answer is usually sitting
on it in plain text.

`references/failure-modes.md` has the engineering detail behind each of these — why the
pid walk exists, why the arming loop polls instead of sleeping, and why there is no
`/remote-control` fallback.
