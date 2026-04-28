---
name: ralph-loop
description: Set up an autonomous coding loop that spawns Claude Code per task, monitors progress via a watchdog script, handles escalations, and provides status via tmux + iTerm2 notifications. Use when asked to "set up a ralph loop", "autonomous build", "run tasks autonomously", "coding loop", "task runner", or when building a project that needs hands-off autonomous execution with monitoring.
---

# Ralph Loop

Autonomous coding loop: a bash runner spawns a fresh interactive Claude TUI per task from a JSON queue, each in its own tmux window (tab). A watchdog script monitors progress via events.log, handles escalations via `claude -p`, and restarts the runner if it dies. Monitored via tmux + iTerm2 notifications (works over SSH). Each task is fully visible and interactive — attach to any window to watch or redirect the agent.

## Architecture

```
┌──────────────┐    creates tmux window   ┌──────────────┐
│ run_tasks.sh │ ────────────────────────>│  claude TUI  │──> events.log
│  (bash loop) │    per task (interactive) └──────────────┘
│              │──── .escalate file ─────>┌──────────────┐
│              │                          │ watchdog.sh  │──> tails events.log
│              │<─── .done/.skip ─────────│  (bash loop) │    git diff alerts
└──────────────┘                          └──────────────┘    idle detection
       │                                         │
       ├──> runner.log                           ├──> iTerm2 notifications
       ├──> events.log (structural)              └──> watchdog.log
       └──> summary.md (incremental)

       tmux session: ralph-<name>
       ┌───────────────────────────────────────────────────────────────┐
       │ [Control] [Step 1: Models] [Step 2: API] [Step 3: Tests] .. │
       ├───────────────────────────────────────────────────────────────┤
       │ Window 0 "Control":                                          │
       │  ┌────────────┬────────────┬───────────┐                     │
       │  │   Runner   │  Watchdog  │  Status   │                     │
       │  └────────────┴────────────┴───────────┘                     │
       │ Window 1+ — one per task: interactive Claude TUI             │
       │  (attach to watch, interact, redirect, or review)            │
       └───────────────────────────────────────────────────────────────┘
```

Each task gets its own **tmux window** (tab) running an interactive Claude TUI. Flip between tasks with `Ctrl-B + n/p` or `Ctrl-B + <number>`. Completed task windows stay open for review.

## Run Directory

All ralph loop artifacts live in a dedicated run directory, NOT in the project directory. This keeps the project directory clean. The base directory defaults to `~/.claude/ralph-runs/` but can be overridden by setting `RALPH_RUNS_BASE`.

```
$RALPH_RUNS_BASE/<project>-<YYYYMMDD-HHMMSS>/   # default: ~/.claude/ralph-runs/
├── tasks.json          ← task queue
├── ralph.env           ← environment config
├── plan.md             ← copy of the plan that spawned this run
├── summary.md          ← updated incrementally after each task
├── events.log          ← structured event log (FINDINGs, ACTIONs, ERRORs, task lifecycle)
└── logs/
    ├── runner.log
    ├── watchdog.log
    ├── tests.log
    ├── decisions.md
    ├── *.done, *.skip, *.escalate
    └── *_attempt*.log
```

The launch script creates this directory automatically.

## Setup Procedure

### 1. Gather Requirements

Ask the user for:
- **Project directory** — which project directory to use
- **Plan** — what to build (a PLAN.md, description, or list of features)
- **Branch** — git branch to work on (create if needed)
- **Deadline** (optional) — ISO timestamp, empty for no deadline

### 2. Create Run Directory and Task Queue

Create the run directory under `$RALPH_RUNS_BASE` (default `~/.claude/ralph-runs/`) and write `tasks.json` directly there. **Never write tasks.json to the project directory** — keep it clean.

```bash
mkdir -p ~/.claude/ralph-runs/<descriptive-name>/logs
```

Use a descriptive name (e.g., `myproject-feature-review`) rather than relying on auto-generated timestamps. This makes it easier to find and reference runs later.

Generate `tasks.json` in the run directory. Read `references/task-format.md` for the schema.

Key principles:
- Each task must be **self-contained** — Claude Code gets zero context from prior tasks
- Include all paths, env vars, and setup in every prompt
- The runner automatically commits after each successful task (the agent writes the commit message)
- End with a "final push" task if you want changes pushed to the remote
- Order: core build → tests → integration → lint → final-push
- Write test commands that verify the task actually worked
- Include build/test commands relevant to the project, mention CLAUDE.md conventions if present

### 3. Create Runner Environment (Optional)

Optionally create `ralph.env` in the run directory to customize settings. If omitted, the launch script generates one with defaults.

```bash
cat > ~/.claude/ralph-runs/<run-name>/ralph.env <<'EOF'
export RALPH_PROJECT_DIR="/path/to/project"
export RALPH_DEADLINE=""                            # ISO timestamp or empty
export RALPH_MAX_FAILURES="3"                       # consecutive failure limit
export RALPH_CONTEXT_FILE=""                        # optional file with extra context for prompts
export RALPH_WATCHDOG_INTERVAL="60"                 # seconds between watchdog checks
export RALPH_ESCALATION_TIMEOUT="300"               # seconds for escalation claude -p timeout
EOF
```

The launch script will automatically set `RALPH_RUN_DIR`, `RALPH_TASKS_FILE`, and `RALPH_LOG_DIR` to point at the run directory.

### 4. Launch via tmux

```bash
bash <skill_dir>/scripts/ralph-launch.sh $PROJECT_DIR --run-dir ~/.claude/ralph-runs/<run-name> [--plan /path/to/plan.md]
```

The `--run-dir` flag points to your pre-created run directory containing `tasks.json`. If omitted, the script auto-creates a timestamped directory (but tasks.json must already exist there — it will NOT copy from the project dir).

This creates a tmux session named `ralph-<run-dir-basename>` with:
  - **Window 0 "Control"**: Three panes — Runner (left), Watchdog (top-right), Status (bottom-right)
  - **Window 1+ "Step N: ..."**: One per task — interactive Claude TUI (created dynamically as tasks start)

Each task runs in a full-screen interactive Claude session. You can attach and interact mid-task, just like dispatch. Completed windows stay open for review — flip through with `Ctrl-B + n/p`.

On launch, the script prints all important paths:
- Run directory
- Tasks file
- Logs directory
- Plan file (if provided)
- Summary file path (generated on completion)
- tmux session name and commands

Report these paths to the user.

### 5. Notifications

Notifications are sent via iTerm2 OSC 9 escape sequences — these appear as native macOS notifications when SSH'd in via iTerm2. No Slack or Discord setup required.

Events that trigger notifications:
- Task completed / failed (all retries exhausted)
- Agent logs a FINDING or ERROR to events.log
- Escalation triggered / resolved
- New git commits detected (with diff stats)
- Runner crashed and restarted
- Agent idle >15 minutes (gentle "seems idle" alert, not crash)
- Loop complete (includes summary file path)
- Deadline reached

If not using iTerm2, a terminal bell (`\a`) is sent instead.

To suppress idle alerts during manual intervention: `touch $LOG_DIR/.paused` (remove to resume).

### 6. Monitoring Commands

Check status on demand:
```bash
# Quick status overview (shows progress + recent events + pause status)
bash <skill_dir>/scripts/ralph-status.sh ~/.claude/ralph-runs/<run-dir>

# Attach to the tmux session (name is ralph-<dirname>)
tmux attach -t ralph-myproject  # example

# View structured event log (the best quick overview of what happened)
cat ~/.claude/ralph-runs/<run-dir>/events.log

# Manual log checks
tail -30 ~/.claude/ralph-runs/<run-dir>/logs/runner.log
tail -30 ~/.claude/ralph-runs/<run-dir>/logs/watchdog.log
ls ~/.claude/ralph-runs/<run-dir>/logs/*.escalate 2>/dev/null

# Pause idle alerts during manual investigation
touch ~/.claude/ralph-runs/<run-dir>/logs/.paused
# Resume: rm ~/.claude/ralph-runs/<run-dir>/logs/.paused
```

### 7. Completion Summary

`summary.md` is updated incrementally as tasks complete (not just at the end). Each task appends its status, output tail, and events. On completion, the final summary wraps everything with:
- Run metadata (project, branch, start/end time, duration)
- Task results table with status, attempt counts, and duration per task
- Task details (incremental sections from each completed task)
- Failures & escalations section with details on what went wrong
- Design decisions & plan changes (logged by task sessions during the run)
- Full event log (from events.log)
- Files changed (git diff stats)
- How to continue (branch, key files, test commands, log locations)

**Design decisions**: Each task session logs notable decisions to `decisions.md`. **Events**: Each task session logs significant findings, actions, and errors to `events.log`. Both are rolled into the final summary.

The summary file path is printed in the runner log and included in the completion notification.

### 8. Teardown

When the loop finishes or user says stop:
```bash
# Kill the tmux session (kills runner + watchdog)
tmux kill-session -t ralph-<dirname>

# Or kill individually
kill $(cat ~/.claude/ralph-runs/<run-dir>/logs/runner.pid) 2>/dev/null
kill $(cat ~/.claude/ralph-runs/<run-dir>/logs/watchdog.pid) 2>/dev/null
```

## Stopping Conditions

The runner stops when ANY of these trigger:
1. **All tasks complete** — clean exit
2. **Deadline passed** — if configured
3. **Max consecutive failures** — default 3 in a row

The watchdog adds:
4. **Runner crash** — watchdog detects dead PID and restarts
5. **All tasks complete** — watchdog detects runner exited + all tasks done, exits itself

## File Markers

The runner and watchdog communicate via files in `$LOG_DIR/`:

| File | Meaning |
|------|---------|
| `{task_id}.done` | Task completed successfully |
| `{task_id}.skip` | Agent marked as unfixable |
| `{task_id}.escalate` | Task failed, watchdog will diagnose via claude -p |
| `{task_id}.running` | Task currently in progress (crash detection) |
| `{task_id}_attempt{N}.log` | Claude Code output for attempt N |
| `{task_id}_escalation.log` | Watchdog's claude -p escalation output |
| `runner.log` | Runner's own log |
| `runner.pid` | Runner's PID (for watchdog health checks) |
| `watchdog.log` | Watchdog's own log |
| `watchdog.pid` | Watchdog's PID |
| `tests.log` | Test command output |
| `decisions.md` | Design decisions logged by task sessions |
| `.task_meta` | Per-task timing and attempt metadata |
| `.paused` | Suppresses watchdog idle alerts during manual intervention |

## Adding Tasks Mid-Run

To add tasks while the runner is going:
1. Edit `tasks.json` in the run directory — append new tasks before `final-push`
2. The runner reads tasks.json each iteration, so new tasks get picked up automatically
3. Don't reorder or remove completed tasks (their `.done` files are keyed by ID)

## Escalation Flow

When a task fails all retries:
1. Runner writes `{task_id}.escalate` with failure context (test output, last 80 lines of claude output)
2. Runner waits up to 5 minutes for `.done` or `.skip` to appear
3. Watchdog detects the `.escalate` file on its next cycle
4. Watchdog spawns `claude -p --dangerously-skip-permissions` with a diagnosis prompt
5. Claude reads the logs, diagnoses the issue, fixes the code, and re-runs the test
6. If fixed: creates `.done` file. If unfixable: creates `.skip` file with reason
7. Runner picks up the marker and continues