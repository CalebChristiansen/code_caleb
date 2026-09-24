---
name: server-docs
description: Set up, or reorganise, the documentation for a home server or self-hosted box as one tree, split by what each document is — a repo README, a docs index with a table of contents, numbered living chapters, runbooks, and append-only incident and decision logs. Use when asked to "document this server", "set up docs like my other box", "make a README / table of contents for this machine", "start an incident log", "write up what happened", "record why we did X", or to tidy existing server notes into this layout. Covers only the organisation, not what the server is for.
---

# server-docs

A server's documentation fails in two ways. It is written twice (a "quick
reference" and a "detailed" doc, which drift apart until neither can be trusted),
or it is written once, as a single growing file of mixed facts, fixes and war
stories that nobody dares edit and everybody appends to.

This layout fixes both with one rule: **file each thing by what it is, not by how
much detail the reader is assumed to want.** There are five kinds of thing, and
they follow two editing rules.

| Kind | Answers | Lives in | Rule |
|---|---|---|---|
| **Chapter** | what the box *is*, one area at a time | `docs/NN-<area>.md` | living — just fix it |
| **Runbook** | "something is wrong, what do I type" | `docs/runbooks/<verb-ing-thing>.md` | living — just fix it |
| **Incident** | what *happened* | `docs/incidents/incidents.md` | append-only |
| **Decision** | *why* the box is shaped this way | `docs/decisions/decisions.md` | append-only |
| **Backlog** | known problems not fixed yet | `docs/issues-backlog.md` | living; entries are deleted once fixed |

Reference decays and wants editing. Things that happened do not. Keep the two
apart and each can follow its own rule.

## The tree

```
<repo>/
├── README.md                 what this repo is, layout, day-to-day commands
├── CLAUDE.md                 (optional) agent context; points at docs/
└── docs/
    ├── README.md             THE table of contents: chapters, then everything else
    ├── 01-overview.md        host, users, access, service/port table, key paths
    ├── 02-storage.md         ┐
    ├── 03-…                  │ one chapter per area of the box, numbered in
    ├── …                     │ roughly the order a stranger needs them
    ├── NN-conventions.md     ┘ last: how docs are edited, where things go
    ├── issues-backlog.md
    ├── runbooks/
    │   ├── README.md         index table: runbook → chapter it belongs to
    │   ├── cold-start.md     the box is dead and you are holding a new one
    │   └── debugging-<thing>.md …
    ├── incidents/
    │   ├── README.md         index table of anchor links, newest first
    │   └── incidents.md      every incident, one file, `---` between entries
    └── decisions/
        ├── README.md         index table of anchor links
        └── decisions.md      every decision, one file
```

Incidents and decisions live in **one file each**, with a README holding an index.
One file stays greppable and easy to append to. The index is what makes it
browsable.

Every template is in [`references/templates.md`](references/templates.md). Copy
from there rather than working from memory.

## The conventions that make it work

1. **Cold-start pointer at the top of both READMEs.** Put a blockquote before
   anything else: *"The box is dead and you are holding a new one? →
   `runbooks/cold-start.md`"*. Anyone rebuilding the box is in a hurry and should
   not have to read a single paragraph first. If a restore needs a secret held
   somewhere else (a password-manager account, a backup key), say so here too,
   including *which* account. Otherwise the backups are just very well-encrypted
   noise.
2. **Every chapter opens with a summary block.** Two to four bold-keyed lines
   (`**Service** \`:port\` · unit · data path`) and one short paragraph with
   anything surprising, then `---`, then the detail. This block replaces a
   separate quick-reference doc. Someone who wants the short version reads the
   first paragraph of the right chapter.
3. **Indexes are tables.** Both the docs README and each sub-folder README are
   tables with a link on the left and a one-line "what's in it" on the right.
   The runbook index adds a column naming the chapter each runbook belongs to.
   Each runbook repeats that link in its first line (`*From \`05-network\`.*`).
4. **Living documents: correct them in place.** No `(was: …)`, no dated asides,
   no changelog at the bottom. Git remembers what they used to say. A runbook
   that has been annotated until it is a changelog with a command buried in it
   has failed.
5. **Append-only documents: annotate them, never rewrite them.** When an incident
   or decision becomes false, add one dated line where a reader could act on the
   untrue part:
   `(update YYYY-MM-DD: what is true now)`
   A reversed decision gets a *new* entry, and the old one is left as it was. If a
   historical doc is stale throughout, put one note at the top rather than forty
   inline. Never quietly edit an incident so the box looks like it was never wrong.
6. **Dates are absolute.** Write `2026-03-17`, never "last Tuesday". Put the date
   in each incident and decision heading, because the heading becomes the anchor
   the index links to.
7. **Secrets are named, never stored.** Docs say *where* a secret lives
   (`/etc/<host>/<svc>.env`, mode `0640 root:sudo`, and which vault item). They
   never contain the value.

## Workflow: a new box

Survey first, then write. Facts come from the machine and never from memory.

1. **Survey.** Collect what the overview and chapters need:
   ```bash
   hostnamectl; ip -brief addr; cat /etc/os-release | head -3
   systemctl list-units --type=service --state=running --no-pager
   sudo ss -tlnp                                  # what listens where
   lsblk -f; findmnt -t ext4,ntfs,ntfs3,xfs,btrfs,zfs; cat /etc/fstab
   crontab -l; sudo crontab -l; systemctl list-timers --no-pager
   getent passwd | awk -F: '$3>=1000 && $3<65534'  # human accounts
   ls /etc/sudoers.d; ufw status 2>/dev/null
   ```
   Ask the user for whatever the machine can't tell you: its purpose in one
   line, where the backups go, where secrets are kept, and anything that has
   already gone wrong.
2. **Choose chapters.** Group the survey by area. Storage, networking,
   monitoring and security are almost always separate chapters. Each service
   family gets its own. Aim for 5–10. Fewer means chapters are hiding several
   subjects each; more usually means a runbook got filed as a chapter.
   `01-overview` always comes first and `NN-conventions` always comes last.
3. **Write the skeleton.** Create every file from the templates with its
   summary block filled in and its body left thin. Write `docs/README.md` now,
   not at the end. The table of contents comes first and the chapters grow into it.
4. **Fill the chapters** from the survey. Use tables for ports, services, drives
   and schedules.
5. **Write `runbooks/cold-start.md`,** even if it is short and full of `TODO`.
   It is the document you will need most on the day you have least time to write it.
6. **Seed the logs.** Anything the user has told you already broke goes in
   `incidents.md`, dated. Anything already decided goes in `decisions.md`,
   including the first decision: that the docs follow this layout.
7. **Wire it up.** If the box has a `CLAUDE.md`, make it point at `docs/README.md`
   rather than repeating facts the chapters already hold.
8. **Check links:** `python3 <this-skill>/scripts/check-links.py docs/`. It
   verifies every relative link and every `#anchor` against GitHub's slug rules.

## Workflow: tidying existing notes

1. List every existing doc and sort each section into chapter, runbook,
   incident, decision or backlog. Headings shared between files mean the same
   fact is written twice: keep the better copy and delete the other.
2. Move the content and don't rewrite it. Chapters and runbooks can be edited
   afterwards. Incidents and decisions keep their original wording, including
   the parts that are now wrong, plus a dated `(update …)` line.
3. Record the reorganisation itself as a decision, with before and after numbers
   ("2,846 lines in two tiers became nine chapters and 21 runbooks").
4. Run the link check.

## Workflow: day to day

- **Something broke and was fixed:** append an incident. Use **What happened**,
  **What held**, **What did not hold**, **Fix** and **Aftermath**. Add a row at
  the top of the incidents index. If the fix is repeatable, it also becomes a
  runbook, linked from the incident.
- **Chose X over Y:** append a decision. Say what was chosen, what was rejected,
  and why. Add a row to the decisions index.
- **Found a problem you won't fix now:** add it to the backlog as a numbered
  entry with labels, priority and a **Fix direction** line. Delete the entry when
  it is fixed, and record the fix as an incident if the story is worth keeping.
- **A chapter is wrong:** fix the sentence. That's all.

## Things not to do

- Don't create a `quick-reference.md`. The summary blocks at the top of each
  chapter already are the quick reference.
- Don't put a procedure in the middle of a chapter's explanation. Move it to a
  runbook and link to it.
- Don't split incidents into one file per incident until there are enough that
  one file is actually painful. The index handles browsing.
- Don't let the docs README describe things. It is a table of contents. Its only
  prose is a few lines explaining the living and append-only split.
