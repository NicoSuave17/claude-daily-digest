#!/bin/bash
# claude-daily-digest — Daily Claude Code changelog review + email.
# Invoked by launchd at ~9am daily (or on wake if that slot was missed).
#
# Flow:
#   1. Load config.env for user-specific settings.
#   2. Check if any claude process is running. If yes, skip auto-update.
#   3. Read installed version.
#   4. Render prompt template with today's values.
#   5. Invoke `claude -p` with the rendered prompt. One retry on failure.
#   6. If a .eml file was produced, pipe it to msmtp to send via Gmail SMTP.
#   7. Rotate old logs.
#
# Environment assumptions (set up by setup.sh):
#   - Config at INSTALL_DIR/config.env
#   - Prompt template at INSTALL_DIR/templates/prompt.tpl
#   - Gmail app password in System keychain under $KEYCHAIN_SERVICE
#   - ~/.msmtprc pointing at that keychain entry

set -u
# Note: not using `set -e` — we want to continue through failures and report them.

# ---- STEP 0: Locate and load config ----
# The script's own directory resolves to INSTALL_DIR/bin. Config is one up.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$INSTALL_DIR/config.env"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found at $CONFIG_FILE"
    echo "ERROR: Did you run setup.sh?"
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Required vars (set in config.env).
: "${EMAIL:?config.env missing EMAIL}"
: "${INSTALL_DIR:?config.env missing INSTALL_DIR}"
: "${CLAUDE_BIN:?config.env missing CLAUDE_BIN}"
: "${CLAUDE_MODEL:=claude-opus-4-7}"
: "${CLAUDE_EFFORT:=xhigh}"

LOG_DIR="$INSTALL_DIR/logs"
EMAILS_DIR="$INSTALL_DIR/emails"
INDEX_FILE="$INSTALL_DIR/INDEX.md"
PROMPT_TPL="$INSTALL_DIR/templates/prompt.tpl"
TODAY="$(date +%Y-%m-%d)"
LOG_FILE="$LOG_DIR/$TODAY.log"

mkdir -p "$LOG_DIR" "$EMAILS_DIR"

# Redirect all output to today's log while also printing to stdout (launchd captures it too).
exec > >(tee -a "$LOG_FILE") 2>&1

# ---- Failure alerting helper ----
# Called before every `exit 1` site. Delivers a macOS notification AND a
# fallback email (via the same msmtp path that has proven 100% reliable).
# The email includes the last 40 lines of today's log so the user can
# triage without opening Terminal. Silent fails (like 2026-04-16 and
# 2026-04-19) happened because this helper didn't exist.
#
# Args:
#   $1 — short summary (max ~60 chars, used for notification title + email subject suffix)
alert_failure() {
    local summary="${1:-Daily digest failed}"
    # macOS notification. Non-fatal if osascript is unavailable or blocked.
    /usr/bin/osascript -e "display notification \"${summary}. Check logs/${TODAY}.log\" with title \"Claude daily digest failed\" sound name \"Basso\"" 2>/dev/null || true

    # Fallback email via msmtp. Reuses the same account as successful sends.
    if command -v msmtp >/dev/null 2>&1 && [ -n "${EMAIL:-}" ]; then
        local ALERT_EML
        ALERT_EML="$(mktemp -t claude-digest-alert.XXXXXX)"
        {
            printf 'To: %s\n' "$EMAIL"
            printf 'From: Claude Changelog Daemon <%s>\n' "$EMAIL"
            printf 'Subject: [FAIL] Claude daily digest — %s — %s\n' "$TODAY" "$summary"
            printf 'Date: %s\n' "$(date -R 2>/dev/null || date "+%a, %d %b %Y %H:%M:%S %z")"
            printf 'MIME-Version: 1.0\n'
            printf 'Content-Type: text/plain; charset=utf-8\n'
            printf '\n'
            printf 'The daily digest job failed. Summary: %s\n\n' "$summary"
            printf 'Last 40 lines of the run log (%s):\n' "$LOG_FILE"
            printf -- '----------------------------------------\n'
            tail -40 "$LOG_FILE" 2>/dev/null || echo "(no log available)"
            printf -- '----------------------------------------\n'
            printf '\nInstall: %s\n' "${INSTALL_DIR:-unknown}"
            printf 'LaunchAgent: %s\n' "${LAUNCHD_LABEL:-unknown}"
        } > "$ALERT_EML"
        msmtp -a gmail -t < "$ALERT_EML" 2>&1 || echo "WARNING: alert email send failed"
        rm -f "$ALERT_EML"
    fi
}

echo "========================================"
echo "Daily changelog review starting: $(date)"
echo "========================================"
echo "INFO: INSTALL_DIR=$INSTALL_DIR"
echo "INFO: EMAIL=$EMAIL"

if [ ! -x "$CLAUDE_BIN" ]; then
    echo "ERROR: claude CLI not executable at $CLAUDE_BIN"
    echo "ERROR: Update CLAUDE_BIN in $CONFIG_FILE or reinstall Claude Code CLI."
    alert_failure "claude CLI missing at $CLAUDE_BIN"
    exit 1
fi

if [ ! -f "$PROMPT_TPL" ]; then
    echo "ERROR: Prompt template not found at $PROMPT_TPL"
    echo "ERROR: Your install appears incomplete."
    alert_failure "prompt template missing — install broken"
    exit 1
fi

# ---- STEP 1: Detect running claude sessions ----
# If any interactive/VS Code Claude session is running, skip auto-update to
# avoid corrupting its state.
CLAUDE_PROCS=$(pgrep -a -f "claude" 2>/dev/null | \
    grep -v "daily-review.sh" | \
    grep -v "grep" | \
    grep -v "com.anthropic.claudefordesktop" | \
    grep -E "bin/claude|claude-code-vscode|node.*claude" || true)

if [ -n "$CLAUDE_PROCS" ]; then
    echo "INFO: Active claude process(es) detected — auto-update will be SKIPPED:"
    echo "$CLAUDE_PROCS" | sed 's/^/       /'
    CAN_UPDATE=false
else
    echo "INFO: No active claude sessions detected. Auto-update permitted."
    CAN_UPDATE=true
fi

# ---- STEP 2: Capture installed version ----
INSTALLED_RAW=$("$CLAUDE_BIN" --version 2>&1 || true)
INSTALLED_VERSION=$(echo "$INSTALLED_RAW" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [ -z "$INSTALLED_VERSION" ]; then
    echo "ERROR: Could not parse installed version from \`claude --version\` output:"
    echo "$INSTALLED_RAW" | sed 's/^/       /'
    echo "ERROR: The output format may have changed. Aborting to avoid a bad digest."
    alert_failure "claude --version parse failed"
    exit 1
fi
echo "INFO: Installed version (before): $INSTALLED_VERSION"

# ---- STEP 3a: Collect Tier 2 context (whitelist only) ----
# We inline a small, stable set of files so the digest knows the user's actual
# setup. Not dynamic enough to leak things they didn't plan to share. Each
# block is optional — missing files just mean the corresponding section is empty.
CONTEXT_FILE="$(mktemp -t claude-digest-context.XXXXXX)"
trap 'rm -f "$CONTEXT_FILE" "${CONTEXT_FILE%.ctx}"' EXIT

{
    echo "=== BEGIN USER CONTEXT BUNDLE ==="
    echo "# The following sections describe the user's current Claude Code setup."
    echo "# Use them to ground the 'why it matters' and 'features worth trying' sections."
    echo "# Anything marked '(not found)' means that file/directory doesn't exist; skip it."
    echo

    echo "--- global CLAUDE.md (user's operating principles) ---"
    if [ -f "$HOME/.claude/CLAUDE.md" ]; then
        cat "$HOME/.claude/CLAUDE.md"
    else
        echo "(not found)"
    fi
    echo

    echo "--- global rules (user's explicit behavioral rules) ---"
    if compgen -G "$HOME/.claude/rules/*.md" > /dev/null; then
        for f in "$HOME/.claude/rules"/*.md; do
            echo "### $(basename "$f")"
            cat "$f"
            echo
        done
    else
        echo "(no rules/ directory or empty)"
    fi
    echo

    echo "--- installed skills (with descriptions) ---"
    # For each skill dir at ~/.claude/skills/<name>/, extract the YAML
    # frontmatter from SKILL.md (description, argument-hint, allowed-tools).
    # That tells the daemon what each skill actually *does*, not just its name.
    if [ -d "$HOME/.claude/skills" ]; then
        echo "## ~/.claude/skills/ (custom/personal)"
        for dir in "$HOME/.claude/skills"/*/; do
            [ -d "$dir" ] || continue
            name="$(basename "$dir")"
            echo "### /$name"
            if [ -f "$dir/SKILL.md" ]; then
                # Extract frontmatter (between the first pair of ---). Max 15 lines.
                awk '/^---$/{if(++n==2) exit; next} n==1{print}' "$dir/SKILL.md" 2>/dev/null | head -15
                # Plus the first body line after frontmatter (usually the H1 or intent).
                awk 'f && NF {print; exit} /^---$/{if(++n==2)f=1}' "$dir/SKILL.md" 2>/dev/null
            else
                echo "(no SKILL.md)"
            fi
            echo
        done
    fi
    if [ -d "$HOME/.claude/plugins/marketplaces" ]; then
        MARKETPLACE_OUT=$(find "$HOME/.claude/plugins/marketplaces" -maxdepth 2 -mindepth 2 -type d -exec basename {} \; 2>/dev/null | grep -v '^\.' | sort)
        if [ -n "$MARKETPLACE_OUT" ]; then
            echo "## ~/.claude/plugins/marketplaces/ (installed plugins, names only)"
            echo "$MARKETPLACE_OUT"
        fi
    fi
    if [ ! -d "$HOME/.claude/skills" ] && [ ! -d "$HOME/.claude/plugins" ]; then
        echo "(no skills/ or plugins/ directory)"
    fi
    echo

    echo "--- Context OS navigation index (if user maintains one) ---"
    if [ -f "$HOME/.claude/context-os/CONTEXT-OS.md" ]; then
        cat "$HOME/.claude/context-os/CONTEXT-OS.md"
    else
        echo "(no Context OS)"
    fi
    echo

    echo "--- recently active projects (modified in last 7 days; topical signal only) ---"
    # Only folders modified in the last 7 days. This is a weak signal of what
    # the user is actually touching this week — NOT a list of his portfolio.
    # Digests should not name these projects unless the changelog item maps
    # specifically to one of them (per the template's grounding rules).
    if [ -d "$HOME/Desktop/Projects" ]; then
        find "$HOME/Desktop/Projects" -maxdepth 1 -mindepth 1 -type d -mtime -7 -exec basename {} \; 2>/dev/null | sort | head -20
    else
        echo "(no ~/Desktop/Projects directory)"
    fi
    echo

    echo "--- MCP servers (live status from 'claude mcp list') ---"
    # Run the CLI's canonical mcp list. Shows transport (stdio/HTTP/SSE),
    # the command or URL, and the current health (Connected / Failed / Needs auth).
    # This is the source of truth — settings.json is stale or partial.
    # Use gtimeout if available (GNU coreutils via Homebrew), else run unbounded.
    # `claude mcp list` is fast in practice; the guard is defense-in-depth.
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout 15 "$CLAUDE_BIN" mcp list 2>&1 | grep -v "^Checking" || echo "(claude mcp list failed or unavailable)"
    else
        "$CLAUDE_BIN" mcp list 2>&1 | grep -v "^Checking" || echo "(claude mcp list failed or unavailable)"
    fi
    echo

    echo "--- prior digest history (tiered) ---"
    # Tiered inlining: the last 3 digests in full (for editorial callbacks,
    # correction awareness, shape continuity); digests 4+ as one-line summaries
    # from INDEX.md. This bounds bundle growth — without the cap, each new
    # digest referenced prior digests which grew each one, causing a positive
    # feedback loop that hit ~54KB by day 7 and produced stream timeouts.
    #
    # See `/Users/nicomarino/.claude/plans/can-you-review-this-goofy-hippo.md`
    # for the audit that motivated this tiering.
    echo "# Last 1 digest in full (most recent):"
    COUNT=0
    for md in $(find "$INSTALL_DIR" -maxdepth 1 -type f -name '????-??-??.md' 2>/dev/null | sort -r); do
        [ -f "$md" ] || continue
        NAME="$(basename "$md")"
        # Skip today's file — we haven't written it yet this run.
        [ "$NAME" = "$TODAY.md" ] && continue
        echo "### $NAME"
        cat "$md"
        echo
        COUNT=$((COUNT + 1))
        [ "$COUNT" -ge 1 ] && break
    done
    [ "$COUNT" -eq 0 ] && echo "(no previous digests — this may be the first run)"
    echo
    echo "# Older digests — one-liner summaries from INDEX.md (for continuity, not detail):"
    if [ -f "$INDEX_FILE" ]; then
        # Print INDEX lines that refer to dated digests, skipping the 1 most
        # recent (already inlined in full above) and today's line (not written yet).
        SKIP_DATES=()
        for md in $(find "$INSTALL_DIR" -maxdepth 1 -type f -name '????-??-??.md' 2>/dev/null | sort -r | head -1); do
            SKIP_DATES+=("$(basename "$md" .md)")
        done
        SKIP_DATES+=("$TODAY")
        grep -E '^- [0-9]{4}-[0-9]{2}-[0-9]{2}' "$INDEX_FILE" 2>/dev/null | while read -r line; do
            SKIP=0
            for d in "${SKIP_DATES[@]}"; do
                case "$line" in "- $d"*) SKIP=1; break;; esac
            done
            [ $SKIP -eq 0 ] && echo "$line"
        done
    else
        echo "(no INDEX.md)"
    fi
    echo

    # Hard cap: if the bundle exceeds 30KB after everything above, drop the
    # oldest full digests (the bulkiest component) until under cap. Done
    # outside this heredoc after CONTEXT_FILE is written — see below.

    echo "=== END USER CONTEXT BUNDLE ==="
} > "$CONTEXT_FILE"

CONTEXT_BYTES="$(wc -c < "$CONTEXT_FILE" | tr -d ' ')"
echo "INFO: Tier 2 context bundle (pre-cap): $CONTEXT_BYTES bytes"

# ---- Bundle size cap (30KB hard limit) ----
# If the tiered bundle still exceeds 30KB, truncate the "Last 3 digests in
# full" section by dropping the oldest full digest (the 3rd one listed).
# This is a belt-and-suspenders — the tiering alone should keep us well
# under 30KB in normal operation.
BUNDLE_CAP=30720  # 30KB
# Iteratively drop oldest full digest until under cap. Starts by keeping 3,
# then 2, then 1. If a single digest + all other bundle components still
# exceeds 30KB, that's an anomaly worth logging — but we continue with the
# single most-recent digest rather than corrupting the bundle.
for KEEP_N in 2 1 0; do
    [ "$CONTEXT_BYTES" -le "$BUNDLE_CAP" ] && break
    echo "WARNING: Bundle ${CONTEXT_BYTES}b > ${BUNDLE_CAP}b cap. Reducing full digests from N to $KEEP_N."
    TRIMMED_FILE="$(mktemp -t claude-digest-context-trimmed.XXXXXX)"
    # Drop everything starting at the (KEEP_N + 1)th "### YYYY-MM-DD.md"
    # header within the "Last N digests in full" section, up to (but not
    # including) the "# Older digests" header.
    awk -v keep="$KEEP_N" '
        /^# Last .* digests in full/ { in_full=1; full_count=0; print; next }
        /^# Older digests/ { in_full=0; print; next }
        in_full && /^### [0-9]{4}-[0-9]{2}-[0-9]{2}\.md/ {
            full_count++
            if (full_count > keep) { skip=1 }
        }
        in_full && skip { next }
        { print }
    ' "$CONTEXT_FILE" > "$TRIMMED_FILE"
    mv "$TRIMMED_FILE" "$CONTEXT_FILE"
    CONTEXT_BYTES="$(wc -c < "$CONTEXT_FILE" | tr -d ' ')"
done
echo "INFO: Tier 2 context bundle (post-cap): $CONTEXT_BYTES bytes"

# ---- STEP 3b: Render prompt template and append context ----
USER_NAME="$(id -F 2>/dev/null || whoami)"
USER_WORKFLOWS="${USER_WORKFLOWS:-General software development. No specific framework preferences.}"

PROMPT_FILE="$(mktemp -t claude-digest-prompt.XXXXXX)"
trap 'rm -f "$PROMPT_FILE" "$CONTEXT_FILE"' EXIT

# We use python for substitution instead of sed: macOS BSD sed chokes on
# multibyte delimiters, and any pipe/slash chars in USER_WORKFLOWS would
# break the common escapes. Python's str.replace handles everything cleanly.
export TODAY USER_NAME EMAIL USER_WORKFLOWS INSTALLED_VERSION CAN_UPDATE INSTALL_DIR CLAUDE_BIN
python3 - "$PROMPT_TPL" "$PROMPT_FILE" <<'PYEOF'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, 'r', encoding='utf-8') as f:
    text = f.read()
subs = {
    '__TODAY__':             os.environ.get('TODAY', ''),
    '__USER_NAME__':         os.environ.get('USER_NAME', ''),
    '__EMAIL__':             os.environ.get('EMAIL', ''),
    '__USER_WORKFLOWS__':    os.environ.get('USER_WORKFLOWS', ''),
    '__INSTALLED_VERSION__': os.environ.get('INSTALLED_VERSION', ''),
    '__CAN_UPDATE__':        os.environ.get('CAN_UPDATE', ''),
    '__INSTALL_DIR__':       os.environ.get('INSTALL_DIR', ''),
    '__CLAUDE_BIN__':        os.environ.get('CLAUDE_BIN', ''),
}
for placeholder, value in subs.items():
    text = text.replace(placeholder, value)
with open(dst, 'w', encoding='utf-8') as f:
    f.write(text)
PYEOF

# Append the context bundle after the rendered template. The template's final
# instruction points Claude at the bundle.
cat "$CONTEXT_FILE" >> "$PROMPT_FILE"

echo "INFO: Invoking $CLAUDE_BIN with model=$CLAUDE_MODEL effort=$CLAUDE_EFFORT"

# ---- STEP 4: Run claude -p with exponential-backoff retries ----
# Observed API failure modes (see .planning audit):
#   - "Stream idle timeout - partial response received": transient in most
#     cases, but can recur across back-to-back attempts during API pressure.
#   - Individual attempts can run for hours before streaming completes.
# Retry strategy: 3 attempts at 60s, 5min, 20min. The 5min backoff covers a
# warm-cache second try during transient degradation; the 20min backoff
# covers genuine incident-length windows. Worst-case total wall clock is
# ~26min plus attempt time. launchd ExitTimeOut bumped to 2400s (40min)
# to accommodate.
MAX_ATTEMPTS=3
RETRY_DELAYS=(60 300 1200)  # seconds between attempts 1→2 (60s), 2→3 (5min)... actually used after attempt N to wait before N+1
ATTEMPT=1
CLAUDE_EXIT=0

while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    echo "----------------------------------------"
    echo "INFO: Attempt $ATTEMPT of $MAX_ATTEMPTS"
    echo "----------------------------------------"

    "$CLAUDE_BIN" \
        -p "$(cat "$PROMPT_FILE")" \
        --permission-mode bypassPermissions \
        --output-format text \
        --model "$CLAUDE_MODEL" \
        --effort "$CLAUDE_EFFORT"
    CLAUDE_EXIT=$?

    echo "----------------------------------------"
    echo "INFO: claude -p (attempt $ATTEMPT) exited with code $CLAUDE_EXIT"

    if [ -f "$INSTALL_DIR/$TODAY.md" ]; then
        break
    fi

    if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
        # Index into RETRY_DELAYS: attempt N (1-indexed) → delay[N-1]
        DELAY="${RETRY_DELAYS[$((ATTEMPT - 1))]}"
        echo "WARNING: Digest not produced on attempt $ATTEMPT. Waiting ${DELAY}s before retry $((ATTEMPT + 1))."
        sleep "$DELAY"
    fi
    ATTEMPT=$((ATTEMPT + 1))
done

# ---- STEP 5: Verify digest produced ----
# Expect Claude to produce both a markdown file and a JSON file. The JSON
# drives the email render; the markdown is the durable human archive.
JSON_FILE="$INSTALL_DIR/$TODAY.json"
MD_FILE="$INSTALL_DIR/$TODAY.md"
if [ -f "$MD_FILE" ] && [ -f "$JSON_FILE" ]; then
    echo "SUCCESS: Markdown digest at $MD_FILE"
    echo "SUCCESS: JSON digest at $JSON_FILE"
elif [ -f "$MD_FILE" ] && [ ! -f "$JSON_FILE" ]; then
    echo "ERROR: Markdown produced but JSON missing. Renderer can't build the email."
    echo "ERROR: Claude may not have written to the expected path."
    alert_failure "JSON missing — digest produced but unbuildable"
    exit 1
else
    echo "ERROR: Digest files not produced after $MAX_ATTEMPTS attempts."
    echo "ERROR: Last claude -p exit code: $CLAUDE_EXIT"
    alert_failure "claude -p failed after $MAX_ATTEMPTS attempts (exit $CLAUDE_EXIT)"
    exit 1
fi

INSTALLED_AFTER=$("$CLAUDE_BIN" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
echo "INFO: Installed version (after): ${INSTALLED_AFTER:-UNKNOWN}"

# ---- STEP 6: Render JSON -> multipart MIME .eml ----
EML_FILE="$EMAILS_DIR/$TODAY.eml"
RENDER_SCRIPT="$INSTALL_DIR/bin/render-email.py"
if [ ! -f "$RENDER_SCRIPT" ]; then
    echo "ERROR: Renderer missing at $RENDER_SCRIPT"
    alert_failure "render-email.py missing — install broken"
    exit 1
fi
if ! python3 "$RENDER_SCRIPT" "$JSON_FILE" "$EML_FILE"; then
    echo "ERROR: render-email.py failed on $JSON_FILE"
    alert_failure "render-email.py failed on today's JSON"
    exit 1
fi
echo "INFO: Rendered multipart MIME email to $EML_FILE"

# ---- STEP 7: Send via msmtp ----
if command -v msmtp >/dev/null 2>&1; then
    if msmtp -a gmail -t < "$EML_FILE"; then
        echo "INFO: Email sent via msmtp (gmail account)"
    else
        MSMTP_EXIT=$?
        echo "WARNING: msmtp send failed (exit $MSMTP_EXIT). .eml at $EML_FILE — see $LOG_DIR/msmtp.log"
    fi
else
    echo "WARNING: msmtp not installed; .eml at $EML_FILE for manual send"
fi

# ---- STEP 7: Log rotation ----
# gzip daily logs > 30d, delete .gz > 180d. Leaves launchd.*.log and
# msmtp.log alone (they're small and append-only).
find "$LOG_DIR" -maxdepth 1 -type f -name '????-??-??.log' -mtime +30 -exec gzip -q {} \; 2>/dev/null || true
find "$LOG_DIR" -maxdepth 1 -type f -name '????-??-??.log.gz' -mtime +180 -delete 2>/dev/null || true

echo "========================================"
echo "Daily changelog review finished: $(date)"
echo "========================================"

exit 0
