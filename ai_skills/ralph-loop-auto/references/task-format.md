# Task Queue Format

`tasks.json` is an ordered array stored in the run directory. If placed in the project directory, the launch script copies it to the run dir automatically. Tasks run in order; completed tasks are skipped on restart.

```json
[
  {
    "id": "unique-slug",
    "name": "Human-readable task name",
    "prompt": "Full instructions for Claude Code. Be specific — each task runs in a fresh session with no memory of prior tasks. Include paths, env vars, and expected state.",
    "test": "bash command that exits 0 on success. Use grep -q, python assertions, curl checks, etc.",
    "retries": 2,
    "priority": "P0"
  }
]
```

## Fields

| Field | Required | Description |
|-------|----------|-------------|
| `id` | yes | Unique slug. Used for `.done`, `.skip`, `.escalate`, `.running` marker files |
| `name` | yes | Short name shown in logs and status output |
| `prompt` | yes | Full prompt sent to `claude -p`. Include everything — the session has zero prior context |
| `test` | yes | Verification command. Empty string = always pass |
| `retries` | no | Extra attempts beyond the first (default: 2, so 3 total) |
| `priority` | no | Informational. `P0` = must ship, `P1` = should, `P2` = nice-to-have |

## Prompt Tips

- Include the working directory and any relevant env setup
- Reference specific file paths — Claude Code can't discover them
- End with "run this test to verify" so Claude self-checks
- Include build/test commands relevant to the project's build system
- Note that CLAUDE.md exists at repo root with project conventions, if present
- For tasks building on prior tasks: describe the expected state, don't assume memory

## Test Tips

- `python3 -c "assert ...; print('PASS')"` for programmatic checks
- `grep -q 'pattern' file` for file content checks  
- `curl -s http://... | grep -q 'expected'` for web endpoints
- `test -f path/to/file` for existence checks
- Chain with `&&` for multi-condition: `test -f app.py && curl -s localhost:5000/health | grep -q ok`
- `bazel build //path/to:target` for build verification
- `bazel test //path/to:test_target` for bazel test targets

## Design Decisions

The runner automatically instructs each task session to log notable design decisions, plan deviations, and alternative choices to a shared `decisions.md` file. These are rolled up into the final `summary.md` under "Design Decisions & Plan Changes". No action needed in task prompts — this is handled by the runner.

## Commits

The runner automatically instructs each task session to commit its changes with a descriptive message after the test passes. No need for explicit "commit" tasks — each task is checkpointed in git automatically. A silent fallback commit runs if the agent forgets.

## Task Ordering

1. **Core functionality** — build, test, verify
2. **Integration tests** — end-to-end verification
3. **Lint & formatting** — fix style issues
4. **Nice-to-haves** — extra features, polish
5. **Final push** — push to remote (always last)
