#!/usr/bin/env bash
# Ralph Loop — status checker
# Run anytime to see the current state of a ralph loop.
#
# Usage: ralph-status.sh [run_dir_or_project_dir]
#   Accepts either a run directory or a project dir.
#   Falls back to $RALPH_RUN_DIR, $RALPH_PROJECT_DIR, or current directory.

INPUT_DIR="${1:-${RALPH_RUN_DIR:-${RALPH_PROJECT_DIR:-$(pwd)}}}"

# If the input dir has a ralph.env, source it for proper paths
if [ -f "$INPUT_DIR/ralph.env" ]; then
  # shellcheck disable=SC1091
  source "$INPUT_DIR/ralph.env"
fi

RUN_DIR="${RALPH_RUN_DIR:-$INPUT_DIR}"
TASKS_FILE="${RALPH_TASKS_FILE:-$RUN_DIR/tasks.json}"
LOG_DIR="${RALPH_LOG_DIR:-$RUN_DIR/logs}"
PROJECT_DIR="${RALPH_PROJECT_DIR:-$INPUT_DIR}"

# ── validation ───────────────────────────────────────────────────────────────

if [ ! -f "$TASKS_FILE" ]; then
  echo "No tasks.json found at $TASKS_FILE"
  echo "Pass a run directory or set RALPH_RUN_DIR."
  exit 1
fi

# ── helpers ──────────────────────────────────────────────────────────────────

pid_status() {
  local name="$1" pid_file="$2"
  if [ -f "$pid_file" ]; then
    local pid
    pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
      echo "$name: RUNNING (PID $pid)"
    else
      echo "$name: DEAD (stale PID $pid)"
    fi
  else
    echo "$name: NOT STARTED"
  fi
}

# ── progress ─────────────────────────────────────────────────────────────────

echo "========================================"
echo "  Ralph Loop Status"
echo "  $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "========================================"
echo ""
echo "Project: $PROJECT_DIR"
[ "$RUN_DIR" != "$PROJECT_DIR" ] && echo "Run dir: $RUN_DIR"
echo ""

# Process status
pid_status "Runner  " "$LOG_DIR/runner.pid"
pid_status "Watchdog" "$LOG_DIR/watchdog.pid"
if [ -f "$LOG_DIR/.paused" ]; then
  echo "Paused:   YES (touch $LOG_DIR/.paused — remove to resume monitoring)"
fi
echo ""

# Task progress (accurate counting against current tasks.json)
python3 -c "
import json, os, sys

tasks_file = '$TASKS_FILE'
log_dir = '$LOG_DIR'

if not os.path.exists(tasks_file):
    print('No tasks.json found')
    sys.exit(0)

tasks = json.load(open(tasks_file))
task_ids = [t['id'] for t in tasks]

done_files = {f.replace('.done','') for f in os.listdir(log_dir) if f.endswith('.done')} if os.path.isdir(log_dir) else set()
skip_files = {f.replace('.skip','') for f in os.listdir(log_dir) if f.endswith('.skip')} if os.path.isdir(log_dir) else set()
running_files = {f.replace('.running','') for f in os.listdir(log_dir) if f.endswith('.running')} if os.path.isdir(log_dir) else set()
escalate_files = {f.replace('.escalate','') for f in os.listdir(log_dir) if f.endswith('.escalate')} if os.path.isdir(log_dir) else set()

done = [t for t in task_ids if t in done_files]
skipped = [t for t in task_ids if t in skip_files]
running = [t for t in task_ids if t in running_files and t not in done_files and t not in skip_files]
escalated = [t for t in task_ids if t in escalate_files]
pending = [t for t in task_ids if t not in done_files and t not in skip_files and t not in running_files]

total = len(task_ids)
pct = int(100 * len(done) / total) if total > 0 else 0
bar_width = 30
filled = int(bar_width * len(done) / total) if total > 0 else 0
bar = '#' * filled + '-' * (bar_width - filled)

print(f'Progress: [{bar}] {pct}%')
print(f'  Done:      {len(done)}/{total}')
print(f'  Skipped:   {len(skipped)}')
print(f'  Running:   {len(running)}')
print(f'  Escalated: {len(escalated)}')
print(f'  Pending:   {len(pending)}')
print()

# Show task list with status
for t in tasks:
    tid = t['id']
    name = t['name']
    if tid in done_files:
        marker = '[DONE]    '
    elif tid in skip_files:
        marker = '[SKIP]    '
    elif tid in escalate_files:
        marker = '[ESCALATE]'
    elif tid in running_files:
        marker = '[RUNNING] '
    else:
        marker = '[       ] '
    print(f'  {marker} {name}')
" 2>/dev/null

echo ""

# Recent events
EVENTS_FILE="$RUN_DIR/events.log"
if [ -f "$EVENTS_FILE" ] && [ -s "$EVENTS_FILE" ]; then
  event_count=$(wc -l < "$EVENTS_FILE")
  echo "--- Recent Events ($event_count total) ---"
  tail -8 "$EVENTS_FILE"
  echo ""
fi

# Start time (from runner.log first line)
if [ -f "$LOG_DIR/runner.log" ]; then
  first_line=$(head -1 "$LOG_DIR/runner.log" 2>/dev/null)
  if [ -n "$first_line" ]; then
    echo "--- Recent runner activity ---"
    tail -5 "$LOG_DIR/runner.log" 2>/dev/null
    echo ""
  fi
fi

# Escalation files
esc_count=$(ls "$LOG_DIR"/*.escalate 2>/dev/null | wc -l)
if [ "$esc_count" -gt 0 ]; then
  echo "--- Active escalations ---"
  for f in "$LOG_DIR"/*.escalate; do
    echo "  $(basename "$f" .escalate)"
  done
  echo ""
fi

# Summary file
if [ -f "$RUN_DIR/summary.md" ]; then
  echo "--- Summary ---"
  echo "  $RUN_DIR/summary.md"
  echo ""
fi

echo "========================================"
