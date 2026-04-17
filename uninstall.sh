#!/bin/bash
# claude-daily-digest — uninstaller.
# Unloads the LaunchAgent, removes generated files, prompts before removing
# data (digests, emails, keychain entry).

set -u

if [ -t 1 ]; then
    C_GRN=$'\033[0;32m' C_YLW=$'\033[0;33m' C_RED=$'\033[0;31m' C_RST=$'\033[0m' C_BLD=$'\033[1m'
else
    C_GRN="" C_YLW="" C_RED="" C_RST="" C_BLD=""
fi

say()  { echo "${C_GRN}==>${C_RST} $*"; }
warn() { echo "${C_YLW}!${C_RST} $*"; }

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$INSTALL_DIR/config.env"

if [ ! -f "$CONFIG_FILE" ]; then
    warn "No config.env found — nothing to uninstall (or setup.sh never completed)."
    exit 0
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${LAUNCHD_LABEL:?config.env missing LAUNCHD_LABEL}"
: "${KEYCHAIN_SERVICE:?config.env missing KEYCHAIN_SERVICE}"

PLIST_PATH="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"

echo "${C_BLD}claude-daily-digest — uninstaller${C_RST}"
echo

# 1. Unload LaunchAgent
if launchctl print "gui/$(id -u)/${LAUNCHD_LABEL}" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/${LAUNCHD_LABEL}" 2>/dev/null || true
    say "Unloaded LaunchAgent."
else
    warn "LaunchAgent wasn't loaded."
fi

# 2. Remove plist
if [ -f "$PLIST_PATH" ]; then
    rm -f "$PLIST_PATH"
    say "Removed $PLIST_PATH"
fi

# 3. Offer to remove ~/.msmtprc
if [ -f "$HOME/.msmtprc" ]; then
    read -r -p "Remove ~/.msmtprc? [y/N] " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        rm -f "$HOME/.msmtprc"
        say "Removed ~/.msmtprc"
    fi
fi

# 4. Offer to remove keychain entry (needs sudo)
read -r -p "Remove Gmail app password from System keychain (service: $KEYCHAIN_SERVICE)? [y/N] " ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
    sudo security delete-generic-password -s "$KEYCHAIN_SERVICE" /Library/Keychains/System.keychain \
        && say "Removed keychain entry." \
        || warn "Keychain entry not found or removal failed."
fi

# 5. Offer to remove generated data
read -r -p "Remove digests, .eml files, and logs in $INSTALL_DIR? [y/N] " ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
    rm -rf "$INSTALL_DIR/logs" "$INSTALL_DIR/emails"
    rm -f "$INSTALL_DIR"/????-??-??.md "$INSTALL_DIR/INDEX.md"
    say "Removed digests, emails, and logs."
fi

# 6. Remove config
rm -f "$CONFIG_FILE"
say "Removed config.env"

echo
echo "${C_GRN}Uninstalled.${C_RST} The repo itself is untouched — delete the directory"
echo "if you want to remove the source too."
