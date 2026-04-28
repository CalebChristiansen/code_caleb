#!/usr/bin/env python3
"""Convert claude -p --output-format stream-json output to a human-readable log.

Reads stream-json lines from stdin (or a file argument) and writes a readable
transcript to stdout showing tool calls, results, and assistant responses.
"""

import json
import sys


def truncate(text: str, max_lines: int = 30) -> str:
    lines = text.split('\n')
    if len(lines) <= max_lines:
        return text
    return '\n'.join(lines[:max_lines]) + f'\n  ... ({len(lines) - max_lines} more lines)'


def format_tool_input(name: str, inp: dict) -> str:
    if name == 'Bash':
        cmd = inp.get('command', '')
        desc = inp.get('description', '')
        prefix = f'  # {desc}\n' if desc else ''
        return f'{prefix}  $ {cmd}'
    elif name == 'Read':
        path = inp.get('file_path', '')
        offset = inp.get('offset', '')
        limit = inp.get('limit', '')
        extra = ''
        if offset:
            extra += f' (offset={offset}'
            if limit:
                extra += f', limit={limit}'
            extra += ')'
        elif limit:
            extra += f' (limit={limit})'
        return f'  {path}{extra}'
    elif name in ('Edit', 'Write'):
        return f'  {inp.get("file_path", "")}'
    elif name == 'Grep':
        pattern = inp.get('pattern', '')
        path = inp.get('path', '.')
        return f'  /{pattern}/ in {path}'
    elif name == 'Glob':
        return f'  {inp.get("pattern", "")}'
    else:
        # Generic: show keys
        parts = []
        for k, v in inp.items():
            sv = str(v)
            if len(sv) > 80:
                sv = sv[:77] + '...'
            parts.append(f'  {k}: {sv}')
        return '\n'.join(parts)


def main() -> None:
    if len(sys.argv) > 1:
        source = open(sys.argv[1])
    else:
        source = sys.stdin

    for line in source:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue

        etype = event.get('type', '')

        if etype == 'system' and event.get('subtype') == 'init':
            model = event.get('model', 'unknown')
            cwd = event.get('cwd', '')
            print(f'=== Session started (model: {model}, cwd: {cwd}) ===\n')

        elif etype == 'assistant':
            msg = event.get('message', {})
            for block in msg.get('content', []):
                if block.get('type') == 'text':
                    text = block.get('text', '')
                    if text.strip():
                        print(f'Claude: {text}\n')
                elif block.get('type') == 'tool_use':
                    name = block.get('name', '?')
                    inp = block.get('input', {})
                    print(f'[{name}]')
                    print(format_tool_input(name, inp))
                    print()

        elif etype == 'user':
            msg = event.get('message', {})
            for block in msg.get('content', []):
                if block.get('type') == 'tool_result':
                    content = block.get('content', '')
                    is_error = block.get('is_error', False)
                    if isinstance(content, list):
                        content = '\n'.join(
                            c.get('text', '') for c in content if c.get('type') == 'text'
                        )
                    if content:
                        prefix = 'ERROR: ' if is_error else ''
                        print(f'  {prefix}{truncate(content)}\n')

        elif etype == 'result':
            subtype = event.get('subtype', '')
            duration = event.get('duration_ms', 0)
            cost = event.get('total_cost_usd', 0)
            turns = event.get('num_turns', 0)
            minutes = duration / 60000
            print(f'=== Done ({subtype}) — {turns} turns, {minutes:.1f}m, ${cost:.4f} ===')

    if source is not sys.stdin:
        source.close()


if __name__ == '__main__':
    main()
