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

echo "========================================"
echo "Daily changelog review starting: $(date)"
echo "========================================"
echo "INFO: INSTALL_DIR=$INSTALL_DIR"
echo "INFO: EMAIL=$EMAIL"

if [ ! -x "$CLAUDE_BIN" ]; then
    echo "ERROR: claude CLI not executable at $CLAUDE_BIN"
    echo "ERROR: Update CLAUDE_BIN in $CONFIG_FILE or reinstall Claude Code CLI."
    exit 1
fi

if [ ! -f "$PROMPT_TPL" ]; then
    echo "ERROR: Prompt template not found at $PROMPT_TPL"
    echo "ERROR: Your install appears incomplete."
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

    echo "--- installed skills (names only) ---"
    # Primary location: ~/.claude/skills/ (directories). Secondary: marketplace
    # plugins under ~/.claude/plugins/marketplaces/*/. We list both.
    if [ -d "$HOME/.claude/skills" ]; then
        echo "## ~/.claude/skills/ (custom/personal)"
        find "$HOME/.claude/skills" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | sort || echo "(empty)"
    fi
    if [ -d "$HOME/.claude/plugins/marketplaces" ]; then
        # Filter out Claude-internal metadata dirs (.claude-plugin, etc.)
        MARKETPLACE_OUT=$(find "$HOME/.claude/plugins/marketplaces" -maxdepth 2 -mindepth 2 -type d -exec basename {} \; 2>/dev/null | grep -v '^\.' | sort)
        if [ -n "$MARKETPLACE_OUT" ]; then
            echo "## ~/.claude/plugins/marketplaces/ (installed plugins)"
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

    echo "--- top-level projects (folder names only; for topical correlation) ---"
    if [ -d "$HOME/Desktop/Projects" ]; then
        ls -1 "$HOME/Desktop/Projects" 2>/dev/null | head -100
    else
        echo "(no ~/Desktop/Projects directory)"
    fi
    echo

    echo "--- MCP servers configured (from settings files) ---"
    # Extract mcpServers keys from settings.json and settings.local.json if they parse.
    for f in "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json"; do
        if [ -f "$f" ]; then
            echo "### $(basename "$f")"
            # Best-effort: python -c 'json' for robust parse; fall back to grep.
            python3 -c "
import json, sys
try:
    d = json.load(open('$f'))
    servers = list((d.get('mcpServers') or {}).keys())
    print('  mcp: ' + (', '.join(servers) if servers else '(none)'))
except Exception as e:
    print(f'  (could not parse: {e})')
" 2>/dev/null || grep -o '"mcpServers"' "$f" || true
        fi
    done
    echo

    echo "=== END USER CONTEXT BUNDLE ==="
} > "$CONTEXT_FILE"

CONTEXT_BYTES="$(wc -c < "$CONTEXT_FILE" | tr -d ' ')"
echo "INFO: Tier 2 context bundle: $CONTEXT_BYTES bytes"

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

# ---- STEP 4: Run claude -p with one retry on digest-missing ----
MAX_ATTEMPTS=2
RETRY_DELAY=60
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
        echo "WARNING: Digest not produced on attempt $ATTEMPT. Waiting ${RETRY_DELAY}s before retry."
        sleep "$RETRY_DELAY"
    fi
    ATTEMPT=$((ATTEMPT + 1))
done

# ---- STEP 5: Verify digest produced ----
if [ -f "$INSTALL_DIR/$TODAY.md" ]; then
    echo "SUCCESS: Digest written to $INSTALL_DIR/$TODAY.md"
else
    echo "ERROR: Digest file $INSTALL_DIR/$TODAY.md was not produced after $MAX_ATTEMPTS attempts."
    echo "ERROR: Last claude -p exit code: $CLAUDE_EXIT"
    echo "ERROR: Job failing with exit 1 so launchd records the failure."
    exit 1
fi

INSTALLED_AFTER=$("$CLAUDE_BIN" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
echo "INFO: Installed version (after): ${INSTALLED_AFTER:-UNKNOWN}"

# ---- STEP 6: Send the .eml via msmtp ----
EML_FILE="$EMAILS_DIR/$TODAY.eml"
if [ -f "$EML_FILE" ]; then
    if command -v msmtp >/dev/null 2>&1; then
        if msmtp -a gmail -t < "$EML_FILE"; then
            echo "INFO: Email sent via msmtp (gmail account)"
        else
            MSMTP_EXIT=$?
            echo "WARNING: msmtp send failed (exit $MSMTP_EXIT). .eml still at $EML_FILE — see $LOG_DIR/msmtp.log"
        fi
    else
        echo "INFO: msmtp not installed; .eml at $EML_FILE for manual open"
    fi
else
    echo "WARNING: No .eml file at $EML_FILE — Claude skipped email generation"
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
