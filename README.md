# /security-audit

> ## ⚠️ Before you start
>
> Your AI agent can install this skill (copy into `~/.claude/skills/security-audit/`, then restart Claude Code to load it). A few things need **you** or your environment:
>
> - Nothing to grant — it's **read-only** and never changes anything. Optionally copy `scripts/audit-redact-secrets.sh` into `~/.claude/scripts/` if you want the redaction helper.


> Comprehensive, read-only security scan for your macOS dev system — with a baseline diff so every run tells you what's *new*.

## What it does

`/security-audit` runs a thorough, hands-off security sweep of your Mac developer environment and writes you a plain-English report. It hunts for leaked secrets in your Claude Code transcripts and project files (API keys, tokens, private keys, DB URLs with credentials), checks system hygiene (macOS updates, FileVault, Time Machine, listening ports, outdated Homebrew/npm packages), inventories LaunchAgents and SSH keys, and flags git repos with uncommitted or stale work.

The first run establishes a baseline. Every run after that diffs against it, so the report leads with the one section that matters most on a weekly cadence: **what changed since last time** — new secrets, new LaunchAgents, new listening ports, newly outdated packages.

It is **strictly read-only**. It never rotates a key, never edits a file, never auto-redacts anything. It surfaces findings, ranks them by urgency, and lets *you* decide. Part of [vibekit](https://ritual.industries) — a showcase of small tools and Claude Code skills that make coding with AI better.

## Install

This skill is a single folder. Drop it into your Claude Code skills directory so that `~/.claude/skills/security-audit/SKILL.md` exists.

```bash
# Clone the repo
git clone https://github.com/brianharms/skill-security-audit.git

# Copy the skill into place
mkdir -p ~/.claude/skills
cp -R skill-security-audit ~/.claude/skills/security-audit
```

(Or download the ZIP from GitHub and copy the folder in manually — same destination.)

### Companion redaction script (optional but recommended)

The skill ships a bundled helper at `scripts/audit-redact-secrets.sh`. The audit itself **never runs it** — redaction can corrupt active session files, so it's a deliberate, manual, after-the-fact tool. To have it available when you decide to clean up dead/rotated secrets:

```bash
mkdir -p ~/.claude/scripts
cp ~/.claude/skills/security-audit/scripts/audit-redact-secrets.sh ~/.claude/scripts/
```

You run it yourself, only after quitting every Claude Code window:

```bash
# Preview what would change
bash ~/.claude/scripts/audit-redact-secrets.sh --dry-run

# Apply
bash ~/.claude/scripts/audit-redact-secrets.sh
```

### Adjust the scan scope (important)

The skill ships with paths tuned to one machine. **Before your first run, point it at where *you* keep things.** Open `~/.claude/skills/security-audit/SKILL.md` and edit the scan roots:

- Project scan (Agents B & C, Phase 3) defaults to `~/Desktop/Claude Projects/*` — change this to wherever your code lives (e.g. `~/dev/*`, `~/repos/*`).
- Transcript scan (Agent A) uses `~/.claude/training-data/` and `~/.claude/projects/` — these are standard Claude Code locations and usually correct as-is.

Once installed, just type `/security-audit` in Claude Code to run it.

## Usage

In any Claude Code session:

```
/security-audit
```

Claude tells you it's starting ("this takes 3–5 minutes"), spawns three parallel scan agents, runs the direct system checks, computes deltas against your baseline, and writes a timestamped report to `~/.claude/security-audit/reports/YYYY-MM-DD-HHMM.md`. It finishes with a tight chat summary: risk level, your top 3 action items, and a count of what's new since last run.

Natural-language triggers work too:

```
weekly security scan
audit my system
check for leaked secrets
```

The report ends with a **manual checklist** for the things a script genuinely can't verify — reviewing active API keys in the Anthropic/GitHub/Stripe consoles, checking 3rd-party Google access, scanning Gmail forwarding rules, and so on. Run it weekly and give yourself ten minutes for that part.

## Requirements / Dependencies

- **macOS only.** The audit leans on `softwareupdate`, `fdesetup`, `tmutil`, `launchctl`, `lsof`, and `~/Library/LaunchAgents` — these are macOS-specific.
- **Claude Code CLI** with skills support (`~/.claude/skills/`). The skill orchestrates subagents and uses Grep/Bash/Read tools — no external MCP server required.
- **Optional command-line tools** that some checks use if present (gracefully skipped if not): [Homebrew](https://brew.sh) (`brew outdated`), `npm` (global package check), `ssh-keygen` (ships with macOS), `git` (project hygiene), `python3` (only for the companion redaction script).

No sibling skills are required.

## For AI coding agents

This section is for an agent working **on** this skill.

### Repo layout

```
skill-security-audit/
├── SKILL.md                          # the skill itself — the contract Claude reads
├── scripts/
│   └── audit-redact-secrets.sh       # bundled companion; manual-only, NOT run by the skill
├── LICENSE                           # MIT
├── .gitignore
└── README.md
```

There is no `web/`, `swift/`, or `template.html` — this skill produces a Markdown report, not an HTML artifact.

### What SKILL.md is

`SKILL.md` is the entire skill. The YAML frontmatter (`name`, `description`) is what Claude Code uses for discovery and triggering — the `description` is what decides whether `/security-audit` and its natural-language phrases fire, so edit it carefully. The body is a 7-phase procedure Claude executes: spawn 3 parallel scan agents → direct system checks → git hygiene → compute deltas → write report → update baseline → summarize. There is no compiled code path; the prose *is* the program.

### How to test changes

1. Copy your edited folder into place: `cp -R . ~/.claude/skills/security-audit`.
2. Start Claude Code and invoke `/security-audit`.
3. Confirm a report lands in `~/.claude/security-audit/reports/` and a `~/.claude/security-audit/baseline.json` is written/updated.
4. Run twice: the **first** run establishes the baseline, the **second** must populate the "What's new since last run" section by diffing against it. Both behaviors need to work.

### Invariants — do not break these

- **Read-only is the whole contract.** The audit must never rotate, redact, delete, or modify anything it scans. The only writes it makes are the report file and `baseline.json`. If you add a check, it stays read-only.
- **The redaction script is never invoked by the skill.** `scripts/audit-redact-secrets.sh` is documented as copy-to-`~/.claude/scripts/`-and-run-manually only, because it can corrupt active session files. Keep that separation. If you keep its destructive sweep, keep its `--dry-run` mode and its running-process safety check.
- **Baseline diff is the point.** Preserve the `baseline.json` shape (`last_run`, `secrets_in_transcripts`, `launch_agents`, `listening_ports`, `homebrew_outdated`, `npm_outdated`) and the first-run-establishes / subsequent-runs-diff logic. The weekly value is the delta, not the snapshot.
- **Secrets stay masked.** Reported secrets are deduplicated and middle-masked; baseline stores masked forms only. Never write a full live secret into a report or the baseline.
- **Keep false-positive guidance intact.** The skill explicitly calls out known false positives (Chrome's `anonymous_feedback_submit_api_key`, base64/protobuf binary noise, the regex pattern strings themselves echoing in audit prompts, `[REDACTED_BY_AUDIT_*]` markers). Don't strip these — they prevent noisy, alarming reports.
- **Scope paths are user-configurable.** The default roots (`~/Desktop/Claude Projects/*`, `~/.claude/training-data/`, `~/.claude/projects/`) are examples. Keep them `~/`-relative and keep the README's "adjust the scope" guidance accurate to whatever the SKILL.md actually uses.

## License

MIT © 2026 Brian Harms / Ritual Industries. See [LICENSE](LICENSE).
