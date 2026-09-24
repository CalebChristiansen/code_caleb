#!/usr/bin/env python3
"""Check every relative link and #anchor in a markdown tree.

    check-links.py [DIR]      default: ./docs

Anchors are computed with GitHub's slug rules, since that is where the tree is
read. External links (http:, mailto:) are skipped. Exit 1 if anything is broken.
"""
import re
import sys
from pathlib import Path

LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
HEADING = re.compile(r"^#{1,6}\s+(.*?)\s*#*\s*$")
FENCE = re.compile(r"^\s*(```|~~~)")


def slug(text):
    text = re.sub(r"`([^`]*)`", r"\1", text)            # inline code keeps its text
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)  # links keep their label
    text = text.strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)                 # GitHub keeps _ and -
    return text.replace(" ", "-")


def lines_outside_fences(path):
    fenced = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if FENCE.match(line):
            fenced = not fenced
            continue
        if not fenced:
            yield line


_anchor_cache = {}


def anchors(path):
    if path not in _anchor_cache:
        seen, out = {}, set()
        for line in lines_outside_fences(path):
            m = HEADING.match(line)
            if not m:
                continue
            s = slug(m.group(1))
            n = seen.get(s, 0)
            seen[s] = n + 1
            out.add(s if n == 0 else f"{s}-{n}")
        _anchor_cache[path] = out
    return _anchor_cache[path]


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "docs")
    if not root.is_dir():
        sys.exit(f"not a directory: {root}")
    broken = 0
    files = sorted(root.rglob("*.md"))
    for md in files:
        for n, line in enumerate(md.read_text(encoding="utf-8").splitlines(), 1):
            for target in LINK.findall(line):
                if re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I):
                    continue
                path_part, _, frag = target.partition("#")
                dest = (md.parent / path_part).resolve() if path_part else md
                problem = None
                if not dest.exists():
                    problem = "missing file"
                elif frag and dest.is_file() and dest.suffix == ".md":
                    if frag.lower() not in anchors(dest):
                        problem = f"no heading for #{frag}"
                if problem:
                    broken += 1
                    print(f"{md}:{n}: {target} — {problem}")
    print(f"{len(files)} files, {broken} broken link(s)")
    sys.exit(1 if broken else 0)


if __name__ == "__main__":
    main()
