# Detached spawn — why the launcher is shaped the way it is

Each of these is a bug that actually happened. The code that prevents them looks
like paranoia until you have lost an evening to one.

## The pane pid is not necessarily claude

`tmux`'s `#{pane_pid}` is the pane's **top** process, which is only `claude` if every
wrapper `exec`'d through (`sh -c` → `bash -lc` → `exec claude`). `/bin/sh` does not
always take that optimisation. When it doesn't, the pane pid is a surviving `sh -c`
with claude as its **child**.

Read the Remote Control state file at the pane pid and you get a path that will never
exist — so an **armed** session reads as unarmed. Anything that then tries to "fix" it
by toggling `/remote-control` switches a live bridge **off**.

Hence `claude_pid()`: breadth-first from the pane pid down to the first descendant that
actually owns `~/.claude/sessions/<pid>.json`, falling back to the pane pid only if
nothing below it does.

## `/remote-control` toggles — never send it as a fallback

It is not idempotent. Aimed at a session that armed a few seconds later than a fixed
sleep expected, it turns a working bridge off. The resulting silence is
indistinguishable from an upstream Remote Control outage, so you go and read the wrong
logs.

Since Claude Code v2.1.215 the `--remote-control` flag arms the bridge on its own
within a few seconds, even detached. So the launcher **polls** for up to 30s and, on
timeout, reports `NOT ARMED` and exits 1. Failing loudly is correct here; "helpfully"
nudging is not.

## Detached sessions cannot answer the trust prompt

A directory Claude has not seen before raises *"Is this a project you created or one
you trust?"*. Attached, a human answers. Detached, nobody does, and the process waits
forever — no state file is ever written, so the poll times out and reports `NOT ARMED`
while the process sits there perfectly healthy and completely useless.

`cd ~` before spawning, or accept the directory once in an attached session. The flag
is `~/.claude.json` → `projects` → `<dir>` → `hasTrustDialogAccepted`.

## Detached tmux defaults to 80x24

Claude's UI is cramped in it. The launcher spawns at `-x 220 -y 50`, matching what the
cron keepalive uses for the always-on session.

## Never trust `PATH` for the CLI

`tmux` runs its command through `/bin/sh -c`, which is neither login nor interactive,
so it reads neither `.bashrc` nor `.profile` and will not find `~/.npm-global/bin`.

On this box that used to "work" only because a stale system-wide `/usr/bin/claude`
(v2.1.71, no `--remote-control` flag) sat on the default `PATH`. It died instantly with
"unknown option", the pane exited, and every keepalive tick logged a fresh spawn that
would not arm. Removing that copy fixed the symptom and exposed the real bug. Both
launchers now pin the binary absolutely.

## Stacked sessions rotate each other's OAuth tokens

Several long-lived Remote Control processes under one account refresh the same OAuth
credential. Whichever refreshes last leaves the others holding a dead one, and a
session with a stale token cannot re-arm — only a fresh process fixes it. This is why
the keepalive deliberately does **not** try to re-arm a long-lived process, and why
"just spawn more sessions" is bad advice past two or three.

## A keepalive is not a launcher

Pressing the cron keepalive into service for ad-hoc sessions (by overriding its session
name) works, but it writes lock and last-link state as though it were managing a
persistent session, and it is `flock`-serialised against itself. Use the launcher's
`--detach` for one-off sessions; leave the keepalive to the session cron owns.
