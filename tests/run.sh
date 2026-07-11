#!/bin/bash

set -euo pipefail
umask 077

ROOT=$(cd -P -- "$(dirname -- "$0")/.." && pwd)
TMP="$ROOT/tests/tmp/run.$$"
ORIGINAL_HOME=$HOME
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/.config/git-gpg-preview" "$TMP/temp" "$TMP/calls" "$TMP/captures" "$TMP/lock"

export HOME="$TMP/home"
export XDG_CONFIG_HOME="$HOME/.config"
export TMPDIR="$TMP/temp"
export FAKE_GPG_CALL_DIR="$TMP/calls"
export FAKE_DIALOG_CAPTURE_DIR="$TMP/captures"
export FAKE_DIALOG_DECISION=sign
export FAKE_DIALOG_DELAY=0
export FAKE_DIALOG_LOG="$TMP/dialog.log"
# Shared "hardware touch" signal: the fake dialog creates it for a sign
# decision; the fake GPG blocks on it so signing is concurrent with review.
export FAKE_TOUCH_FILE="$TMP/touch"

cat > "$XDG_CONFIG_HOME/git-gpg-preview/config" <<EOF
real_gpg=$ROOT/tests/helpers/fake-gpg
ui_helper=$ROOT/tests/helpers/fake-dialog.jxa
lock_root=$TMP/lock
audit_log=$TMP/audit.log
EOF
chmod 600 "$XDG_CONFIG_HOME/git-gpg-preview/config"

pass_count=0
fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}
pass() {
    pass_count=$((pass_count + 1))
    printf 'ok %d - %s\n' "$pass_count" "$1"
}

latest_call() {
    tail -n 1 "$FAKE_GPG_CALL_DIR/calls"
}
latest_capture() {
    ls -t "$TMP/captures"/*.summary | head -n 1
}
details_of() {
    printf '%s\n' "${1%.summary}.details"
}
assert_forwarded() {
    local expected="$1" id
    id=$(latest_call)
    cmp -s "$expected" "$FAKE_GPG_CALL_DIR/$id.stdin" || fail "stdin changed before real GPG"
}
run_preview() {
    local label="$1" payload="$2" expected_type="$3" expected_stdout output summary details id
    expected_stdout="signature:$label"
    export FAKE_GPG_STDOUT="$expected_stdout"
    rm -f "$FAKE_TOUCH_FILE".*
    output=$("$ROOT/git-gpg-preview" --status-fd=2 -bsau 'TEST KEY ! $(touch bad)' < "$payload")
    [[ "$output" == "$expected_stdout" ]] || fail "$label contaminated stdout"
    assert_forwarded "$payload"
    summary=$(latest_capture)
    details=$(details_of "$summary")
    grep -F "Request type: $expected_type" "$summary" >/dev/null || fail "$label classified incorrectly"
    grep -F 'SHA-256:' "$summary" >/dev/null || fail "$label omitted payload hash"
    grep -F 'Signing key: TEST KEY ! $(touch bad)' "$summary" >/dev/null || fail "$label lost key selector"
    grep -F 'Exact payload SHA-256:' "$details" >/dev/null || fail "$label details omitted payload hash"
    [[ ! -e "$FIXTURE/bad" ]] || fail "$label executed hostile-looking key content"
    id=$(latest_call)
    printf '%s\0' --status-fd=2 -bsau 'TEST KEY ! $(touch bad)' > "$TMP/expected.args"
    cmp -s "$TMP/expected.args" "$FAKE_GPG_CALL_DIR/$id.args" || fail "$label changed GPG arguments"
}

FIXTURE="$TMP/repository with spaces"
mkdir -p "$FIXTURE"
git -C "$FIXTURE" init -b main >/dev/null
git -C "$FIXTURE" config user.name 'Preview Tester'
git -C "$FIXTURE" config user.email 'preview@example.invalid'
git -C "$FIXTURE" config commit.gpgSign false
git -C "$FIXTURE" config tag.gpgSign false

printf 'initial\n' > "$FIXTURE/initial.txt"
git -C "$FIXTURE" add -- initial.txt
git -C "$FIXTURE" commit -m 'Initial message' >/dev/null
INITIAL=$(git -C "$FIXTURE" rev-parse HEAD)
git -C "$FIXTURE" cat-file commit "$INITIAL" > "$TMP/initial.payload"

HOSTILE_NAME=$'unicodé $(touch bad)\nsecond line.txt'
printf 'hostile-looking filename content\n' > "$FIXTURE/$HOSTILE_NAME"
git -C "$FIXTURE" add -- "$HOSTILE_NAME"
git -C "$FIXTURE" commit -m $'Unicode Ω and spaces\n\n$(touch bad); `touch bad`; "quoted"' >/dev/null
SECOND=$(git -C "$FIXTURE" rev-parse HEAD)
git -C "$FIXTURE" cat-file commit "$SECOND" > "$TMP/commit.payload"

git -C "$FIXTURE" checkout -b side "$SECOND" >/dev/null
printf 'side\n' > "$FIXTURE/side.txt"
git -C "$FIXTURE" add -- side.txt
git -C "$FIXTURE" commit -m 'Side parent' >/dev/null
git -C "$FIXTURE" checkout main >/dev/null
printf 'main\n' > "$FIXTURE/main.txt"
git -C "$FIXTURE" add -- main.txt
git -C "$FIXTURE" commit -m 'Main parent' >/dev/null
git -C "$FIXTURE" merge --no-ff side -m 'Merge two parents' >/dev/null
MERGE=$(git -C "$FIXTURE" rev-parse HEAD)
git -C "$FIXTURE" cat-file commit "$MERGE" > "$TMP/merge.payload"

git -C "$FIXTURE" tag -a preview-tag -m $'Annotated tag Ω\n\n$(touch bad)'
TAG_OBJECT=$(git -C "$FIXTURE" rev-parse preview-tag)
git -C "$FIXTURE" cat-file tag "$TAG_OBJECT" > "$TMP/tag.payload"

cd "$FIXTURE"

run_preview 'initial commit' "$TMP/initial.payload" commit
summary=$(latest_capture)
details=$(details_of "$summary")
grep -F 'Parents: (initial commit; none)' "$details" >/dev/null || fail 'initial commit parent display'
grep -F 'Initial commit (empty tree to proposed tree)' "$details" >/dev/null || fail 'initial commit diffstat'
pass 'initial signed commit payload and root diffstat'

EVIL="$TMP/evil-diff"
cat > "$EVIL" <<EOF
#!/bin/bash
touch '$TMP/external-diff-ran'
exit 99
EOF
chmod 700 "$EVIL"
git config diff.external "$EVIL"
run_preview 'signed commit' "$TMP/commit.payload" commit
[[ ! -e "$TMP/external-diff-ran" ]] || fail 'external diff executed'
summary=$(latest_capture)
grep -F 'Unicode Ω and spaces' "$summary" >/dev/null || fail 'Unicode message missing'
details=$(details_of "$summary")
grep -F 'DERIVED CHANGED-FILE SUMMARY / DIFFSTAT' "$details" >/dev/null || fail 'diffstat missing'
grep -F 'EXACT SIGNED PAYLOAD — VERBATIM BYTES BETWEEN MARKERS' "$details" >/dev/null || fail 'exact payload detail missing'
grep -F 'DERIVED FULL DIFF — REVIEW AID, NOT LITERAL GPG INPUT' "$details" >/dev/null || fail 'derived diff warning missing'
[[ ! -e "$FIXTURE/bad" ]] || fail 'hostile message or filename executed'
pass 'signed commit, hostile content, safe derived diff, and exact payload details'

run_preview 'merge commit' "$TMP/merge.payload" commit
summary=$(latest_capture)
details=$(details_of "$summary")
[[ $(grep -c '^  [0-9a-f]\{40\}$' "$details") -eq 2 ]] || fail 'merge parents not shown'
grep -F 'Changes from parent 2:' "$details" >/dev/null || fail 'second merge-parent diffstat missing'
pass 'merge commit with multiple parents'

run_preview 'annotated tag' "$TMP/tag.payload" tag
summary=$(latest_capture)
details=$(details_of "$summary")
grep -F 'Annotated tag Ω' "$summary" >/dev/null || fail 'tag message missing'
grep -F 'Target object:' "$details" >/dev/null || fail 'tag target missing'
pass 'annotated tag payload'

{
    printf 'unknown signing format\nUnicode Ω\n'
    printf '\000\001hostile $(touch bad)\n'
} > "$TMP/unknown.payload"
run_preview 'unknown payload' "$TMP/unknown.payload" unknown
pass 'unknown and binary signing payload'

cat > "$TMP/push.payload" <<EOF
certificate version 0.1
pusher 0123456789012345678901234567890123456789 1700000000 +0000
pushee ssh://example.invalid/repository

0000000000000000000000000000000000000000 1111111111111111111111111111111111111111 refs/heads/main
EOF
run_preview 'push certificate' "$TMP/push.payload" 'push certificate'
pass 'push certificate payload'

before=$(wc -l < "$FAKE_GPG_CALL_DIR/calls")
export FAKE_DIALOG_DECISION=cancel
rm -f "$FAKE_TOUCH_FILE".*
set +e
cancel_output=$("$ROOT/git-gpg-preview" -bsau TEST < "$TMP/commit.payload" 2>"$TMP/cancel.stderr")
cancel_status=$?
set -e
after=$(wc -l < "$FAKE_GPG_CALL_DIR/calls")
[[ "$cancel_status" -ne 0 ]] || fail 'cancellation returned success'
[[ -z "$cancel_output" ]] || fail 'cancellation wrote stdout'
[[ "$before" -eq "$after" ]] || fail 'cancellation contacted GPG'
pass 'cancellation fails without contacting GPG'

export FAKE_DIALOG_DECISION=sign
export FAKE_GPG_STDOUT='verify-output'
printf 'verification input bytes\000tail' > "$TMP/verify.stdin"
verify_output=$("$ROOT/git-gpg-preview" --status-fd=1 --verify "$TMP/fake.sig" - < "$TMP/verify.stdin")
[[ "$verify_output" == 'verify-output' ]] || fail 'verification stdout changed'
assert_forwarded "$TMP/verify.stdin"
pass 'verification invocation transparently passes through'

export FAKE_GPG_STDOUT='gpg-failure-output'
export FAKE_GPG_EXIT=42
rm -f "$FAKE_TOUCH_FILE".*
set +e
"$ROOT/git-gpg-preview" -bsau TEST < "$TMP/commit.payload" > "$TMP/failure.stdout" 2> "$TMP/failure.stderr"
failure_status=$?
set -e
unset FAKE_GPG_EXIT
[[ "$failure_status" -eq 42 ]] || fail "GPG exit status changed ($failure_status)"
[[ $(<"$TMP/failure.stdout") == 'gpg-failure-output' ]] || fail 'GPG failure stdout changed'
assert_forwarded "$TMP/commit.payload"
pass 'GPG failure and exact exit code propagation'

export FAKE_GPG_STDOUT=''
export FAKE_GPG_SIGNAL=TERM
rm -f "$FAKE_TOUCH_FILE".*
set +e
"$ROOT/git-gpg-preview" -bsau TEST < "$TMP/commit.payload" > "$TMP/signal.stdout" 2> "$TMP/signal.stderr"
signal_status=$?
set -e
unset FAKE_GPG_SIGNAL
[[ "$signal_status" -eq 143 ]] || fail "GPG signal was not propagated ($signal_status)"
[[ ! -s "$TMP/signal.stdout" ]] || fail 'signal path contaminated stdout'
pass 'GPG termination-signal propagation'

: > "$FAKE_DIALOG_LOG"
export FAKE_GPG_STDOUT='parallel-signature'
export FAKE_DIALOG_DELAY=0.35
rm -f "$FAKE_TOUCH_FILE".*
"$ROOT/git-gpg-preview" -bsau TEST < "$TMP/commit.payload" > "$TMP/parallel.1" 2> "$TMP/parallel.1.err" &
p1=$!
"$ROOT/git-gpg-preview" -bsau TEST < "$TMP/merge.payload" > "$TMP/parallel.2" 2> "$TMP/parallel.2.err" &
p2=$!
wait "$p1"
wait "$p2"
export FAKE_DIALOG_DELAY=0
lock_events=()
while IFS= read -r event; do
    lock_events+=("$event")
done < "$FAKE_DIALOG_LOG"
[[ "${#lock_events[@]}" -eq 4 ]] || fail 'concurrent dialog event count'
[[ "${lock_events[0]}" == start\ * && "${lock_events[1]}" == end\ * && "${lock_events[2]}" == start\ * && "${lock_events[3]}" == end\ * ]] || fail 'dialogs overlapped'
[[ $(<"$TMP/parallel.1") == 'parallel-signature' && $(<"$TMP/parallel.2") == 'parallel-signature' ]] || fail 'parallel stdout changed'
pass 'concurrent requests queue dialogs and retain separate payloads'

printf '999999\n' > "$TMP/lock/dialog.lock"
export FAKE_GPG_STDOUT='stale-lock-recovered'
rm -f "$FAKE_TOUCH_FILE".*
stale_output=$("$ROOT/git-gpg-preview" -bsau TEST < "$TMP/commit.payload")
[[ "$stale_output" == 'stale-lock-recovered' ]] || fail 'stale lock recovery failed'
pass 'stale dialog lock recovery'

before=$(wc -l < "$FAKE_GPG_CALL_DIR/calls")
printf 'tree 0000000000000000000000000000000000000000\n\ninvalid tree\n' > "$TMP/invalid-commit.payload"
set +e
"$ROOT/git-gpg-preview" -bsau TEST < "$TMP/invalid-commit.payload" > "$TMP/invalid.stdout" 2> "$TMP/invalid.stderr"
invalid_status=$?
set -e
after=$(wc -l < "$FAKE_GPG_CALL_DIR/calls")
[[ "$invalid_status" -ne 0 && "$before" -eq "$after" ]] || fail 'invalid recognized payload reached GPG'
[[ ! -s "$TMP/invalid.stdout" ]] || fail 'invalid payload contaminated stdout'
pass 'recognized payload parsing/object errors fail closed'

[[ -f "$TMP/audit.log" && $(stat -f '%Lp' "$TMP/audit.log") == 600 ]] || fail 'audit log permissions'
! grep -F 'Unicode Ω and spaces' "$TMP/audit.log" >/dev/null || fail 'audit log contains raw message'
grep -F 'decision=sign' "$TMP/audit.log" >/dev/null || fail 'audit decision missing'
pass 'mode-0600 metadata-only audit log'

INSTALL_TEST="$TMP/install-home"
mkdir -p "$INSTALL_TEST"
(
    export HOME="$INSTALL_TEST"
    export XDG_CONFIG_HOME="$HOME/.config"
    "$ROOT/install.sh" --real-gpg "$ROOT/tests/helpers/fake-gpg" >/dev/null
    [[ $(git config --global --get gpg.openpgp.program) == "$HOME/.local/bin/git-gpg-preview" ]]
    [[ $(stat -f '%Lp' "$HOME/.local/bin/git-gpg-preview") == 700 ]]
    [[ $(stat -f '%Lp' "$XDG_CONFIG_HOME/git-gpg-preview/config") == 600 ]]
    [[ $(<"$HOME/.local/state/git-gpg-preview/previous-program-state") == absent ]]
    "$ROOT/install.sh" --real-gpg "$ROOT/tests/helpers/fake-gpg" >/dev/null
    [[ $(<"$HOME/.local/state/git-gpg-preview/previous-program-state") == absent ]]
    "$ROOT/uninstall.sh" >/dev/null
    ! git config --global --get gpg.openpgp.program >/dev/null 2>&1
    [[ ! -e "$HOME/.local/bin/git-gpg-preview" ]]
) || fail 'idempotent install or absent-value recovery'
pass 'idempotent installation and restoration of an absent previous value'

RESTORE_TEST="$TMP/restore-home"
mkdir -p "$RESTORE_TEST"
(
    export HOME="$RESTORE_TEST"
    export XDG_CONFIG_HOME="$HOME/.config"
    git config --global --add gpg.openpgp.program '/previous/path with spaces/gpg'
    "$ROOT/install.sh" --real-gpg "$ROOT/tests/helpers/fake-gpg" >/dev/null
    "$ROOT/uninstall.sh" >/dev/null
    [[ $(git config --global --get-all gpg.openpgp.program) == '/previous/path with spaces/gpg' ]]
) || fail 'exact previous-value restoration'
pass 'uninstaller restores the exact previous program value'

[[ ! -e "$ORIGINAL_HOME/git-gpg-preview-tests-touched" ]] || fail 'unexpected file outside test area'
printf '1..%d\n' "$pass_count"
