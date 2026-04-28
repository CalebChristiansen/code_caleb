---
name: dispatch
description: Launch a background Claude session in tmux to handle a task autonomously. Use when asked to "dispatch", "send to background", "launch a background claude", "investigate this in the background", or when the user wants to hand off a task and walk away.
argument-hint: "[task description]"
---

# Dispatch

Launches an interactive Claude TUI session in tmux to handle a task autonomously. The dispatched Claude runs with `--dangerously-skip-permissions` and produces a summary when done. You can attach to the tmux session at any time to watch, interact, or redirect.

Think of it as handing a colleague a sticky note and saying "sort this out while I'm at lunch" — but you can walk over and check on them whenever you want.

## Architecture

```
┌─────────────────────────────────────────────┐
│            tmux: dispatch-<name>            │
│  ┌─────────────────────┬──────────────────┐ │
│  │   Claude Interactive │   Status Watch   │ │
│  │   TUI               │   (events +      │ │
│  │   (attach to        │    log tail)      │ │
│  │    interact)        │                   │ │
│  └─────────────────────┴──────────────────┘ │
└─────────────────────────────────────────────┘
         │                        │
         ▼                        ▼
    raw.log (TUI capture)    dispatch-status.sh
    run.log (ANSI-stripped)
    events.log (structured)
         │
         ▼ (on completion)
    summary.md
```

## Run Directory

All dispatch artifacts live under `~/.claude/dispatch-runs/`, NOT in the project directory.

```
~/.claude/dispatch-runs/<name>-<YYYYMMDD-HHMMSS>/
├── prompt.md          <- full prompt (initial task for the TUI session)
├── run.log            <- ANSI-stripped log (searchable, used for summary extraction)
├── raw.log            <- raw TUI capture via tmux pipe-pane (for debugging)
├── events.log         <- structured event log (FINDINGs, ACTIONs, ERRORs)
├── summary.md         <- auto-generated summary (from markers or haiku fallback)
├── dispatch.pid       <- PID of the claude process
├── dispatch.env       <- environment config (model, project dir)
└── done               <- marker written on completion (contains exit code)
```

## Workflow

### 1. Gather Information

Determine from the user (or infer from conversation context):
- **Task description** — what should the background Claude do. If the user provided it as an argument, use that. Otherwise ask.
- **Model** — default `claude-opus-4-6`. Ask only if the user hasn't specified.

Do NOT ask for information you can infer from the conversation. If the user says "dispatch this grafana issue" and you've been discussing a Grafana problem, you already have all the context.

### 2. Create Run Directory

```bash
RUN_NAME="<descriptive-slug>"  # e.g., "fix-grafana-datasource"
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
RUN_DIR="$HOME/.claude/dispatch-runs/${RUN_NAME}-${TIMESTAMP}"
mkdir -p "$RUN_DIR"
```

Use a short, descriptive name based on the task — not a generic label.

### 3. Assemble the Prompt

This is the critical step. Write `prompt.md` in the run directory. The dispatched Claude gets ZERO context from this conversation — everything it needs must be in the prompt.

**Structure the prompt with these sections:**

```markdown
## Task
<What needs to be done — clear, specific, actionable>

## Context
<What's been tried, what's known, what's currently running, why this matters>

## Key Files
<Paths to relevant source code, configs, docs — be specific>

## Steps
<Suggested investigation or implementation steps — numbered>

## Constraints
- Read CLAUDE.md at the project root for repo conventions
- Do NOT add Co-Authored-By lines to commits
- Do NOT add "Generated with Claude Code" to PR bodies
- <Any other task-specific constraints>

## When Done
The events addendum in the prompt instructs the agent to write `summary.md` and `done` marker directly when it finishes. You do NOT need to add these instructions — they are injected automatically by the launcher.

The agent will:
1. Write a summary to `$RUN_DIR/summary.md`
2. Create a completion marker: `echo 0 > $RUN_DIR/done`
3. Log a DISPATCH_DONE event to events.log
4. The TUI stays open — the user can continue interacting

If the agent fails to do this, the `_run.sh` safety net generates a haiku summary from events.log after the TUI exits.
```

**Prompt quality guidelines:**
- Include ALL relevant file paths — the dispatched Claude can't read your mind
- Include recent error messages or symptoms verbatim
- If there's a running process (test harness, Docker containers), mention it
- Mention how to verify the fix (test commands, curl checks, etc.)
- Don't assume the dispatched Claude knows anything about the current session

### 4. Launch

```bash
bash ~/.claude/skills/dispatch/scripts/dispatch-launch.sh \
  "$PROJECT_DIR" \
  --run-dir "$RUN_DIR" \
  --model claude-opus-4-6
```

The script creates a tmux session and starts Claude.

### 5. Report to User

After launching, tell the user:
- The tmux session name
- How to monitor: `tmux attach -t dispatch-<name>`
- How to check status: `bash ~/.claude/skills/dispatch/scripts/dispatch-status.sh <run_dir>`
- How to read the summary when done: `cat <run_dir>/summary.md`
- How to kill it: `tmux kill-session -t dispatch-<name>`
- The run directory path (for logs)

## Human Takeover

The dispatch runs as an interactive TUI session. You can attach at any time:

1. **Watch**: `tmux attach -t dispatch-<name>` — see Claude working in real time
2. **Interact**: Wait for Claude to finish a tool call, then type your question or instruction
3. **Redirect**: Tell Claude to change approach, investigate something else, or stop
4. **Detach**: `Ctrl-B, D` — Claude continues autonomously
5. **Exit**: Type `/exit` in the TUI to end the session — post-processing (summary, done marker) runs automatically

No special pause mechanism needed. The TUI session is live and responsive.

## Checking on a Dispatched Task

If the user asks "is it done?", "what happened?", or "check on the dispatch":

1. Run `dispatch-status.sh` to check if it's still running
2. If done, read `summary.md` from the run directory and present the findings
3. If still running, report status and last few lines of output

## Multiple Dispatches

Multiple dispatch sessions can run in parallel — each gets its own tmux session and run directory. If the user asks to dispatch multiple tasks, create separate runs for each.

## Usage Examples

```
/dispatch investigate why tests are failing in CI
/dispatch refactor the auth middleware to use JWT
/dispatch "debug the flaky telemetry test in tests/integration"
```
