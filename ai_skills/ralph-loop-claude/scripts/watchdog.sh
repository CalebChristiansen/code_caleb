#!/usr/bin/env bash
# Ralph Loop — watchdog
# Monitors the task runner, handles escalations by spawning claude -p,
# checks runner health, and reports progress. Replaces the OpenClaw
# heartbeat cron from the original setup.
#
# Required env (set via ralph.env, same as run_tasks.sh):
#   RALPH_PROJECT_DIR   — project root
#   RALPH_TASKS_FILE    — path to tasks.json
#   RALPH_LOG_DIR       — log directory
#
# Optional env:
#   RALPH_WATCHDOG_INTERVAL — seconds between checks (default: 60)
#   RALPH_ESCALATION_TIMEOUT — seconds to wait for claude -p fix (default: 300)

set -uo pipefail

PROJECT_DIR="${RALPH_PROJECT_DIR:?RALPH_PROJECT_DIR not set}"
RUN_DIR="${RALPH_RUN_DIR:?RALPH_RUN_DIR not set — must point to a run directory}"
TASKS_FILE="${RALPH_TASKS_FILE:-$RUN_DIR/tasks.json}"
LOG_DIR="${RALPH_LOG_DIR:-$RUN_DIR/logs}"
INTERVAL="${RALPH_WATCHDOG_INTERVAL:-60}"
ESCALATION_TIMEOUT="${RALPH_ESCALATION_TIMEOUT:-300}"
WATCHDOG_LOG="$LOG_DIR/watchdog.log"

# ── helpers ──────────────────────────────────────────────────────────────────

wlog() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$WATCHDOG_LOG"; }

notify() {
  local msg="$1"
  if [ "${TERM_PROGRAM:-}" = "iTerm.app" ] || [ "${LC_TERMINAL:-}" = "iTerm2" ]; then
    printf '\e]9;%s\a' "$msg"
  else
    printf '\a'
  fi
}

task_count() { python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "$TASKS_FILE"; }
task_field() { python3 -c "import json,sys; t=json.load(open(sys.argv[1]))[int(sys.argv[2])]; print(t.get(sys.argv[3],''))" "$TASKS_FILE" "$1" "$2"; }

# Count tasks accurately against current tasks.json (not stale .done files)
count_progress() {
  python3 -c "
import json, os
tasks = json.load(open('$TASKS_FILE'))
task_ids = [t['id'] for t in tasks]
done = [f.replace('.done','') for f in os.listdir('$LOG_DIR') if f.endswith('.done')]
skipped = [f.replace('.skip','') for f in os.listdir('$LOG_DIR') if f.endswith('.skip')]
current_done = [t for t in task_ids if t in done]
current_skip = [t for t in task_ids if t in skipped]
remaining = [t for t in task_ids if t not in done and t not in skipped]
print(f'{len(current_done)}|{len(current_skip)}|{len(remaining)}|{len(task_ids)}')
for t in remaining[:3]:
    name = next((x['name'] for x in tasks if x['id'] == t), t)
    print(f'NEXT:{name}')
"
}

runner_alive() {
  local pid_file="$LOG_DIR/runner.pid"
  if [ -f "$pid_file" ]; then
    local pid
    pid=$(cat "$pid_file")
    kill -0 "$pid" 2>/dev/null && return 0
  fi
  return 1
}

runner_pid() {
  [ -f "$LOG_DIR/runner.pid" ] && cat "$LOG_DIR/runner.pid" || echo ""
}

# ── escalation handler ──────────────────────────────────────────────────────

handle_escalation() {
  local esc_file="$1"
  local task_id
  task_id=$(basename "$esc_file" .escalate)

  wlog "ESCALATION: handling $task_id"
  notify "Watchdog: escalation for $task_id"

  local esc_content
  esc_content=$(cat "$esc_file")

  # Build a prompt for claude to diagnose and fix
  local fix_prompt="You are a watchdog agent for an autonomous coding loop.
Working directory: $PROJECT_DIR

A task has failed all retry attempts and needs your diagnosis.

$esc_content

Instructions:
1. Read the full log file referenced above
2. Diagnose the root cause
3. Fix the code directly (edit files, run commands as needed)
4. Re-run the test command to verify your fix
5. If fixed successfully: run 'date -Iseconds > $LOG_DIR/${task_id}.done'
6. If truly unfixable: write a reason to '$LOG_DIR/${task_id}.skip'

Do NOT move on without either creating the .done or .skip file."

  wlog "  spawning claude -p for escalation fix..."
  local esc_log="$LOG_DIR/${task_id}_escalation.log"
  timeout "$ESCALATION_TIMEOUT" \
    claude -p --dangerously-skip-permissions "$fix_prompt" \
    2>&1 | tee "$esc_log" || true

  if [ -f "$LOG_DIR/${task_id}.done" ]; then
    wlog "  ESCALATION FIXED: $task_id"
    notify "Watchdog: $task_id fixed by escalation"
    rm -f "$esc_file"
  elif [ -f "$LOG_DIR/${task_id}.skip" ]; then
    wlog "  ESCALATION SKIPPED: $task_id — $(cat "$LOG_DIR/${task_id}.skip")"
    notify "Watchdog: $task_id marked unfixable"
    rm -f "$esc_file"
  else
    wlog "  ESCALATION INCONCLUSIVE: $task_id (claude timed out or didn't resolve)"
    notify "Watchdog: escalation for $task_id inconclusive"
    # Leave .escalate file in place — runner will time out and move on
  fi
}

# ── restart runner ───────────────────────────────────────────────────────────

restart_runner() {
  wlog "RESTARTING runner..."
  notify "Watchdog: restarting runner"

  # Source ralph.env from the run directory, then launch
  cd "$PROJECT_DIR"
  local script_dir
  script_dir="$(dirname "$(readlink -f "$0")")"
  nohup bash -c "source '$RUN_DIR/ralph.env' && bash '$script_dir/run_tasks.sh'" >> "$LOG_DIR/runner.log" 2>&1 &
  local new_pid=$!
  echo "$new_pid" > "$LOG_DIR/runner.pid"
  wlog "  runner restarted (PID: $new_pid)"
}

# ── main loop ────────────────────────────────────────────────────────────────

EVENTS_FILE="$RUN_DIR/events.log"

mkdir -p "$LOG_DIR"
echo $$ > "$LOG_DIR/watchdog.pid"

wlog "=== Watchdog starting ==="
wlog "Project: $PROJECT_DIR"
wlog "Interval: ${INTERVAL}s"
wlog "Escalation timeout: ${ESCALATION_TIMEOUT}s"

cycle=0

# Track events.log position for incremental tailing
events_last_line=0
if [ -f "$EVENTS_FILE" ]; then
  events_last_line=$(wc -l < "$EVENTS_FILE")
fi

# Track last known HEAD for git diff notifications
last_known_head=$(cd "$PROJECT_DIR" && git rev-parse HEAD 2>/dev/null || echo "unknown")

while true; do
  cycle=$((cycle + 1))

  # 1. Handle escalations
  for esc_file in "$LOG_DIR"/*.escalate; do
    [ -f "$esc_file" ] || continue
    handle_escalation "$esc_file"
  done

  # 2. Check runner health (with pause/idle awareness)
  if ! runner_alive; then
    # Is there still work to do?
    progress=$(count_progress)
    remaining=$(echo "$progress" | head -1 | cut -d'|' -f3)
    total=$(echo "$progress" | head -1 | cut -d'|' -f4)
    done_count=$(echo "$progress" | head -1 | cut -d'|' -f1)
    skip_count=$(echo "$progress" | head -1 | cut -d'|' -f2)
    finished=$((done_count + skip_count))

    if [ "$finished" -ge "$total" ]; then
      wlog "ALL TASKS COMPLETE ($done_count done, $skip_count skipped out of $total)"
      notify "Ralph Loop complete: $done_count/$total done, $skip_count skipped"
      wlog "=== Watchdog exiting (loop complete) ==="
      rm -f "$LOG_DIR/watchdog.pid"
      exit 0
    else
      wlog "RUNNER DIED with $remaining tasks remaining — restarting"
      restart_runner
    fi
  else
    # Runner is alive — check for idle/paused state
    if [ ! -f "$LOG_DIR/.paused" ]; then
      # Find the most recently modified log file to gauge activity
      latest_log=$(ls -t "$LOG_DIR"/*.log 2>/dev/null | head -1)
      if [ -n "$latest_log" ]; then
        last_mod=$(stat -c %Y "$latest_log" 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        idle_secs=$((now_epoch - last_mod))
        # 15 minutes = 900 seconds
        if [ "$idle_secs" -ge 900 ]; then
          idle_min=$((idle_secs / 60))
          wlog "IDLE: runner alive but no log output for ${idle_min}m (PID: $(runner_pid))"
          notify "Ralph: agent seems idle (${idle_min}m no output) — paused or stuck?"
        fi
      fi
    fi
  fi

  # 3. Progress report (every 5 cycles = ~5 min with default interval)
  if [ $((cycle % 5)) -eq 0 ]; then
    progress=$(count_progress)
    stats=$(echo "$progress" | head -1)
    done_count=$(echo "$stats" | cut -d'|' -f1)
    skip_count=$(echo "$stats" | cut -d'|' -f2)
    remaining=$(echo "$stats" | cut -d'|' -f3)
    total=$(echo "$stats" | cut -d'|' -f4)

    pid_info=""
    runner_alive && pid_info="(PID: $(runner_pid))" || pid_info="(DEAD)"

    wlog "PROGRESS: $done_count/$total done, $skip_count skipped, $remaining remaining — runner $pid_info"

    # Show next tasks
    echo "$progress" | grep "^NEXT:" | while read -r line; do
      wlog "  ${line}"
    done
  fi

  # 4. Tail events.log for new entries, notify on FINDING/ERROR/TASK_FAIL
  if [ -f "$EVENTS_FILE" ]; then
    current_line=$(wc -l < "$EVENTS_FILE")
    if [ "$current_line" -gt "$events_last_line" ]; then
      new_events=$(tail -n +"$((events_last_line + 1))" "$EVENTS_FILE")
      while IFS= read -r event_line; do
        [ -z "$event_line" ] && continue
        wlog "EVENT: $event_line"
        # Notify on high-severity events
        if echo "$event_line" | grep -qE 'FINDING:|ERROR:|TASK_FAIL:'; then
          notify "Ralph: $event_line"
        fi
      done <<< "$new_events"
      events_last_line=$current_line
    fi
  fi

  # 5. Check for git changes (task completion = new commits)
  current_head=$(cd "$PROJECT_DIR" && git rev-parse HEAD 2>/dev/null || echo "unknown")
  if [ "$current_head" != "$last_known_head" ] && [ "$last_known_head" != "unknown" ] && [ "$current_head" != "unknown" ]; then
    diff_stat=$(cd "$PROJECT_DIR" && git diff --stat "${last_known_head}..${current_head}" 2>/dev/null || echo "")
    if [ -n "$diff_stat" ]; then
      wlog "GIT CHANGES since last check:"
      echo "$diff_stat" | while IFS= read -r line; do
        wlog "  $line"
      done
      notify "Ralph: new commits pushed — $(echo "$diff_stat" | tail -1)"
    fi
    last_known_head=$current_head
  fi

  sleep "$INTERVAL"
done