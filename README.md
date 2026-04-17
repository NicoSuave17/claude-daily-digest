# claude-daily-digest

A personal robot butler that reads the [Claude Code changelog](https://code.claude.com/docs/en/changelog) every morning, auto-updates your CLI if safe, writes a digest personalized to your workflow, and emails it to you.

Runs entirely on your Mac. No server, no subscription beyond your existing Claude plan. ~2 minutes of work per day, done before you wake up.

Built by [@NicoSuave17](https://github.com/NicoSuave17).

---

## What you'll get

Every morning at ~9am, an email like this lands in your inbox:

```
Subject: Claude Code daily — 2026-04-17 — Opus 4.7 + xhigh, /ultrareview, auto mode GA

VERSION STATUS
Installed (before): 2.1.111
Installed (after):  2.1.112
Upstream latest:    2.1.112
Update action:      ran — 2.1.111 -> 2.1.112

NEW SINCE LAST REVIEW
- 2.1.112 — hotfix for auto mode availability
- 2.1.111 — Opus 4.7 + xhigh effort, /ultrareview, auto mode GA, ...
- 2.1.110 — /tui fullscreen, push notifications, MCP reliability fixes

FEATURES WORTH TRYING TODAY
1. /ultrareview on your next PR. [tailored to your workflow]
2. /effort xhigh for architecture tasks on Opus 4.7.
3. Push notifications for long unattended tasks.
...
```

Personalized to a one-line description of your work that you give during setup.

## Requirements

| | |
|---|---|
| **OS** | macOS (launchd). Apple Silicon or Intel. No Linux/Windows support in v1. |
| **Homebrew** | Required. [brew.sh](https://brew.sh) |
| **Claude Code CLI** | Installed and logged in. [Install guide](https://docs.claude.com/en/docs/claude-code/quickstart) |
| **Claude plan** | Paid plan required (Pro or Max). Each run uses ~20–40k tokens of your daily quota. |
| **Google account** | Gmail or Google Workspace, with **2-Step Verification enabled**. You'll generate a one-time app password scoped to SMTP send. |
| **sudo** | Setup prompts for your Mac password once, to store the Gmail app password in the System keychain (so it's readable even when your Mac is asleep). |

That's it. No other accounts, no API keys, no webhooks.

## Install

```bash
git clone https://github.com/NicoSuave17/claude-daily-digest.git
cd claude-daily-digest
./setup.sh
```

Setup walks you through:

1. Checking prerequisites and installing `msmtp`.
2. Asking for your email.
3. Asking for a one-line description of your work (for prompt personalization).
4. Opening [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords) so you can generate a Gmail app password.
5. Storing that password in the System keychain (sudo prompt here).
6. Writing `~/.msmtprc`, `config.env`, and the launchd plist.
7. Sending a test email to confirm the whole chain works.

Total time: ~3 minutes, most of it spent on the Google app-password page.

## What it sets up on your machine

After setup you'll have:

| File | Purpose |
|---|---|
| `config.env` (in repo dir) | Your email, workflow description, paths. **Contains no secrets** but is gitignored by default. |
| `~/.msmtprc` | SMTP config for Gmail. Mode 0600. No password inside — it's pulled live from keychain. |
| `~/Library/LaunchAgents/com.$USER.claude-daily-digest.plist` | The macOS scheduler entry. |
| System keychain entry `msmtp-claude-daily-digest` | Your Gmail app password, sudo-accessible only. |

Runtime data (logs, digests, sent emails) lives under the repo directory in `logs/`, `emails/`, and dated `.md` files.

## Customizing what Claude writes

Two levels of customization:

**Light:** edit `USER_WORKFLOWS` in `config.env`.
```bash
USER_WORKFLOWS="Backend engineer. Go, Postgres, k8s. Heavy Claude Code user."
```
Every digest's "why it matters" and "features worth trying" sections will key off this.

**Full:** edit `templates/prompt.tpl` directly.
The entire prompt sent to Claude lives there. Change the output format, add sections, remove sections, change the tone — whatever you want. The placeholders like `__TODAY__`, `__EMAIL__`, `__INSTALL_DIR__` get substituted by [bin/daily-review.sh](bin/daily-review.sh) at run time.

## How it works

**Five pieces, each doing one thing.**

1. **launchd** (macOS built-in scheduler) fires [bin/daily-review.sh](bin/daily-review.sh) at 9:03am local time. If your Mac is asleep, it fires on wake.
2. **The shell script** loads `config.env`, renders `templates/prompt.tpl` with today's values, and invokes `claude -p` (headless Claude Code) with the rendered prompt. One automatic retry if the digest isn't produced.
3. **Claude** reads [INDEX.md](INDEX.md) to find the last-reviewed version, WebFetches the changelog, extracts new entries, runs `claude update` if safe, writes a markdown digest, and writes a plain-text `.eml` file.
4. **msmtp** pipes the `.eml` to Gmail SMTP (port 587, TLS). The app password comes from the System keychain — no prompts, no typing.
5. **Log rotation** gzips logs older than 30 days and deletes gzipped logs older than 180.

One `claude -p` call per day. No polling, no background daemons, no cron loops. Total runtime ~2 minutes.

## Why these design choices

**System keychain, not login keychain.** The login keychain locks when you log out or (depending on settings) when your Mac sleeps. System keychain never locks. That's why the 9am email still arrives when your laptop is closed.

**`.eml` file as source of truth.** If SMTP fails, the email still exists on disk. Double-click it in Finder to open as a draft in Mail.app. Three fallback layers: SMTP → local file → retry next day.

**Auto-update is session-safe.** Before running `claude update`, the script checks for any active `claude` processes. If you're mid-session, the update is deferred to the next day. This prevents corrupting a live conversation.

**Exit codes reflect reality.** If no digest was produced, the script exits 1 so `launchctl print` records the failure. Silent success is the worst kind of bug.

## Daily operations

```bash
# Trigger a run right now (don't wait for 9am)
launchctl kickstart -k gui/$(id -u)/com.$USER.claude-daily-digest

# Check last exit + next fire time
launchctl print gui/$(id -u)/com.$USER.claude-daily-digest

# Tail today's log
tail -f logs/"$(date +%Y-%m-%d)".log

# See past digests
ls -lt *.md

# See SMTP history
tail logs/msmtp.log
```

## Troubleshooting

**No email arrived.** Check today's log (`logs/YYYY-MM-DD.log`) and the msmtp log (`logs/msmtp.log`). Common causes:

- Gmail app password revoked → regenerate and update the keychain (see below).
- Claude CLI needs re-authentication → run `claude` interactively once.
- Network down at 9am → next day's run will catch up.

**Rotating the Gmail app password.**
```bash
sudo security delete-generic-password -s msmtp-claude-daily-digest /Library/Keychains/System.keychain
sudo security add-generic-password \
    -a your@email.com \
    -s msmtp-claude-daily-digest \
    -w \
    /Library/Keychains/System.keychain
```
The `-w` with no value prompts interactively — nothing hits shell history.

**"claude --version failed" during setup.** Run `claude` interactively once to complete OAuth login, then re-run `setup.sh`.

**Costs too many tokens.** Drop `CLAUDE_EFFORT` from `xhigh` to `high` or `medium` in `config.env`.

**Claude is ignoring my `USER_WORKFLOWS`.** Edit `templates/prompt.tpl` directly — make the workflow emphasis more prominent, or add explicit instructions.

## Uninstall

```bash
./uninstall.sh
```

Interactive — asks before removing `~/.msmtprc`, the keychain entry, and your data.

## What this does NOT do

- Does not send alerts if a run fails (check `launchctl print` manually, or add a hook).
- Does not retry across days — a missed day is a missed day.
- Does not support non-Gmail SMTP out of the box (you can edit `~/.msmtprc` for any SMTP provider).
- Does not work on Linux or Windows.
- Does not handle Claude Code CLI path changes — update `CLAUDE_BIN` in `config.env` if you change Homebrew prefix.

## License

MIT. See [LICENSE](LICENSE).
