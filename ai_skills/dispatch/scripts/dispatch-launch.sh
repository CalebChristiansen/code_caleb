#!/usr/bin/env bash
# Dispatch — tmux launcher
# Launches a background claude -p session in a tmux session with log tailing.
#
# Usage: dispatch-launch.sh <project_dir> --run-dir <path> [--model <model>]
#   project_dir: the working directory for the claude session
#   --run-dir:   run directory containing prompt.md
#   --model:     claude model to use (default: claude-opus-4-6)
#
# Session is named "dispatch-<run_dir_basename>".
# Attach with: tmux attach -t dispatch-<name>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# ── parse args ───────────────────────────────────────────────────────────────

PROJECT_DIR=""
RUN_DIR=""
MODEL="claude-opus-4-6"

while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir)
      RUN_DIR="$2"
      shift 2
      ;;
    --model)
      MODEL="$2"
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

if [ -z "$PROJECT_DIR" ] || [ -z "$RUN_DIR" ]; then
  echo "Usage: dispatch-launch.sh <project_dir> --run-dir <path> [--model <model>]"
  exit 1
fi

PROJECT_DIR="$(readlink -f "$PROJECT_DIR")"
RUN_DIR="$(readlink -f "$RUN_DIR")"

# ── validate ─────────────────────────────────────────────────────────────────

if [ ! -d "$RUN_DIR" ]; then
  echo "Error: Run directory does not exist: $RUN_DIR"
  exit 1
fi

if [ ! -f "$RUN_DIR/prompt.md" ]; then
  echo "Error: No prompt.md found in run directory: $RUN_DIR"
  exit 1
fi

RUN_BASENAME="$(basename "$RUN_DIR")"
SESSION_NAME="dispatch-${RUN_BASENAME}"

# ── check for existing session ───────────────────────────────────────────────

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  echo "Session '$SESSION_NAME' already exists."
  echo "  Attach: tmux attach -t $SESSION_NAME"
  echo "  Kill:   tmux kill-session -t $SESSION_NAME"
  exit 1
fi

# ── write dispatch.env ───────────────────────────────────────────────────────

cat > "$RUN_DIR/dispatch.env" <<ENVEOF
export DISPATCH_PROJECT_DIR="$PROJECT_DIR"
export DISPATCH_RUN_DIR="$RUN_DIR"
export DISPATCH_MODEL="$MODEL"
export DISPATCH_SESSION="$SESSION_NAME"
export DISPATCH_START="$(date -Iseconds)"
ENVEOF

# ── build the runner script ──────────────────────────────────────────────────
# We write a small wrapper script so tmux can run it cleanly.

cat > "$RUN_DIR/_run.sh" <<RUNEOF
#!/usr/bin/env bash
set -uo pipefail

source "\$DISPATCH_RUN_DIR/dispatch.env"

cd "\$DISPATCH_PROJECT_DIR"

echo "[dispatch] Starting at \$(date)"
echo "[dispatch] Model: \$DISPATCH_MODEL"
echo "[dispatch] Project: \$DISPATCH_PROJECT_DIR"
echo "[dispatch] Prompt: \$DISPATCH_RUN_DIR/prompt.md"
echo ""

# Write PID
echo \$\$ > "\$DISPATCH_RUN_DIR/dispatch.pid"

# Events file for structured logging
EVENTS_FILE="\$DISPATCH_RUN_DIR/events.log"
touch "\$EVENTS_FILE"

# Files the agent writes to signal completion
DONE_FILE="\$DISPATCH_RUN_DIR/done"
SUMMARY_FILE="\$DISPATCH_RUN_DIR/summary.md"

# Inject event logging + completion instructions into the prompt
EVENTS_ADDENDUM="

EVENTS: When you make a significant finding, take a significant action, or encounter an unexpected result, log it:
echo \"[\\\$(date -Iseconds)] FINDING: <one-line summary>\" >> \$EVENTS_FILE
echo \"[\\\$(date -Iseconds)] ACTION: <what you did>\" >> \$EVENTS_FILE
echo \"[\\\$(date -Iseconds)] ERROR: <what went wrong>\" >> \$EVENTS_FILE
Only log things a human supervisor would want to know about. Skip routine file reads and searches.

WHEN DONE: After completing your task, signal completion by running these commands:
1. Write your summary (using the format from the 'When Done' section above if provided):
   cat > \$SUMMARY_FILE << 'SUMMARY_EOF'
   **Task**: <what was asked>
   **Outcome**: <success/partial/failure>
   **Findings**: <what was discovered>
   **Changes Made**: <files modified>
   **Follow-up**: <anything unresolved>
   SUMMARY_EOF
2. Mark the task as done: echo 0 > \$DONE_FILE
3. Log the completion event: echo \"[\\\$(date -Iseconds)] DISPATCH_DONE: <one-line outcome>\" >> \$EVENTS_FILE

The session will remain open after you signal completion — the user may continue interacting with you."

# Log dispatch start event
echo "[\$(date -Iseconds)] DISPATCH_START: \$(head -1 "\$DISPATCH_RUN_DIR/prompt.md")" >> "\$EVENTS_FILE"

# Start tmux pipe-pane to capture TUI output to raw.log
PANE_ID=\$(tmux display-message -p '#{pane_id}')
tmux pipe-pane -t "\$PANE_ID" "cat >> '\$DISPATCH_RUN_DIR/raw.log'"

# Read the task prompt (user message) and events/completion instructions (system prompt)
TASK_PROMPT="\$(cat "\$DISPATCH_RUN_DIR/prompt.md")"

# Run Claude interactively — this IS the TUI the user sees in the left pane.
# Task goes as positional arg (user message), events/completion as appended system prompt.
# Attach to the tmux session to watch, interact, pause, or redirect.
EXIT_CODE=0
claude --dangerously-skip-permissions \\
  --model "\$DISPATCH_MODEL" \\
  --add-dir "\$DISPATCH_RUN_DIR" \\
  --append-system-prompt "\$EVENTS_ADDENDUM" \\
  "\$TASK_PROMPT" || EXIT_CODE=\$?

# Stop pipe-pane capture
tmux pipe-pane -t "\$PANE_ID" 2>/dev/null || true

# Strip ANSI escape codes from raw capture to produce a searchable log
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b([AB)//g; s/\r//g' \\
  "\$DISPATCH_RUN_DIR/raw.log" > "\$DISPATCH_RUN_DIR/run.log" 2>/dev/null || true

echo ""
echo "[dispatch] TUI exited at \$(date) with code \$EXIT_CODE"

# Safety net: if the agent didn't signal completion, do it now
if [ ! -f "\$DONE_FILE" ]; then
  echo "[\$(date -Iseconds)] DISPATCH_EXIT: TUI exited with code \$EXIT_CODE" >> "\$EVENTS_FILE"
  echo "\$EXIT_CODE" > "\$DONE_FILE"
fi

# Safety net: if no summary was written by the agent, generate one
if [ ! -s "\$SUMMARY_FILE" ]; then
  echo "[dispatch] No summary from agent, generating with haiku..."
  EVENTS_TAIL=""
  if [ -f "\$EVENTS_FILE" ] && [ -s "\$EVENTS_FILE" ]; then
    EVENTS_TAIL=\$(cat "\$EVENTS_FILE")
  fi
  SUMMARY_PROMPT="Summarize this dispatched Claude Code session based on its event log. Use these sections:
- **Task**: what was asked
- **Outcome**: success/partial/failure
- **Findings**: what was discovered
- **Changes Made**: files modified
- **Follow-up**: anything unresolved

Events:
\$EVENTS_TAIL"

  printf '%s' "\$SUMMARY_PROMPT" | claude -p \\
    --dangerously-skip-permissions \\
    --model \$DISPATCH_MODEL \\
    > "\$SUMMARY_FILE" 2>/dev/null

  if [ ! -s "\$SUMMARY_FILE" ]; then
    {
      echo "**Summary generation failed. Events:**"
      echo ""
      cat "\$EVENTS_FILE" 2>/dev/null || echo "(no events)"
    } > "\$SUMMARY_FILE"
    echo "[dispatch] WARNING: Haiku summary failed, wrote events to summary.md"
  else
    echo "[dispatch] Summary generated at \$SUMMARY_FILE"
  fi
fi

# Clean up PID file
rm -f "\$DISPATCH_RUN_DIR/dispatch.pid"
RUNEOF

chmod +x "$RUN_DIR/_run.sh"

# ── create tmux session ──────────────────────────────────────────────────────

# Export env for tmux panes
export DISPATCH_PROJECT_DIR="$PROJECT_DIR"
export DISPATCH_RUN_DIR="$RUN_DIR"
export DISPATCH_MODEL="$MODEL"
export DISPATCH_SESSION="$SESSION_NAME"

# Force a usable size for detached sessions (no client = no inherited size)
tmux set-option -g default-size 200x50 2>/dev/null || true

# Pane 0 (left): Claude runner
tmux new-session -d -s "$SESSION_NAME" -x 200 -y 50 \
  "source '$RUN_DIR/dispatch.env' && bash '$RUN_DIR/_run.sh'; echo ''; echo '--- Dispatch complete. Press enter to close. ---'; read"

# Pane 1 (right): Live status dashboard (optional — don't fail if it can't split)
tmux split-window -h -t "$SESSION_NAME" \
  "source '$RUN_DIR/dispatch.env' && watch -n 5 -t bash '$SCRIPT_DIR/dispatch-status.sh' '$RUN_DIR'" 2>/dev/null || true

# Set pane titles
tmux select-pane -t "$SESSION_NAME:0.0" -T "Claude" 2>/dev/null || true
tmux select-pane -t "$SESSION_NAME:0.1" -T "Status" 2>/dev/null || true
tmux set-option -t "$SESSION_NAME" pane-border-status top 2>/dev/null || true

# Focus on Claude pane
tmux select-pane -t "$SESSION_NAME:0.0" 2>/dev/null || true

# ── print startup info ──────────────────────────────────────────────────────

PROMPT_LINES=$(wc -l < "$RUN_DIR/prompt.md")

echo ""
echo "Dispatch launched in tmux session: $SESSION_NAME"
echo ""
echo "  Run dir:   $RUN_DIR"
echo "  Prompt:    $RUN_DIR/prompt.md ($PROMPT_LINES lines)"
echo "  Model:     $MODEL"
echo "  Log:       $RUN_DIR/run.log"
echo "  Summary:   $RUN_DIR/summary.md (generated on completion)"
echo ""
echo "  tmux:      $SESSION_NAME"
echo "  Attach:    tmux attach -t $SESSION_NAME"
echo "  Detach:    Ctrl-B then D (inside tmux)"
echo "  Kill:      tmux kill-session -t $SESSION_NAME"
echo "  Status:    bash $SCRIPT_DIR/dispatch-status.sh $RUN_DIR"
echo ""

# Attach if interactive
if [ -t 0 ]; then
  tmux attach -t "$SESSION_NAME"
fi