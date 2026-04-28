#!/usr/bin/env bash
# Ralph Loop — autonomous task runner
# Spawns a fresh Claude Code session per task. Skips completed tasks on restart.
# Stops when: all tasks done, deadline hit, or max failures reached.
#
# Required env (set via ralph.env):
#   RALPH_PROJECT_DIR   — project root
#   RALPH_RUN_DIR       — run directory for artifacts (tasks, logs, summary)
#   RALPH_TASKS_FILE    — path to tasks.json (default: $RUN_DIR/tasks.json)
#   RALPH_LOG_DIR       — log directory (default: $RUN_DIR/logs)
#   RALPH_DEADLINE      — ISO timestamp deadline (optional, empty = no deadline)
#   RALPH_MAX_FAILURES  — consecutive failure limit (default: 3)
#   RALPH_CONTEXT_FILE  — file with extra context for prompts (optional)
#   RALPH_ESCALATION_TIMEOUT — seconds to wait for watchdog fix (default: 300)
#   RALPH_PLAN_FILE     — path to plan.md for this run (optional)

set -uo pipefail

PROJECT_DIR="${RALPH_PROJECT_DIR:?RALPH_PROJECT_DIR not set}"
RUN_DIR="${RALPH_RUN_DIR:?RALPH_RUN_DIR not set — must point to a run directory}"
TASKS_FILE="${RALPH_TASKS_FILE:-$RUN_DIR/tasks.json}"
LOG_DIR="${RALPH_LOG_DIR:-$RUN_DIR/logs}"
DEADLINE="${RALPH_DEADLINE:-}"
MAX_CONSECUTIVE_FAILURES="${RALPH_MAX_FAILURES:-3}"
CONTEXT_FILE="${RALPH_CONTEXT_FILE:-}"
ESCALATION_WAIT="${RALPH_ESCALATION_TIMEOUT:-300}"
PLAN_FILE="${RALPH_PLAN_FILE:-}"
RALPH_SESSION="${RALPH_SESSION:?RALPH_SESSION not set — launch via ralph-launch.sh}"

cd "$PROJECT_DIR"
mkdir -p "$LOG_DIR"

# Set ERR trap after env is validated so $LOG_DIR is guaranteed to exist
trap 'echo "[$(date "+%H:%M:%S")] RUNNER CRASHED (line $LINENO, exit $?)" | tee -a "$LOG_DIR/runner.log"' ERR

# ── helpers ──────────────────────────────────────────────────────────────────

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_DIR/runner.log"; }

# Send a macOS notification via iTerm2 OSC 9 (works over SSH).
# Falls back to terminal bell if not in iTerm2.
notify() {
  local msg="$1"
  if [ "${TERM_PROGRAM:-}" = "iTerm.app" ] || [ "${LC_TERMINAL:-}" = "iTerm2" ]; then
    printf '\e]9;%s\a' "$msg"
  else
    printf '\a'
  fi
}

past_deadline() {
  [ -z "$DEADLINE" ] && return 1
  local deadline_epoch now_epoch
  deadline_epoch=$(date -d "$DEADLINE" +%s 2>/dev/null || echo 9999999999)
  now_epoch=$(date +%s)
  [ "$now_epoch" -ge "$deadline_epoch" ]
}

task_count() { python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "$TASKS_FILE"; }
task_field() { python3 -c "import json,sys; t=json.load(open(sys.argv[1]))[int(sys.argv[2])]; print(t.get(sys.argv[3],''))" "$TASKS_FILE" "$1" "$2"; }

is_task_done() { [ -f "$LOG_DIR/${1}.done" ]; }
is_task_skipped() { [ -f "$LOG_DIR/${1}.skip" ]; }
mark_done() { date -Iseconds > "$LOG_DIR/${1}.done"; }

run_test() {
  local test_cmd="$1"
  [ -z "$test_cmd" ] && return 0
  bash -c "$test_cmd" >> "$LOG_DIR/tests.log" 2>&1
}

# Format seconds into human-readable duration
format_duration() {
  local secs="$1"
  if [ "$secs" -ge 3600 ]; then
    printf '%dh %dm %ds' $((secs/3600)) $((secs%3600/60)) $((secs%60))
  elif [ "$secs" -ge 60 ]; then
    printf '%dm %ds' $((secs/60)) $((secs%60))
  else
    printf '%ds' "$secs"
  fi
}

# ── main loop ────────────────────────────────────────────────────────────────

# Write PID file so watchdog can track us
echo $$ > "$LOG_DIR/runner.pid"

# Record start state for summary
run_start_epoch=$(date +%s)
run_start_human=$(date '+%Y-%m-%d %H:%M:%S %Z')
git_start_commit=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
git_branch=$(git branch --show-current 2>/dev/null || echo "unknown")

log "=== Ralph Loop starting ==="
log "Project: $PROJECT_DIR"
log "Run dir: $RUN_DIR"
log "Tasks: $(task_count)"
[ -n "$DEADLINE" ] && log "Deadline: $DEADLINE" || log "Deadline: none"

# Print startup info block
log ""
log "  Run dir:   $RUN_DIR"
log "  Tasks:     $TASKS_FILE"
log "  Logs:      $LOG_DIR/"
[ -n "$PLAN_FILE" ] && log "  Plan:      $PLAN_FILE"
log "  Branch:    $git_branch"
log "  Commit:    ${git_start_commit:0:11}"
log ""

# Load extra context if provided
extra_context=""
if [ -n "$CONTEXT_FILE" ] && [ -f "$CONTEXT_FILE" ]; then
  extra_context=$(cat "$CONTEXT_FILE")
  log "Loaded context from $CONTEXT_FILE"
fi

consecutive_failures=0
step_num=0
total=$(task_count)

# Per-task metadata tracking (task_id|status|attempts|duration_s)
TASK_META_FILE="$LOG_DIR/.task_meta"
: > "$TASK_META_FILE"

# Decisions log — task sessions append design decisions and plan changes here
DECISIONS_FILE="$LOG_DIR/decisions.md"
: > "$DECISIONS_FILE"

# Events log — structured append-only log for significant findings, actions, errors
EVENTS_FILE="$RUN_DIR/events.log"
touch "$EVENTS_FILE"

for i in $(seq 0 $((total - 1))); do
  if past_deadline; then
    log "DEADLINE REACHED — stopping"
    notify "Ralph Loop: deadline reached"
    break
  fi

  task_id=$(task_field "$i" "id")
  task_name=$(task_field "$i" "name")
  task_prompt=$(task_field "$i" "prompt")
  task_test=$(task_field "$i" "test")
  task_retries=$(task_field "$i" "retries")
  task_retries=${task_retries:-2}

  # Skip completed or skipped tasks
  if is_task_done "$task_id"; then
    log "SKIP $task_id — already done"
    echo "${task_id}|done|0|0|${task_name}" >> "$TASK_META_FILE"
    continue
  fi
  if is_task_skipped "$task_id"; then
    log "SKIP $task_id — agent marked skip"
    echo "${task_id}|skip|0|0|${task_name}" >> "$TASK_META_FILE"
    continue
  fi

  # Crash recovery guard
  if [ -f "$LOG_DIR/${task_id}.running" ]; then
    log "WARN $task_id — was running when runner last died. Retrying."
  fi
  date -Iseconds > "$LOG_DIR/${task_id}.running"

  log "START $task_id: $task_name"
  echo "[$(date -Iseconds)] TASK_START: $task_name (id: $task_id)" >> "$EVENTS_FILE"
  task_start_epoch=$(date +%s)
  step_num=$((step_num + 1))

  success=false
  final_attempt=0
  for attempt in $(seq 1 $((task_retries + 1))); do
    if past_deadline; then
      log "DEADLINE mid-task — stopping"
      break 2
    fi

    final_attempt=$attempt
    log "  attempt $attempt/$((task_retries + 1))"

    # Signal file lives in the project dir so auto mode trusts writes to it
    SIGNAL_FILE="$PROJECT_DIR/.ralph_done"
    rm -f "$SIGNAL_FILE"

    # Paths for this attempt
    CLEAN_LOG="$LOG_DIR/${task_id}_attempt${attempt}.log"
    PROMPT_FILE="$LOG_DIR/${task_id}_attempt${attempt}_prompt.md"
    ADDENDUM_FILE="$LOG_DIR/${task_id}_attempt${attempt}_system.md"
    WRAPPER_SCRIPT="$LOG_DIR/${task_id}_attempt${attempt}_run.sh"

    # Window naming: "Step N: task_name" (truncated to fit tmux tab bar)
    if [ "$attempt" -eq 1 ]; then
      WINDOW_NAME="Step ${step_num}: ${task_name:0:40}"
    else
      WINDOW_NAME="Step ${step_num}: ${task_name:0:30} (retry ${attempt})"
    fi

    # Write task prompt to file (read by wrapper at runtime)
    # Use printf to avoid shell metacharacter interpretation in task content
    {
      printf 'You are working on a project in %s.\n' "$(pwd)"
      printf '%s\n\n' "$extra_context"
      printf 'YOUR TASK: %s\n\n' "$task_prompt"
      printf 'VERIFICATION: After completing the task, run this test command to verify:\n'
      printf '%s\n\n' "$task_test"
      printf 'If the test fails, fix the issue and try again. Do not move on until the test passes.\n'
    } > "$PROMPT_FILE"

    # Write system addendum to file (injected via --append-system-prompt)
    cat > "$ADDENDUM_FILE" <<SYSEOF
WHEN DONE: After completing your task and verifying the test passes:
1. Stage and commit your changes with a descriptive commit message (no Co-Authored-By lines)
2. Create a file called $SIGNAL_FILE containing a one-line summary of what you did (use the Write tool or echo)

CRITICAL: Writing that file is the LAST thing you do. After creating it, STOP IMMEDIATELY. Do not take any further actions, do not start new work, do not invoke any skills or commands. The session will be terminated automatically.
SYSEOF

    # Generate per-task wrapper script (like dispatch's _run.sh)
    {
      echo "#!/usr/bin/env bash"
      echo "set -uo pipefail"
      echo ""
      echo "PROJ='$PROJECT_DIR'"
      echo "CLEAN='$CLEAN_LOG'"
      echo "SIG='$SIGNAL_FILE'"
      echo "PROMPT='$PROMPT_FILE'"
      echo "ADDENDUM='$ADDENDUM_FILE'"
      echo "SESSION='$RALPH_SESSION'"
      echo "WIN_IDX_FILE='$LOG_DIR/${task_id}_window_index'"
      echo "TASK_NAME='$task_name'"
      echo "TASK_ID='$task_id'"
      echo "TASK_SUMMARY_FILE='$LOG_DIR/${task_id}_summary.md'"
      echo "RUN_DIR='$RUN_DIR'"
      echo ""
      cat <<'BODYEOF'
cd "$PROJ"

TASK_PROMPT="$(cat "$PROMPT")"
EVENTS_ADDENDUM="$(cat "$ADDENDUM")"

# Wait for the runner to write our window index
while [ ! -f "$WIN_IDX_FILE" ]; do sleep 0.2; done
WIN_IDX="$(cat "$WIN_IDX_FILE")"

# Capture raw tmux output for logging
PANE_ID="${SESSION}:${WIN_IDX}.0"
tmux pipe-pane -t "$PANE_ID" "cat >> '$CLEAN'" 2>/dev/null || true

# Run interactive Claude TUI — named for resume support
EXIT_CODE=0
claude --permission-mode auto \
  --name "ralph: $TASK_NAME" \
  --add-dir "$RUN_DIR" \
  --append-system-prompt "$EVENTS_ADDENDUM" \
  "$TASK_PROMPT" &
CLAUDE_PID=$!

# Background watcher: kill Claude once signal file appears (safety net if agent forgets /exit)
(while [ ! -f "$SIG" ]; do sleep 2; done; sleep 2; kill $CLAUDE_PID 2>/dev/null) &
WATCHER_PID=$!

wait $CLAUDE_PID 2>/dev/null || true
EXIT_CODE=$?
kill $WATCHER_PID 2>/dev/null || true

# Stop pipe-pane capture
tmux pipe-pane -t "$PANE_ID" 2>/dev/null || true

# Strip ANSI escape codes from raw capture to produce a searchable log
if [ -f "$CLEAN" ]; then
  perl -pe 's/\e\[[0-9;]*[a-zA-Z]//g; s/\e\][^\a]*\a//g; s/\e\([AB)//g; s/\r//g' \
    "$CLEAN" > "${CLEAN}.tmp" && mv "${CLEAN}.tmp" "$CLEAN"
fi

# Safety net: if agent didn't signal completion, do it now
if [ ! -f "$SIG" ]; then
  echo "$EXIT_CODE" > "$SIG"
fi

# Generate per-task summary
echo ""
echo "========================================"
echo "  Task Complete: $TASK_NAME"
echo "========================================"
if [ -f "$CLEAN" ] && [ -s "$CLEAN" ]; then
  SUMMARY_PROMPT="Summarize this Claude Code task session in 3-5 bullet points. Cover: what was done, key decisions, and final result (pass/fail). Be concise."
  SUMMARY=$(tail -200 "$CLEAN" | claude -p --permission-mode auto "$SUMMARY_PROMPT" 2>/dev/null || echo "(summary generation failed)")
  echo "$SUMMARY"
  {
    echo "# Task: $TASK_NAME"
    echo ""
    echo "$SUMMARY"
  } > "$TASK_SUMMARY_FILE"
  echo ""
  echo "  Summary saved: $TASK_SUMMARY_FILE"
else
  echo "  (no log output to summarize)"
fi
echo ""
echo "  Resume session:  claude --resume \"ralph: $TASK_NAME\""
echo "  Full log:        $CLEAN"
echo "========================================"
echo ""
echo "Press enter to close this window."
BODYEOF
    } > "$WRAPPER_SCRIPT"
    chmod +x "$WRAPPER_SCRIPT"

    log "  launching tmux window: $WINDOW_NAME"
    WINDOW_INDEX=$(tmux new-window -t "$RALPH_SESSION" -n "$WINDOW_NAME" -P -F '#{window_index}' \
      "bash '$WRAPPER_SCRIPT'; read")
    # Write window index so the wrapper can set up pipe-pane
    echo "$WINDOW_INDEX" > "$LOG_DIR/${task_id}_window_index"
    # Prevent tmux from renaming the window to "bash" or "claude"
    tmux set-option -t "${RALPH_SESSION}:${WINDOW_INDEX}" automatic-rename off 2>/dev/null || true

    # Wait for signal_done (agent completion or TUI exit safety net)
    while [ ! -f "$SIGNAL_FILE" ]; do
      sleep 5
      # Check if the tmux window died without creating signal file
      if ! tmux list-windows -t "$RALPH_SESSION" -F '#{window_index}' 2>/dev/null | grep -qF "$WINDOW_INDEX"; then
        log "  window disappeared — treating as completion"
        echo "1" > "$SIGNAL_FILE"
        break
      fi
      past_deadline && break 2
    done

    if run_test "$task_test"; then
      log "  PASS"
      mark_done "$task_id"
      rm -f "$LOG_DIR/${task_id}.running"
      success=true
      consecutive_failures=0

      # Log agent's completion summary to events.log, then clean up
      if [ -f "$SIGNAL_FILE" ]; then
        agent_summary=$(head -1 "$SIGNAL_FILE")
        [ -n "$agent_summary" ] && [ "$agent_summary" != "0" ] && \
          echo "[$(date -Iseconds)] TASK_COMPLETE: $agent_summary" >> "$EVENTS_FILE"
        rm -f "$SIGNAL_FILE"
      fi

      # Safety net: commit any uncommitted changes the agent missed
      # Use git add -u (tracked files only) to avoid staging ralph artifacts
      if ! git diff --quiet HEAD 2>/dev/null; then
        git add -u 2>/dev/null || true
        git commit -m "ralph: $task_name" 2>/dev/null || true
        log "  committed (fallback)"
      fi

      break
    else
      log "  FAIL (attempt $attempt)"

      # On final retry, write escalation for watchdog
      if [ "$attempt" -eq "$((task_retries + 1))" ]; then
        log "  ESCALATING to watchdog..."
        last_log=$(tail -80 "$LOG_DIR/${task_id}_attempt${attempt}.log" 2>/dev/null)
        test_output=$(bash -c "$task_test" 2>&1 || true)

        # Use printf to safely write escalation (avoid shell metachar interpretation)
        {
          printf 'TASK FAILURE — needs agent diagnosis.\n\n'
          printf 'Task: %s (id: %s)\n' "$task_name" "$task_id"
          printf 'Test command: %s\n' "$task_test"
          printf 'Test output:\n%s\n\n' "$test_output"
          printf 'Last 80 lines of Claude Code output:\n%s\n\n' "$last_log"
          printf 'Full log: %s\n' "$LOG_DIR/${task_id}_attempt${attempt}.log"
          printf 'Task definition: %s (id: %s)\n\n' "$TASKS_FILE" "$task_id"
          printf 'Fix the code directly. Re-run the test: %s\n' "$task_test"
          printf 'If fixed: touch %s\n' "$LOG_DIR/${task_id}.done"
          printf 'If unfixable: write reason to %s\n' "$LOG_DIR/${task_id}.skip"
        } > "$LOG_DIR/${task_id}.escalate"

        notify "Ralph Loop: $task_name failed — escalated"

        # Wait for watchdog fix (synced with RALPH_ESCALATION_TIMEOUT)
        waited=0
        while [ $waited -lt "$ESCALATION_WAIT" ]; do
          [ -f "$LOG_DIR/${task_id}.done" ] || [ -f "$LOG_DIR/${task_id}.skip" ] && break
          sleep 15
          waited=$((waited + 15))
          past_deadline && break 2
        done

        if [ -f "$LOG_DIR/${task_id}.done" ]; then
          log "  WATCHDOG FIX"
          success=true
          consecutive_failures=0
          rm -f "$LOG_DIR/${task_id}.escalate" "$LOG_DIR/${task_id}.running"

          # Safety net: commit any uncommitted watchdog changes
          # Use git add -u (tracked files only) to avoid staging ralph artifacts
          if ! git diff --quiet HEAD 2>/dev/null; then
            git add -u 2>/dev/null || true
            git commit -m "ralph: $task_name (watchdog fix)" 2>/dev/null || true
            log "  committed (watchdog fallback)"
          fi
        elif [ -f "$LOG_DIR/${task_id}.skip" ]; then
          log "  WATCHDOG SKIPPED — $(cat "$LOG_DIR/${task_id}.skip")"
          rm -f "$LOG_DIR/${task_id}.escalate" "$LOG_DIR/${task_id}.running"
        else
          log "  WATCHDOG TIMEOUT — no fix in ${ESCALATION_WAIT}s"
          # Clean up to prevent infinite re-escalation
          rm -f "$LOG_DIR/${task_id}.escalate" "$LOG_DIR/${task_id}.running"
        fi
      fi
    fi
  done

  # Record task metadata
  task_end_epoch=$(date +%s)
  task_duration=$((task_end_epoch - task_start_epoch))

  if [ "$success" = true ]; then
    log "DONE $task_id"
    echo "[$(date -Iseconds)] TASK_DONE: $task_name — passed in ${task_duration}s (attempt $final_attempt)" >> "$EVENTS_FILE"
    notify "Ralph Loop: $task_name — passed"
    echo "${task_id}|done|${final_attempt}|${task_duration}|${task_name}" >> "$TASK_META_FILE"
  else
    if is_task_skipped "$task_id"; then
      log "SKIPPED $task_id"
      echo "[$(date -Iseconds)] TASK_SKIP: $task_name — skipped" >> "$EVENTS_FILE"
      echo "${task_id}|skip|${final_attempt}|${task_duration}|${task_name}" >> "$TASK_META_FILE"
    else
      log "FAILED $task_id"
      echo "[$(date -Iseconds)] TASK_FAIL: $task_name — failed after $final_attempt attempts (${task_duration}s)" >> "$EVENTS_FILE"
      echo "${task_id}|fail|${final_attempt}|${task_duration}|${task_name}" >> "$TASK_META_FILE"
    fi
    notify "Ralph Loop: $task_name — FAILED"
    consecutive_failures=$((consecutive_failures + 1))

    if [ "$consecutive_failures" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
      log "TOO MANY CONSECUTIVE FAILURES ($consecutive_failures) — stopping"
      notify "Ralph Loop STOPPED: $MAX_CONSECUTIVE_FAILURES consecutive failures"
      break
    fi
  fi

  # ── incremental summary — append after each task ──────────────────────────
  SUMMARY_FILE="$RUN_DIR/summary.md"
  task_dur_human=$(format_duration "$task_duration")
  if [ "$success" = true ]; then
    task_status="Done"
  elif is_task_skipped "$task_id"; then
    task_status="Skipped"
  else
    task_status="**FAILED**"
  fi

  {
    echo "### $task_name"
    echo "**Status**: $task_status | **Attempt**: $final_attempt | **Duration**: $task_dur_human"
    echo ""
    # Last ~20 lines of Claude output (the conclusion)
    if [ -f "$LOG_DIR/${task_id}_attempt${final_attempt}.log" ]; then
      echo '```'
      tail -20 "$LOG_DIR/${task_id}_attempt${final_attempt}.log"
      echo '```'
      echo ""
    fi
    # Events logged during this task (between TASK_START and TASK_DONE/FAIL/SKIP)
    if [ -f "$EVENTS_FILE" ]; then
      # Escape regex metacharacters in task name for safe sed matching
      escaped_task_name=$(printf '%s' "$task_name" | sed 's/[.[\(*^$\\]/\\&/g')
      task_events=$(sed -n "/TASK_START: ${escaped_task_name}/,/TASK_\(DONE\|FAIL\|SKIP\): ${escaped_task_name}/p" "$EVENTS_FILE" \
        | grep -v "TASK_START:\|TASK_DONE:\|TASK_FAIL:\|TASK_SKIP:" || true)
      if [ -n "$task_events" ]; then
        echo "**Events:**"
        echo "$task_events"
        echo ""
      fi
    fi
    echo "---"
    echo ""
  } >> "$SUMMARY_FILE"
done

# ── generate summary ────────────────────────────────────────────────────────

run_end_epoch=$(date +%s)
run_end_human=$(date '+%Y-%m-%d %H:%M:%S %Z')
run_duration=$((run_end_epoch - run_start_epoch))
run_duration_human=$(format_duration "$run_duration")

# Accurate count: cross-reference .done files against current tasks.json
done_count=$(python3 -c "
import json,os,sys
tasks=json.load(open(sys.argv[1]))
done={f.replace('.done','') for f in os.listdir(sys.argv[2]) if f.endswith('.done')}
print(len([t for t in tasks if t['id'] in done]))
" "$TASKS_FILE" "$LOG_DIR")

skip_count=$(python3 -c "
import json,os,sys
tasks=json.load(open(sys.argv[1]))
skipped={f.replace('.skip','') for f in os.listdir(sys.argv[2]) if f.endswith('.skip')}
print(len([t for t in tasks if t['id'] in skipped]))
" "$TASKS_FILE" "$LOG_DIR")

fail_count=$((total - done_count - skip_count))

log "=== Ralph Loop finished ==="
log "Completed: $done_count / $total tasks"

# Build the final summary — preserve incremental task details written during the loop
SUMMARY_FILE="$RUN_DIR/summary.md"
incremental_content=""
if [ -f "$SUMMARY_FILE" ]; then
  incremental_content=$(cat "$SUMMARY_FILE")
fi

{
  echo "# Ralph Loop Summary"
  echo ""
  echo "## Run Info"
  echo "- **Project**: $PROJECT_DIR"
  echo "- **Branch**: $git_branch"
  echo "- **Started**: $run_start_human"
  echo "- **Finished**: $run_end_human"
  echo "- **Duration**: $run_duration_human"
  if [ "$done_count" -eq "$total" ]; then
    echo "- **Result**: $done_count/$total tasks completed"
  else
    echo "- **Result**: $done_count done, $skip_count skipped, $fail_count failed (of $total)"
  fi
  [ -n "$PLAN_FILE" ] && echo "- **Plan**: $PLAN_FILE"
  echo "- **Run dir**: $RUN_DIR"
  echo ""

  # Task results table
  echo "## Task Results"
  echo ""
  echo "| # | Task | Status | Attempts | Duration |"
  echo "|---|------|--------|----------|----------|"

  task_num=0
  while IFS='|' read -r tid tstatus tattempts tduration tname; do
    task_num=$((task_num + 1))
    [ -z "$tid" ] && continue

    # Format status
    case "$tstatus" in
      done) status_str="Done" ;;
      skip) status_str="Skipped" ;;
      fail) status_str="**FAILED**" ;;
      *) status_str="$tstatus" ;;
    esac

    # Get max attempts from tasks.json
    max_attempts=$(python3 -c "
import json,sys
tasks=json.load(open(sys.argv[1]))
t=next((x for x in tasks if x['id']==sys.argv[2]),None)
print(int(t.get('retries',2))+1 if t else '?')
" "$TASKS_FILE" "$tid" 2>/dev/null || echo "?")

    # Format duration
    if [ "$tduration" -gt 0 ] 2>/dev/null; then
      dur_str=$(format_duration "$tduration")
    else
      dur_str="-"
    fi

    echo "| $task_num | $tname | $status_str | $tattempts/$max_attempts | $dur_str |"
  done < "$TASK_META_FILE"

  echo ""

  # Incremental task details (written during the loop as tasks completed)
  if [ -n "$incremental_content" ]; then
    echo "## Task Details"
    echo ""
    echo "$incremental_content"
    echo ""
  fi

  # Failures and escalations
  echo "## Failures & Escalations"
  echo ""

  has_failures=false
  while IFS='|' read -r tid tstatus tattempts tduration tname; do
    [ -z "$tid" ] && continue
    if [ "$tstatus" = "fail" ] || [ "$tstatus" = "skip" ]; then
      has_failures=true
      echo "### $tname (\`$tid\`)"
      echo ""
      echo "- **Status**: $tstatus"
      echo "- **Attempts**: $tattempts"

      # Include skip reason if available
      if [ -f "$LOG_DIR/${tid}.skip" ]; then
        echo "- **Reason**: $(cat "$LOG_DIR/${tid}.skip")"
      fi

      # Show last test output
      if [ -f "$LOG_DIR/tests.log" ]; then
        last_test=$(grep -A 20 "$tid" "$LOG_DIR/tests.log" 2>/dev/null | tail -10)
        if [ -n "$last_test" ]; then
          echo "- **Last test output**:"
          echo '```'
          echo "$last_test"
          echo '```'
        fi
      fi

      # Link to logs
      echo "- **Logs**: \`$LOG_DIR/${tid}_attempt${tattempts}.log\`"
      if [ -f "$LOG_DIR/${tid}_escalation.log" ]; then
        echo "- **Escalation log**: \`$LOG_DIR/${tid}_escalation.log\`"
      fi
      echo ""
    fi
  done < "$TASK_META_FILE"

  if [ "$has_failures" = false ]; then
    echo "No failures or escalations."
    echo ""
  fi

  # Design decisions
  echo "## Design Decisions & Plan Changes"
  echo ""
  if [ -s "$DECISIONS_FILE" ]; then
    cat "$DECISIONS_FILE"
  else
    echo "No design decisions were logged during this run."
  fi
  echo ""

  # Event log
  echo "## Event Log"
  echo ""
  if [ -f "$EVENTS_FILE" ] && [ -s "$EVENTS_FILE" ]; then
    echo '```'
    cat "$EVENTS_FILE"
    echo '```'
  else
    echo "No events were logged during this run."
  fi
  echo ""

  # Files changed
  echo "## Files Changed"
  echo ""
  git_end_commit=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
  if [ "$git_start_commit" != "unknown" ] && [ "$git_end_commit" != "unknown" ] && [ "$git_start_commit" != "$git_end_commit" ]; then
    echo '```'
    git diff --stat "${git_start_commit}..${git_end_commit}" 2>/dev/null || echo "(could not compute diff)"
    echo '```'

    echo ""
    echo "**New files:**"
    echo ""
    git diff --diff-filter=A --name-only "${git_start_commit}..${git_end_commit}" 2>/dev/null | while read -r f; do
      echo "- \`$f\`"
    done
  else
    echo "No git changes detected (start and end commits are the same)."
  fi
  echo ""

  # How to continue
  echo "## How to Continue"
  echo ""
  echo "- **Branch**: \`$git_branch\`"
  echo "- **Run tests**: Check test commands in the task definitions"
  echo "- **Logs**: \`$LOG_DIR/\`"
  echo "- **Review task output**: \`cat $LOG_DIR/<task-id>_attempt1.log\`"
  echo "- **Runner log**: \`$LOG_DIR/runner.log\`"
  echo "- **Tasks definition**: \`$TASKS_FILE\`"
  [ -n "$PLAN_FILE" ] && echo "- **Plan**: \`$PLAN_FILE\`"

} > "$SUMMARY_FILE"

log "Summary: $SUMMARY_FILE"

notify "Ralph Loop finished: $done_count/$total tasks — summary at $SUMMARY_FILE"
log "Done."

# Clean up PID file
rm -f "$LOG_DIR/runner.pid"
