# Templates

Replace every `<angle-bracket>`. Delete any section that has nothing true to say
yet. An empty heading is worse than a missing one.

---

## `README.md` (repo root)

````markdown
# <repo-name> — <hostname>

<One or two sentences: what this repo holds, and whether it is private.>

> **The box is dead and you are holding a new one?** → **[`docs/runbooks/cold-start.md`](docs/runbooks/cold-start.md)**
>
> Before anything else you need <password manager>, under **`<which account>`**.
> The vault holds `<backup-key item>`, and without it the backups can't be
> decrypted.

---

## What this repo is, and what it is not

| | Answers | Lives in |
|---|---|---|
| **Reproducible install** | what the box is *made of* | this repo |
| **Current-state backup** | what the box has *become* | `<backup location>` |

<Why neither substitutes for the other.>

## Layout

```
bin/        <scripts>
system/etc/ <files mirrored from /etc, if any>
docs/       chapters, runbooks, incidents, decisions
secrets/    .env.example only. Names and shapes. Never values.
```

## Day to day

```bash
<the 3–6 commands you actually run>
```

## Open issues

`docs/issues-backlog.md`.
````

---

## `docs/README.md` — the table of contents

````markdown
# <hostname> — documentation

> **The box is dead and you are holding a new one?**
> → **[`runbooks/cold-start.md`](runbooks/cold-start.md)**

Chapters first, each opening with a summary block, then everything else filed by
*what it is* rather than by how detailed it is.

## Chapters

| | |
|---|---|
| [01 Overview](01-overview.md) | host, users, access, service inventory, key paths |
| [02 Storage](02-storage.md) | <one line> |
| [03 <Area>](03-<area>.md) | <one line> |
| [NN Conventions](NN-conventions.md) | how docs are edited, where things go |

## Everything else

| | |
|---|---|
| [**Runbooks**](runbooks/) | "Something is wrong, what do I type." |
| [**Incidents**](incidents/) | Things that happened. Append-only; true forever. |
| [**Decisions**](decisions/) | Why the box is shaped this way. Also append-only. |
| [**Issue backlog**](issues-backlog.md) | Known problems, not yet fixed. |

Incidents and decisions live apart from the chapters deliberately. Reference decays
and wants editing; a thing that happened does not. Chapters get corrected in place;
these two get appended to. See [NN Conventions](NN-conventions.md).
````

---

## `docs/01-overview.md`

````markdown
# Overview

**Host** <hostname> · **LAN** <ip> · **VPN/Tailnet** <ip> · **Domain** <domain>
**OS** <distro version> · **Repo** `<path>` (`<owner:group mode>`)

| Service | Port | Service | Port |
|---|---|---|---|
| <svc> | <port> | <svc> | <port> |

<One paragraph: the single most surprising thing about this box.>

---

## Users

| Account | Purpose | sudo | Notes |
|---|---|---|---|

## Privileged access

<How sudo works here. Where the password comes from, if it's automated.>

## Key paths

| Path | What |
|---|---|
````

---

## `docs/NN-<area>.md` — any other chapter

````markdown
# <Area>

**<Thing>** `:<port>` · `<unit>.service` · data `<path>` · config `<path>`
**<Thing>** <one line>

<Short paragraph: what is unusual, fragile or load-bearing here. Link the
incident or decision that explains it.>

---

## <Thing>

<Detail. Tables for anything with more than two rows of the same shape.
Procedures go in a runbook and are linked from here:>

Broken? → [Debugging <thing>](runbooks/debugging-<thing>.md)
````

---

## `docs/NN-conventions.md`

````markdown
# NN — Conventions

How we work on this box, as opposed to what the box is.

## Editing docs: two kinds of file, two rules

**Most of this tree is living reference. Just fix it.** The chapters, the
runbooks, the READMEs, the backlog and this file describe what *is*. When they
are wrong, correct the sentence and move on. Don't add an annotation, a dated
aside or a note about what it used to say. Git remembers.

**Incidents and decisions are append-only.** The claim as it was made *is* the
record, so when one becomes false, annotate it rather than editing it:

```
(update YYYY-MM-DD: what is true now)
```

Use one dated line, and only where a reader could otherwise act on something
untrue. A reversed decision gets a new entry.

The mistake to avoid in each direction: annotating a runbook until it becomes a
changelog, or quietly editing an incident so the box looks like it was never wrong.

## Where things go

<Scripts, skills, projects, secrets: one line each on where they live and why.>
````

---

## `docs/runbooks/README.md`

````markdown
# Runbooks

Procedures. Each answers "something is wrong, what do I type". They are kept
apart from the chapters so a fix is never buried in an explanation.

**Start here if the box is gone:** [`cold-start.md`](cold-start.md)

| Runbook | Chapter |
|---|---|
| [Cold start — the box is dead and you are holding a new one](cold-start.md) | — |
| [Debugging <thing>](debugging-<thing>.md) | 0N-<area> |
````

Name runbooks after the action: `debugging-<thing>`, `upgrading-<thing>`,
`recovering-<thing>-after-<event>`, `if-locked-out-after-<thing>`.

---

## `docs/runbooks/<name>.md`

````markdown
# Debugging <thing>

*From `0N-<area>`.*

```bash
# the first command to run, and what its output tells you
<command>

# TRAP: <the thing that wasted an hour last time>
<command>
```

## If <symptom>

<command, then what "good" looks like>
````

Put the commands first and explanations in comments. Someone reading this is
currently having a bad day.

---

## `docs/runbooks/cold-start.md`

````markdown
# Cold start — the box is dead and you are holding a new one

**You need:** <password manager + account>, <backup key item>, <install media>,
<physical access to X>.

1. **Install <OS>.** <hostname, user, disk layout>
2. **Get secrets.** <how to log in to the vault from a fresh box>
3. **Clone this repo** to `<path>`.
4. **Restore.** `<restore command>` from `<backup location>`.
5. **Deploy.** `<deploy command>`
6. **Verify.** `<check command>`, and what "good" looks like.

## Known gaps

- TODO: <anything not yet scripted>
````

---

## `docs/incidents/README.md`

````markdown
# Incidents — index

One compact file, [`incidents.md`](incidents.md), append-only. These are things
that happened. They stay true forever, which is why they are kept apart from the
reference chapters.

When a line here has since become false, annotate it as
`(update YYYY-MM-DD: what is true now)` rather than correcting it.

| Incident |
|---|
| [<Title> (YYYY-MM-DD)](incidents.md#<anchor>) |
````

Newest first. For the anchor, lowercase the heading, drop everything except
letters, digits, spaces and hyphens, then turn each space into a hyphen. Run
`scripts/check-links.py` rather than trusting yourself with the parentheses.

---

## `docs/incidents/incidents.md`

````markdown
# Incidents

Append-only. These happened, and they stay true forever.

---

## <Short title of what broke> (YYYY-MM-DD)

**What happened:** <timeline, with absolute times. What the symptom looked like
from the outside.>

**What held:** <safeguards that worked. Name them so nobody removes them later.>

**What did not hold:** <what should have caught it and didn't.>

**Fix:** <what changed, with paths. Link the runbook if the fix is repeatable.>

**Considered and rejected:** <optional. The obvious fix, and why it was wrong.>

**Aftermath:** <anything still left to clean up.>

---
````

For a multi-day incident, use `(YYYY-MM-DD → MM-DD)` in the heading.

---

## `docs/decisions/README.md`

Same as the incidents index, with this opening line:

> One compact file, [`decisions.md`](decisions.md), append-only. Why the box is
> shaped the way it is. A decision that was right in March is still the decision
> that was made in March even after it is reversed. Reversals get a new entry,
> not an edit.

---

## `docs/decisions/decisions.md`

````markdown
# Decisions

Why the box is shaped the way it is. Also append-only. Reversals get a new entry.

---

## <What was decided, as a statement> (YYYY-MM-DD)

<The situation, then the choice, then the alternatives and why each lost.
Include numbers where there are any.>

---
````

Headings are statements: "Native, not Docker" and "Backups are encrypted", not
"Docker?".

---

## `docs/issues-backlog.md`

````markdown
# Issue backlog

Known problems, not yet fixed. Delete an entry when it is fixed. This is
scaffolding, not history.

---

## 1. <Problem as a statement>
**labels:** <bug, reliability, security, backup, hardware, docs> · **priority:** <high|med|low>

<What was observed, when, and how often.>

- <contributing cause>
- <contributing cause>

**Fix direction:** <the shape of the fix, not the full implementation.>
````
