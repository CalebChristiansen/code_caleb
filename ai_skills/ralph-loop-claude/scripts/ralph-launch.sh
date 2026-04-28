#!/usr/bin/env bash
# Ralph Loop — tmux launcher
# Sets up a tmux session with three panes: runner, watchdog, status.
# Run artifacts live in a dedicated run directory (default: ~/.claude/ralph-runs/),
# NOT in the project directory. Override with RALPH_RUNS_BASE env var.
#
# Usage: ralph-launch.sh <project_dir> [--run-dir <path>] [--plan <plan_file>]
#   project_dir: the working directory for claude sessions
#   --run-dir:   pre-created run directory containing tasks.json and optionally ralph.env
#                If omitted, a new timestamped dir is created under $RALPH_RUNS_BASE (default: ~/.claude/ralph-runs/)
#                and tasks.json is NOT copied from the project dir (it must be in --run-dir)
#   --plan:      optional path to plan.md to copy into the run directory
#
# Session is named "ralph-<run_dir_basename>" so multiple loops can run in parallel.
# Attach with: tmux attach -t ralph-<name>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# ── parse args ───────────────────────────────────────────────────────────────

PROJECT_DIR=""
PLAN_FILE=""
USER_RUN_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --plan)
      PLAN_FILE="$2"
      shift 2
      ;;
    --run-dir)
      USER_RUN_DIR="$2"
      shift 2
      ;;
    *)
      if [ -z "$PROJECT_DIR" ]; then
        PROJECT_DIR="$1"
      fi
      shift
      ;;
  esac
done

if [ -z "$PROJECT_DIR" ]; then
  echo "Usage: ralph-launch.sh <project_dir> [--run-dir <path>] [--plan <plan_file>]"
  echo "  project_dir: working directory for claude sessions"
  echo "  --run-dir:   pre-created run directory with tasks.json (default: auto-create timestamped dir)"
  echo "  --plan:      plan file to copy into the run directory"
  exit 1
fi

PROJECT_DIR="$(readlink -f "$PROJECT_DIR")"
PROJECT_BASENAME="$(basename "$PROJECT_DIR")"

# ── resolve run directory ────────────────────────────────────────────────────

if [ -n "$USER_RUN_DIR" ]; then
  # Use the pre-created run directory
  RUN_DIR="$(readlink -f "$USER_RUN_DIR")"
  if [ ! -d "$RUN_DIR" ]; then
    echo "Error: Run directory does not exist: $RUN_DIR"
    exit 1
  fi
  mkdir -p "$RUN_DIR/logs"
  RUN_BASENAME="$(basename "$RUN_DIR")"
else
  # Auto-create a timestamped run directory
  TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
  RUNS_BASE="${RALPH_RUNS_BASE:-$HOME/.claude/ralph-runs}"
  RUN_DIR="${RUNS_BASE}/${PROJECT_BASENAME}-${TIMESTAMP}"
  mkdir -p "$RUN_DIR/logs"
  RUN_BASENAME="${PROJECT_BASENAME}-${TIMESTAMP}"
fi

SESSION_NAME="ralph-${RUN_BASENAME}"

# ── locate tasks.json ──────────────────────────────────────────────────────

if [ ! -f "$RUN_DIR/tasks.json" ]; then
  echo "Error: No tasks.json found in run directory: $RUN_DIR"
  echo "  Create tasks.json in the run directory before launching."
  exit 1
fi

# Copy plan file if provided or auto-detect from .claude/plans/
if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; then
  cp "$PLAN_FILE" "$RUN_DIR/plan.md"
elif [ -d "$HOME/.claude/plans" ]; then
  # Auto-detect: grab the most recently modified plan
  latest_plan=$(ls -t "$HOME/.claude/plans/"*.md 2>/dev/null | head -1)
  if [ -n "$latest_plan" ]; then
    cp "$latest_plan" "$RUN_DIR/plan.md"
    PLAN_FILE="$latest_plan"
  fi
fi

# ── build ralph.env in the run directory ─────────────────────────────────────

DEADLINE=""
MAX_FAILURES="3"
CONTEXT_FILE=""
WATCHDOG_INTERVAL="60"
ESCALATION_TIMEOUT="300"

# If ralph.env already exists in the run dir, source it for custom values
if [ -f "$RUN_DIR/ralph.env" ]; then
  # shellcheck disable=SC1091
  source "$RUN_DIR/ralph.env"
  DEADLINE="${RALPH_DEADLINE:-$DEADLINE}"
  MAX_FAILURES="${RALPH_MAX_FAILURES:-$MAX_FAILURES}"
  CONTEXT_FILE="${RALPH_CONTEXT_FILE:-$CONTEXT_FILE}"
  WATCHDOG_INTERVAL="${RALPH_WATCHDOG_INTERVAL:-$WATCHDOG_INTERVAL}"
  ESCALATION_TIMEOUT="${RALPH_ESCALATION_TIMEOUT:-$ESCALATION_TIMEOUT}"
fi

# (Re)generate ralph.env with all resolved values
cat > "$RUN_DIR/ralph.env" <<ENVEOF
export RALPH_PROJECT_DIR="$PROJECT_DIR"
export RALPH_RUN_DIR="$RUN_DIR"
export RALPH_TASKS_FILE="$RUN_DIR/tasks.json"
export RALPH_LOG_DIR="$RUN_DIR/logs"
export RALPH_DEADLINE="$DEADLINE"
export RALPH_MAX_FAILURES="$MAX_FAILURES"
export RALPH_CONTEXT_FILE="$CONTEXT_FILE"
export RALPH_WATCHDOG_INTERVAL="$WATCHDOG_INTERVAL"
export RALPH_ESCALATION_TIMEOUT="$ESCALATION_TIMEOUT"
export RALPH_PLAN_FILE="${PLAN_FILE:-}"
export RALPH_SESSION="$SESSION_NAME"
ENVEOF

# ── check for existing session ───────────────────────────────────────────────

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  echo "Session '$SESSION_NAME' already exists."
  echo "  Attach: tmux attach -t $SESSION_NAME"
  echo "  Kill:   tmux kill-session -t $SESSION_NAME"
  exit 1
fi

# ── ensure scripts are executable ────────────────────────────────────────────

chmod +x "$SCRIPT_DIR/run_tasks.sh" "$SCRIPT_DIR/watchdog.sh" "$SCRIPT_DIR/ralph-status.sh"

# ── export env for tmux panes ────────────────────────────────────────────────

export RALPH_PROJECT_DIR="$PROJECT_DIR"
export RALPH_RUN_DIR="$RUN_DIR"
export RALPH_TASKS_FILE="$RUN_DIR/tasks.json"
export RALPH_LOG_DIR="$RUN_DIR/logs"
export RALPH_DEADLINE="$DEADLINE"
export RALPH_MAX_FAILURES="$MAX_FAILURES"
export RALPH_CONTEXT_FILE="$CONTEXT_FILE"
export RALPH_WATCHDOG_INTERVAL="$WATCHDOG_INTERVAL"
export RALPH_ESCALATION_TIMEOUT="$ESCALATION_TIMEOUT"
export RALPH_PLAN_FILE="${PLAN_FILE:-}"
export RALPH_SESSION="$SESSION_NAME"

# ── create tmux session ─────────────────────────────────────────────────────

ENV_FILE="$RUN_DIR/ralph.env"

# Force a usable size for detached sessions (no client = no inherited size)
tmux set-option -g default-size 200x50 2>/dev/null || true

# Pane 0 (left): Runner — takes up the left half
tmux new-session -d -s "$SESSION_NAME" -x 200 -y 50 \
  "source '$ENV_FILE' && bash '$SCRIPT_DIR/run_tasks.sh' 2>&1 | tee -a '$RUN_DIR/logs/runner_console.log'; echo '--- Runner exited. Press enter to close. ---'; read"

# Split right side vertically
# Pane 1 (top-right): Watchdog
tmux split-window -h -t "$SESSION_NAME" \
  "source '$ENV_FILE' && bash '$SCRIPT_DIR/watchdog.sh' 2>&1 | tee -a '$RUN_DIR/logs/watchdog_console.log'; echo '--- Watchdog exited. Press enter to close. ---'; read"

# Pane 2 (bottom-right): Status watch (optional — may fail if terminal is too small)
tmux split-window -v -t "$SESSION_NAME" \
  "source '$ENV_FILE' && watch -n 5 -c bash '$SCRIPT_DIR/ralph-status.sh' '$RUN_DIR'" 2>/dev/null || true

# Set pane titles for clarity
tmux select-pane -t "$SESSION_NAME:0.0" -T "Runner" 2>/dev/null || true
tmux select-pane -t "$SESSION_NAME:0.1" -T "Watchdog" 2>/dev/null || true
tmux select-pane -t "$SESSION_NAME:0.2" -T "Status" 2>/dev/null || true

# Enable pane border status line to show titles
tmux set-option -t "$SESSION_NAME" pane-border-status top 2>/dev/null || true

# Focus on the runner pane
tmux select-pane -t "$SESSION_NAME:0.0" 2>/dev/null || true

# ── print startup info ──────────────────────────────────────────────────────

TASK_COUNT=$(python3 -c "import json; print(len(json.load(open('$RUN_DIR/tasks.json'))))" 2>/dev/null || echo "?")

echo ""
echo "Ralph Loop launched in tmux session: $SESSION_NAME"
echo ""
echo "  Run dir:   $RUN_DIR"
echo "  Tasks:     $RUN_DIR/tasks.json ($TASK_COUNT tasks)"
echo "  Logs:      $RUN_DIR/logs/"
[ -n "$PLAN_FILE" ] && echo "  Plan:      $PLAN_FILE"
echo "  Summary:   $RUN_DIR/summary.md (generated on completion)"
echo ""
echo "  tmux:      $SESSION_NAME"
echo "  Attach:    tmux attach -t $SESSION_NAME"
echo "  Detach:    Ctrl-B then D (inside tmux)"
echo "  Kill:      tmux kill-session -t $SESSION_NAME"
echo "  Status:    bash $SCRIPT_DIR/ralph-status.sh $RUN_DIR"
echo ""

# Attach if we're in an interactive terminal
if [ -t 0 ]; then
  tmux attach -t "$SESSION_NAME"
fi