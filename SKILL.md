---
name: security-audit
description: Run a comprehensive security audit on your macOS dev system. Use when the user says "/security-audit", "weekly security scan", "audit my system", "check for leaked secrets", or wants a system-wide security check. Produces a structured report at ~/.claude/security-audit/reports/ and diffs against the previous run's baseline. NEVER auto-rotates or auto-redacts — surfaces findings and lets the user decide.
---

# Security Audit

Run a comprehensive security audit on the user's macOS dev system. Cover everything that can be checked autonomously without requiring the user to log into external dashboards. The audit is **read-only** — present findings, do not auto-fix.

## Before you start

1. Verify the state directories exist:
   - `~/.claude/security-audit/` — baseline + scratch
   - `~/.claude/security-audit/reports/` — dated reports
   Create them if missing.

2. Check `~/.claude/security-audit/baseline.json` — if it exists, this is a delta run. If not, this is the first run and will establish the baseline.

3. Generate today's report path: `~/.claude/security-audit/reports/YYYY-MM-DD-HHMM.md` (use real local time).

4. Tell the user one sentence: "Running security audit — this takes 3-5 minutes. I'll spawn parallel scans and report findings."

## Phase 1 — Spawn parallel scan agents (in ONE message, multiple Agent calls)

Dispatch THREE subagents in parallel. Each gets a self-contained prompt and reports back a structured finding list. Use `general-purpose` subagent type with `run_in_background: false` (we need their results before phase 2).

### Agent A — Transcript secret scan

Scope: `~/.claude/training-data/` and `~/.claude/projects/`

Patterns to scan (use Grep tool with output_mode "count" first, then "content" for samples):
- `sk-ant-api03-[A-Za-z0-9_-]{40,}` — Anthropic API keys
- `sk-(proj-)?[a-zA-Z0-9_-]{20,}` — OpenAI keys (exclude `sk-ant`)
- `AKIA[0-9A-Z]{16}` — AWS access keys
- `AIza[0-9A-Za-z_-]{35}` — Google API keys (NOTE: Chrome internal `anonymous_feedback_submit_api_key` annotations are FALSE POSITIVES — they're Google's own keys baked into Chrome, not user secrets)
- `gh[pousr]_[A-Za-z0-9]{36,}` — GitHub tokens
- `xox[baprs]-[A-Za-z0-9-]{10,}` — Slack tokens
- `sk_live_[A-Za-z0-9]{24,}` — Stripe live keys
- `-----BEGIN (RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----` — PEM private keys
- `(?i)password\s*[=:]\s*['"][^'"]{6,}['"]` — password assignments
- `(postgres|mysql|mongodb)(\+srv)?://[^:]+:[^@]+@` — DB URLs with creds
- `eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}` — JWT tokens (heavy false positive rate from binary base64; verify in context)

Distinguish real leaks from:
- Pattern echoes (the regex strings themselves appearing in audit prompts)
- Already-redacted content with `[REDACTED_BY_AUDIT_*]` markers
- Chrome internal API keys in `anonymous_feedback_submit_api_key=` annotations
- Base64/protobuf binary content matching key prefixes by chance

Return: list of distinct secrets (deduplicated, masked middle), file count per secret, verdict per category, prioritized rotation list. Under 800 words.

### Agent B — Project filesystem secret scan

Scope: `~/Desktop/Claude Projects/*`

Check for:
- **Hardcoded keys in source files**: scan `.js`, `.ts`, `.mjs`, `.py`, `.sh`, `.json`, `.yaml`, `.yml`, `.toml` for the same patterns as Agent A. Skip `node_modules`, `.venv`, `.git`, `dist`, `build`, `__pycache__`, `site-packages`.
- **`.env` files in git**: for each project that's a git repo, run `git ls-files .env .env.* 2>/dev/null` and `git log --all --full-history --oneline -- .env .env.* 2>/dev/null` to detect committed-and-removed `.env` files.
- **`.env*` files NOT in `.gitignore`**: list any `.env*` file whose project doesn't gitignore it.
- **Plaintext keys in config files**: `package.json`, `wrangler.toml`, `vercel.json`, `firebase.json`, etc.
- **Suspicious world-readable secret files**: any file matching `*.env`, `*credentials*`, `*secret*`, `*.pem`, `*.key` with permissions broader than 600.

Return: list of findings grouped by project, with file paths and verdict (LIKELY LEAK / NEEDS REVIEW / FALSE POSITIVE). Under 800 words.

### Agent C — System config + LaunchAgent scan

Scope: shell rc files, Claude/config dirs, `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`

Check for:
- **Plaintext keys in shell rc files**: `~/.zshrc`, `~/.zprofile`, `~/.zshenv`, `~/.bashrc`, `~/.bash_profile`, `~/.profile`. Look for `export.*=("|')[A-Za-z0-9_-]{20,}` patterns where the variable name suggests a secret (`*KEY*`, `*TOKEN*`, `*SECRET*`).
- **Plaintext keys in Claude config**: `~/.claude/config.json`, `~/.claude/settings.json`, `~/.claude/.credentials.json`. Scan for `*api_key*`, `*token*`, `*secret*` JSON keys with non-empty string values.
- **`~/.secrets/` permissions**: verify directory is `700`, files inside are `600`. Flag anything looser.
- **LaunchAgent inventory**: list all `.plist` files in `~/Library/LaunchAgents/`, `/Library/LaunchAgents/`, `/Library/LaunchDaemons/`. For each, capture filename + Label (from `defaults read`) + Program/ProgramArguments. Compare against `~/.claude/security-audit/baseline.json` `launch_agents` field — flag NEW entries since last run.
- **SSH key inventory**: `ls -la ~/.ssh/`, identify key files (no `.pub` suffix) and check whether they have passphrases (run `ssh-keygen -y -P "" -f <key>` — if it succeeds, key has no passphrase). Flag passwordless keys.
- **macOS env via launchctl**: `launchctl getenv ANTHROPIC_API_KEY` and other common secret-shaped env vars — if set, flag with masked prefix.

Return: structured findings + LaunchAgent diff vs baseline. Under 800 words.

## Phase 2 — Direct system checks (parallel Bash calls in one message)

Run these as parallel Bash calls. They're cheap and don't need a subagent:

```bash
# 1. macOS update check
softwareupdate -l 2>&1 | tail -20

# 2. FileVault status
fdesetup status

# 3. Disk space on root
df -h / | tail -1

# 4. Time Machine last backup
tmutil latestbackup 2>&1 | head -3

# 5. Listening ports (TCP)
lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1, $9}' | sort -u

# 6. Brew outdated
brew outdated 2>/dev/null | head -30

# 7. npm global outdated
npm outdated -g --depth=0 2>/dev/null | head -20

# 8. Suspicious process: anything with ~/.secrets or ~/.ssh open
lsof 2>/dev/null | grep -E "/\.(ssh|secrets|aws)/" | awk '{print $1, $2, $9}' | sort -u

# 9. Recently modified files in sensitive dirs
find ~/.ssh ~/.secrets ~/.aws ~/.config -type f -mtime -7 2>/dev/null | head

# 10. World-readable secret-shaped files in $HOME (excluding common false positives)
find ~ -maxdepth 3 -type f \( -name '*.env' -o -name '*.pem' -o -name '*.key' -o -name 'credentials*' \) \! -perm 600 \! -path '*/node_modules/*' \! -path '*/.venv/*' \! -path '*/.git/*' 2>/dev/null | head
```

Capture each output. Don't print raw output to user — summarize in the report.

## Phase 3 — Git hygiene check (Bash + per-project)

For each project in `~/Desktop/Claude Projects/`:
- `git status --porcelain` — uncommitted changes that could be lost
- `git stash list` — stashed work that might be forgotten
- `git log --oneline -1` — last commit time (flag projects untouched > 90 days as candidates for archival)

Don't dump everything — just count categories and flag outliers.

## Phase 4 — Compute deltas vs baseline

Read `~/.claude/security-audit/baseline.json`. Compare:
- `secrets_in_transcripts`: find any new keys not in last baseline
- `launch_agents`: find new entries
- `listening_ports`: find new entries
- `homebrew_versions`: find newly outdated packages

If no baseline exists, this run BECOMES the baseline.

## Phase 5 — Write report

Write `~/.claude/security-audit/reports/YYYY-MM-DD-HHMM.md`:

```markdown
# Security Audit — YYYY-MM-DD HH:MM

## Summary
- **Risk level**: LOW | MEDIUM | HIGH
- **New since last audit**: N findings
- **Critical actions**: N
- **Last audit**: <date or "first run">

## 🚨 Critical (rotate/fix now)
[Anything that needs immediate action — live secrets in plaintext, compromised keys, public exposure]

## ⚠️ Needs review
[Things worth attention but not on fire — outdated software, passwordless SSH keys, untouched stale projects, NEW LaunchAgents]

## ✅ Clean / no change
[Categories that came back clean — keep this short, just one line per category]

## What's new since last run
[Bullet list of NEW items not in last baseline — most important section for weekly cadence]

## System health
- macOS updates: <count or "current">
- FileVault: <status>
- Time Machine: <last backup time>
- Disk space: <% used>
- Brew packages outdated: N
- npm globals outdated: N

## Project hygiene
- Total projects: N
- Stale (>90 days untouched): N (list)
- With uncommitted changes: N (list)
- Without git: N (list)

## Manual checklist (Tier 2 — do these in your browser)
The script can't check these — give yourself 10 min weekly:
- [ ] Anthropic console → active API keys, last-used
- [ ] GitHub → Settings → Developer settings → PATs + OAuth apps
- [ ] Google Account → Security → 3rd-party access
- [ ] 1Password / Bitwarden → Watchtower / security report
- [ ] Stripe / Cloudflare / Vercel / etc → API keys
- [ ] Browser → review installed extensions
- [ ] Gmail → Settings → Forwarding (no rogue forwards?)
```

## Phase 6 — Update baseline

Write a fresh `~/.claude/security-audit/baseline.json` with current state snapshot:

```json
{
  "last_run": "ISO timestamp",
  "secrets_in_transcripts": ["masked_key_1", "masked_key_2"],
  "launch_agents": ["filename1.plist", "filename2.plist"],
  "listening_ports": ["proc:port", ...],
  "homebrew_outdated": [...],
  "npm_outdated": [...]
}
```

## Phase 7 — Tell the user

In chat (≤150 words):
1. Report path
2. Risk level + 1-line summary
3. Top 3 action items (most urgent)
4. Count of changes since last run
5. Reminder that the manual checklist still needs human attention

Then stop. Do not auto-fix. Do not start rotating keys unless the user explicitly asks.

## Notes for future runs

- The redaction script lives at `the bundled `scripts/audit-redact-secrets.sh` (copy it to ~/.claude/scripts/ first)` — never run it from inside this skill (it can corrupt active session files)
- If a finding looks like a known false positive (Chrome `anonymous_feedback_submit_api_key`, base64 binary noise), say so explicitly in the report
- Keep findings in plain language, not raw diffs — they should be readable by a non-engineer
- Keep the final chat summary tight; put detail in the report file
