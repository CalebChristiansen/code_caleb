---
name: ralph-loop
description: Set up an autonomous coding loop that spawns Claude Code per task, monitors progress via heartbeat cron, handles escalations, and posts live updates to Discord. Use when asked to "set up a ralph loop", "autonomous build", "run tasks autonomously", "coding loop", "task runner", or when building a project that needs hands-off autonomous execution with monitoring. Covers task queue creation, runner setup, heartbeat cron, escalation handling, and Discord channel updates.
---

# Ralph Loop

Autonomous coding loop: a bash runner spawns fresh Claude Code per task from a JSON queue, with an OpenClaw heartbeat cron monitoring progress, diagnosing failures, and restarting the runner if it dies.

## Architecture

```
┌─────────────┐     spawns per task     ┌──────────────┐
│ run_tasks.sh │ ───────────────────────▶│ claude --print│
│  (bash loop) │                         └──────────────┘
│              │──── .escalate file ────▶ ┌──────────────┐
│              │                          │  Heartbeat   │
│              │◀─── .done/.skip ────────│ (cron agent) │
└─────────────┘                          └──────────────┘
       │                                        │
       ▼                                        ▼
  #project-live                          #project-updates
  (raw output)                          (status summaries)
```

## Setup Procedure

### 1. Gather Requirements

Ask the user for:
- **Project directory** — where code lives
- **Plan** — what to build (a PLAN.md, description, or list of features)
- **Deadline** (optional) — ISO timestamp, empty for no deadline
- **Discord channels** — which channels for live output and status updates (default: current channel for both)
- **Bot token source** — Bitwarden item name for Discord bot token, or token in .env

### 2. Create Task Queue

Generate `tasks.json` in the project directory. Read `references/task-format.md` for the schema.

Key principles:
- Each task must be **self-contained** — Claude Code gets zero context from prior tasks
- Include all paths, env vars, and setup in every prompt
- Always start with a "commit existing work" task and end with a "final push" task
- Order: commit → core build → tests → docs → done-commit → nice-to-haves → final-push
- Write test commands that verify the task actually worked

### 3. Create Runner Environment

```bash
mkdir -p $PROJECT_DIR/logs
```

Create `$PROJECT_DIR/ralph.env` with runner config:
```bash
export RALPH_PROJECT_DIR="/path/to/project"
export RALPH_TASKS_FILE="$RALPH_PROJECT_DIR/tasks.json"
export RALPH_LOG_DIR="$RALPH_PROJECT_DIR/logs"
export RALPH_LIVE_CHANNEL="<discord-channel-id>"  # for raw output
export RALPH_BOT_TOKEN="<bot-token>"               # or fetch from Bitwarden at runtime
export RALPH_DEADLINE=""                            # ISO timestamp or empty
export RALPH_MAX_FAILURES="3"
export RALPH_CONTEXT_FILE=""                        # optional file with extra context for prompts
```

Copy the runner script:
```bash
cp <skill_dir>/scripts/run_tasks.sh $PROJECT_DIR/run_tasks.sh
chmod +x $PROJECT_DIR/run_tasks.sh
```

### 4. Set Up Heartbeat Cron

Create a heartbeat cron job via the `cron` tool:

```
cron add:
  name: "<project>-build-monitor"
  schedule: { kind: "every", everyMs: 600000 }
  sessionTarget: "isolated"
  payload:
    kind: "agentTurn"
    message: <heartbeat prompt — see below>
    timeoutSeconds: 180
  delivery:
    mode: "announce"
    channel: "discord"
    to: "channel:<updates-channel-id>"
  enabled: false   # enable when ready to start
```

#### Heartbeat Prompt Template

```
HEARTBEAT: <Project> build monitor.

## Priority: Escalation Check
Look for .escalate files:
  ls <project_dir>/logs/*.escalate 2>/dev/null
If one exists, READ IT. It contains a failed task with diagnosis instructions.
- Read the escalation file and referenced log
- Diagnose the root cause
- Fix the code directly (edit files, run commands)
- Re-run the test command from the escalation
- If fixed: touch <project_dir>/logs/{task_id}.done
- If unfixable: write reason to <project_dir>/logs/{task_id}.skip
- Delete the .escalate file after handling

## Runner Check
Is run_tasks.sh still running?
  ps aux | grep run_tasks.sh | grep -v grep
If dead, check <project_dir>/logs/runner.log for why.
Restart: cd <project_dir> && source ralph.env && nohup bash run_tasks.sh &

## Context Budget Check
Run: session_status
Check context usage (e.g. "Context: 144k/200k"). If usage exceeds 85%, report a warning.
If usage exceeds 95%, finalize: commit and push all work, update PROGRESS.md, disable this cron job (job ID: <job_id>).

## Deadline Check (if applicable)
The DEADLINE is <deadline or "none">.
If past deadline, finalize everything and disable this cron job.

## Progress Report (ACCURATE COUNTING)
⚠️ The logs/ dir may have .done files from prior runs. Do NOT count ls *.done blindly.
Run this to get accurate counts against the current tasks.json:
```
python3 -c "
import json, os
tasks = json.load(open('<project_dir>/tasks.json'))
task_ids = [t['id'] for t in tasks]
done = [f.replace('.done','') for f in os.listdir('<project_dir>/logs') if f.endswith('.done')]
current_done = [t for t in task_ids if t in done]
remaining = [t for t in task_ids if t not in done]
print(f'Done: {len(current_done)}/{len(task_ids)}')
for t in remaining[:3]: print(f'  Next: {t}')
"
```
Report: X/total tasks done, current task name, runner status, time/budget remaining.

## All Tasks Complete Check
If ALL tasks in tasks.json are done (done count == total count) AND the runner process is no longer alive:
1. Post a final summary: "🏁 Ralph Loop complete: X/X tasks done."
2. Disable this cron job: use the cron tool to update job ID <job_id> with enabled: false
3. Do NOT restart the runner — it finished naturally.

## Context Recovery
If no memory of prior work, read:
1. <project_dir>/PLAN.md
2. <project_dir>/PROGRESS.md
3. <project_dir>/tasks.json
4. <project_dir>/logs/runner.log
```

### 5. Write HEARTBEAT.md

Write a `HEARTBEAT.md` in the agent's workspace root with the same instructions as the heartbeat prompt (the cron agent reads this for full context). Include:
- The cron job ID (fill in after creating)
- Project directory path
- Channel IDs
- Deadline (if any)
- Context recovery file list

### 6. Launch

```bash
# Enable heartbeat cron
cron update: jobId=<id>, patch={enabled: true}

# Start runner
cd $PROJECT_DIR && source ralph.env && nohup bash run_tasks.sh > /dev/null 2>&1 &
```

Report to the user: runner PID, heartbeat job ID, which channels to watch.

### 7. Monitoring Commands

Check status on demand:
```bash
tail -30 $PROJECT_DIR/logs/runner.log          # recent activity
ls $PROJECT_DIR/logs/*.escalate 2>/dev/null    # pending escalations
ps aux | grep run_tasks.sh | grep -v grep      # runner alive?
```

**⚠️ Counting completed tasks correctly:**
If the logs/ directory has `.done` files from a prior run (e.g., reusing the same project dir), a naive `ls *.done | wc -l` will overcount. Always cross-reference against the current `tasks.json`:
```bash
python3 -c "
import json, os
tasks = json.load(open('$PROJECT_DIR/tasks.json'))
task_ids = [t['id'] for t in tasks]
done = [f.replace('.done','') for f in os.listdir('$PROJECT_DIR/logs') if f.endswith('.done')]
current_done = [t for t in task_ids if t in done]
remaining = [t for t in task_ids if t not in done]
print(f'Done: {len(current_done)}/{len(task_ids)}')
for t in remaining[:5]: print(f'  ⬜ {t}')
"
```
**Include this counting logic in the heartbeat prompt** so the cron agent reports accurate progress — not stale counts from old runs.

### 8. Teardown

When the loop finishes or user says stop:
```bash
# Kill runner
pkill -f run_tasks.sh

# Disable heartbeat
cron update: jobId=<id>, patch={enabled: false}

# Final commit
cd $PROJECT_DIR && git add -A && git commit -m "chore: ralph loop complete" && git push
```

## Stopping Conditions

The runner stops when ANY of these trigger:
1. **All tasks complete** — clean exit
2. **Deadline passed** — if configured
3. **Max consecutive failures** — default 3 in a row
4. **Runner crash** — heartbeat detects and restarts

The heartbeat adds:
5. **Context budget >95%** — finalizes and disables itself
6. **All tasks complete** — heartbeat detects runner exited + all tasks done, posts final summary, disables itself

## File Markers

The runner and heartbeat communicate via files in `$LOG_DIR/`:

| File | Meaning |
|------|---------|
| `{task_id}.done` | Task completed successfully |
| `{task_id}.skip` | Agent marked as unfixable |
| `{task_id}.escalate` | Task failed, needs agent diagnosis |
| `{task_id}.running` | Task currently in progress (crash detection) |
| `{task_id}_attempt{N}.log` | Claude Code output for attempt N |
| `runner.log` | Runner's own log |
| `tests.log` | Test command output |

## Adding Tasks Mid-Run

To add tasks while the runner is going:
1. Edit `tasks.json` — append new tasks before `final-push`
2. The runner reads tasks.json each iteration, so new tasks get picked up automatically
3. Don't reorder or remove completed tasks (their `.done` files are keyed by ID)
