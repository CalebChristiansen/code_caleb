#!/usr/bin/env bash
# Dispatch — status checker
# Shows the current state of a dispatch run.
#
# Usage: dispatch-status.sh [run_dir]
#   Falls back to $DISPATCH_RUN_DIR or the most recent run in ~/.claude/dispatch-runs/

set -euo pipefail

# ── resolve run directory ────────────────────────────────────────────────────

if [ -n "${1:-}" ]; then
  RUN_DIR="$1"
elif [ -n "${DISPATCH_RUN_DIR:-}" ]; then
  RUN_DIR="$DISPATCH_RUN_DIR"
else
  # Find most recent dispatch run
  RUNS_DIR="$HOME/.claude/dispatch-runs"
  if [ -d "$RUNS_DIR" ]; then
    RUN_DIR=$(ls -td "$RUNS_DIR"/*/ 2>/dev/null | head -1)
    RUN_DIR="${RUN_DIR%/}"  # strip trailing slash
  fi
fi

if [ -z "${RUN_DIR:-}" ] || [ ! -d "$RUN_DIR" ]; then
  echo "No dispatch run found."
  echo "Usage: dispatch-status.sh [run_dir]"
  exit 1
fi

# Source env if available
if [ -f "$RUN_DIR/dispatch.env" ]; then
  # shellcheck disable=SC1091
  source "$RUN_DIR/dispatch.env"
fi

# ── status ───────────────────────────────────────────────────────────────────

echo "========================================"
echo "  Dispatch Status"
echo "  $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "========================================"
echo ""
echo "Run dir: $RUN_DIR"
echo "Model:   ${DISPATCH_MODEL:-unknown}"
echo "Project: ${DISPATCH_PROJECT_DIR:-unknown}"
echo ""

# Process status
if [ -f "$RUN_DIR/done" ]; then
  EXIT_CODE=$(cat "$RUN_DIR/done")
  if [ "$EXIT_CODE" = "0" ]; then
    echo "Status: COMPLETE (success)"
  else
    echo "Status: COMPLETE (exit code $EXIT_CODE)"
  fi
elif [ -f "$RUN_DIR/dispatch.pid" ]; then
  PID=$(cat "$RUN_DIR/dispatch.pid")
  if kill -0 "$PID" 2>/dev/null; then
    echo "Status: RUNNING (PID $PID) — interactive TUI"
    SESSION_HINT="dispatch-$(basename "$RUN_DIR")"
    echo "  Attach to interact: tmux attach -t $SESSION_HINT"
  else
    echo "Status: DEAD (stale PID $PID — crashed?)"
  fi
else
  echo "Status: NOT STARTED"
fi

# Duration
if [ -n "${DISPATCH_START:-}" ]; then
  START_EPOCH=$(date -d "$DISPATCH_START" +%s 2>/dev/null || echo "")
  if [ -n "$START_EPOCH" ]; then
    NOW_EPOCH=$(date +%s)
    ELAPSED=$((NOW_EPOCH - START_EPOCH))
    MINUTES=$((ELAPSED / 60))
    SECONDS=$((ELAPSED % 60))
    echo "Elapsed: ${MINUTES}m ${SECONDS}s"
  fi
fi

echo ""

# Recent events (shown first — most useful during a running dispatch)
if [ -f "$RUN_DIR/events.log" ] && [ -s "$RUN_DIR/events.log" ]; then
  event_count=$(wc -l < "$RUN_DIR/events.log")
  echo "--- Recent Events ($event_count total) ---"
  tail -8 "$RUN_DIR/events.log"
  echo ""
fi

# Summary
if [ -f "$RUN_DIR/summary.md" ]; then
  echo "--- Summary ---"
  cat "$RUN_DIR/summary.md"
  echo ""
  echo "----------------"
  echo ""
fi

# Last lines of output
if [ -f "$RUN_DIR/run.log" ]; then
  LOG_LINES=$(wc -l < "$RUN_DIR/run.log")
  echo "Log: $RUN_DIR/run.log ($LOG_LINES lines)"
  echo ""
  echo "--- Last 20 lines ---"
  tail -20 "$RUN_DIR/run.log"
  echo ""
else
  echo "Log: not yet created"
fi

# Show available files
echo "--- Files ---"
for f in prompt.md run.log raw.log stderr.log events.log summary.md done; do
  if [ -f "$RUN_DIR/$f" ]; then
    SIZE=$(wc -c < "$RUN_DIR/$f" | tr -d ' ')
    printf "  %-15s %s bytes\n" "$f" "$SIZE"
  fi
done
echo ""

# tmux session
SESSION_NAME="dispatch-$(basename "$RUN_DIR")"
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  echo "tmux session: $SESSION_NAME (active)"
  echo "  Attach: tmux attach -t $SESSION_NAME"
  echo "  Kill:   tmux kill-session -t $SESSION_NAME"
else
  echo "tmux session: $SESSION_NAME (not running)"
fi

echo ""
echo "========================================"
