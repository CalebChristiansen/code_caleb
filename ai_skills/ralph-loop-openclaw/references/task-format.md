# Task Queue Format

`tasks.json` is an ordered array. Tasks run in order; completed tasks are skipped on restart.

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
| `name` | yes | Short name shown in logs and Discord updates |
| `prompt` | yes | Full prompt sent to `claude --print`. Include everything — the session has zero prior context |
| `test` | yes | Verification command. Empty string = always pass |
| `retries` | no | Extra attempts beyond the first (default: 2, so 3 total) |
| `priority` | no | Informational. `P0` = must ship, `P1` = should, `P2` = nice-to-have |

## Prompt Tips

- Include the working directory, venv path, env file location
- Reference specific file paths — Claude Code can't discover them
- End with "run this test to verify" so Claude self-checks
- For tasks that post to APIs: include auth patterns (Bitwarden lookup, .env vars)
- For tasks building on prior tasks: describe the expected state, don't assume memory

## Test Tips

- `python3 -c "assert ...; print('PASS')"` for programmatic checks
- `grep -q 'pattern' file` for file content checks  
- `curl -s http://... | grep -q 'expected'` for web endpoints
- `test -f path/to/file` for existence checks
- Chain with `&&` for multi-condition: `test -f app.py && curl -s localhost:5000/health | grep -q ok`

## Task Ordering

1. **Commit existing work** first (safety net)
2. **Core functionality** — build, test, verify
3. **Integration tests** — end-to-end verification
4. **Documentation** — README, configs
5. **Done commit** — "DONE" tagged commit and push
6. **Nice-to-haves** — extra features, polish
7. **Final push** — always last
