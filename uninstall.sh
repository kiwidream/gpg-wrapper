#!/bin/bash

set -euo pipefail
umask 077

INSTALL_BIN="$HOME/.local/bin/git-gpg-preview"
INSTALL_LIB_DIR="$HOME/.local/libexec/git-gpg-preview"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/git-gpg-preview"
STATE_DIR="$HOME/.local/state/git-gpg-preview"
STATE_MARKER="$STATE_DIR/previous-program-state"
STATE_VALUES="$STATE_DIR/previous-program-values"
LOCK_FILE="$HOME/Library/Caches/git-gpg-preview/dialog.lock"

if [[ ! -f "$STATE_MARKER" ]]; then
    printf 'uninstall.sh: installation state is missing; refusing to guess the previous Git setting\n' >&2
    exit 1
fi

state=$(<"$STATE_MARKER")
git config --global --unset-all gpg.openpgp.program >/dev/null 2>&1 || true
case "$state" in
    absent) ;;
    present)
        while IFS= read -r -d '' value; do
            git config --global --add gpg.openpgp.program "$value"
        done < "$STATE_VALUES"
        ;;
    *)
        printf 'uninstall.sh: invalid installation state; Git setting was left unset\n' >&2
        exit 1
        ;;
esac

rm -f "$INSTALL_BIN"
rm -rf "$INSTALL_LIB_DIR" "$CONFIG_DIR"
rm -f "$LOCK_FILE"
rm -rf "$STATE_DIR"

if git config --global --get-all gpg.openpgp.program >/dev/null 2>&1; then
    printf 'Restored global gpg.openpgp.program:\n'
    git config --global --get-all gpg.openpgp.program
else
    printf 'Restored global gpg.openpgp.program to absent.\n'
fi
printf 'Audit logs, if enabled, were not removed.\n'
