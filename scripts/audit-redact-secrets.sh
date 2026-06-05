#!/bin/bash
# audit-redact-secrets.sh
#
# One-shot redaction sweep for dead/rotated secrets in Claude Code transcripts.
# Created during the 2026-04-11 security audit.
#
# Run this AFTER closing all Claude Code windows so no transcript files are
# being actively written. It does an unconditional sweep (no skip threshold).
#
# What it redacts:
#   - Any sk-ant-api03-* Anthropic API key
#   - The dead Fish Audio key (prefix f6a39c... suffix c722)
#   - The dead Deepgram key (full literal)
#   - PEM private key blocks (-----BEGIN PRIVATE KEY----- ...)
#
# It will NOT touch:
#   - Files outside ~/.claude/training-data and ~/.claude/projects
#   - Already-redacted markers
#
# Usage:
#   1. Quit all Claude Code windows
#   2. Run: bash ~/.claude/scripts/audit-redact-secrets.sh
#   3. Optionally pass --dry-run to preview without writing

set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# Safety: warn if any claude processes are running
if pgrep -fil "claude " >/dev/null 2>&1; then
  echo "⚠️  Claude Code processes appear to be running. Active session files"
  echo "    may be written to mid-redaction and corrupted."
  echo ""
  pgrep -fil "claude " || true
  echo ""
  read -r -p "Continue anyway? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

python3 - "$DRY_RUN" << 'PY'
import os, re, sys, json, time
from pathlib import Path

dry_run = bool(int(sys.argv[1]))

patterns = [
    (re.compile(r"sk-ant-api03-[A-Za-z0-9_\-]{40,}"), "ANTHROPIC"),
    (re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----[^\"]*"), "PRIVKEY"),
    (re.compile(r"\bf6a39c[a-f0-9]{22}c722\b", re.I), "FISH"),
    (re.compile(r"\b3c2e7957c428b291ad73cdb66d3b2cf260833438\b"), "DEEPGRAM"),
]
MARKER = "[REDACTED_BY_AUDIT_2026-04-11]"

roots = [
    Path.home() / ".claude" / "training-data",
    Path.home() / ".claude" / "projects",
]

stats = {"scanned": 0, "modified": 0, "redactions_total": 0, "by_pattern": {}}
modified_files = []

for root in roots:
    if not root.exists(): continue
    for f in root.rglob("*.jsonl"):
        stats["scanned"] += 1
        try:
            content = f.read_text(encoding="utf-8", errors="replace")
        except Exception:
            continue
        new_content = content
        file_redactions = 0
        for regex, name in patterns:
            new_content, n = regex.subn(MARKER, new_content)
            if n > 0:
                file_redactions += n
                stats["by_pattern"][name] = stats["by_pattern"].get(name, 0) + n
        if file_redactions > 0:
            if not dry_run:
                f.write_text(new_content, encoding="utf-8")
            stats["modified"] += 1
            stats["redactions_total"] += file_redactions
            modified_files.append((f.name, file_redactions))

mode = "DRY RUN" if dry_run else "APPLIED"
print(f"=== AUDIT SWEEP — {mode} ===")
print(json.dumps(stats, indent=2))
if modified_files:
    print(f"\n=== FILES {'WOULD BE' if dry_run else ''} MODIFIED ===")
    for n, c in sorted(modified_files, key=lambda x: -x[1]):
        print(f"  {c:4d} redactions: {n}")
else:
    print("\nNothing to redact — all clean.")
PY
