# git-gpg-preview

`git-gpg-preview` is a fail-closed, Git-specific OpenPGP wrapper for macOS. Git invokes it through `gpg.openpgp.program`. For a signing request, the wrapper captures the exact stdin bytes once, shows a concise foreground preview of what Git is asking GPG to sign, and engages real GnuPG concurrently so your hardware key's confirmation prompt is active while the preview is on screen.

Because GnuPG is engaged during the preview, your key blocks on its normal confirmation (a touch, plus the PIN only when gpg-agent has not cached it). Touching the key completes the signature and dismisses the preview; **Cancel** kills GnuPG before it produces a signature, so Git aborts. The physical hardware confirmation — not a software button — is the authorization gate.

Verification and other non-signing GPG operations pass directly to the configured absolute GPG executable without a dialog.

## Requirements

- macOS, including `/usr/bin/osascript`, AppKit, `shlock`, and standard command-line tools
- Git
- GnuPG (`gpg`)

No Python, package runtime, daemon, network service, or third-party GUI framework is used.

## Install

Inspect the scripts, then run:

```sh
cd ~/git-gpg-preview
./tests/run.sh
./install.sh --real-gpg /absolute/path/to/gpg
```

The installer:

- installs the executable as `~/.local/bin/git-gpg-preview`;
- installs the static JXA/AppKit dialog helper under `~/.local/libexec/git-gpg-preview/`;
- writes a mode-0600 configuration containing the absolute real-GPG path;
- records the exact previous global `gpg.openpgp.program` state once; and
- sets global `gpg.openpgp.program` to the wrapper.

It does not alter `commit.gpgSign`, `tag.gpgSign`, `user.signingkey`, GPG agent configuration, smart-card configuration, PIN policy, or hardware touch/confirmation policy. Re-running `install.sh` updates the installed files without replacing the original recovery state.

To enable the optional metadata-only audit log during installation:

```sh
./install.sh --real-gpg /absolute/path/to/gpg \
  --audit-log "$HOME/Library/Logs/git-gpg-preview/audit.log"
```

The audit file and its directory are restricted to the current user. Each line contains only a UTC timestamp, sanitized repository path, request type, payload SHA-256, calling PID/process, and decision. It never records payloads, messages, diffs, filenames, PINs, passphrases, or signature bytes.

## Review behavior

For signing operations, stdin is copied exactly once into a unique mode-0600 file within a mode-0700 temporary request directory. Each request retains its own payload. Dialogs from simultaneous Git processes are serialized using macOS `shlock`; dead-process locks are recovered atomically. Because each request holds the lock across its preview and signature, one hardware confirmation completes before the next request's preview appears.

The main dialog is deliberately small and concise, showing:

- request type: commit, annotated tag, push certificate, or unknown;
- branch;
- GPG signing-key selector, when present;
- exact byte count and SHA-256;
- the commit/tag message or payload body.

**View Details** opens a selectable, scrollable report containing everything else: the full repository/worktree path, the tree and parent/target object hashes, the per-parent changed-file summary, the verbatim captured payload, a byte-preserving hex view, and the complete safely generated diff for commits.

The preview appears and reports readiness before GPG is engaged, so when a PIN is required the pinentry prompt launches last and stays frontmost and focused rather than opening behind the preview. The preview does not steal focus back, so you can type the PIN and then touch the key.

There is no **Sign** button: the signature is produced by the hardware confirmation that is already pending while the preview is shown. Touching the key completes signing with the captured bytes and original arguments and dismisses the window. **Cancel** kills GPG before it produces a signature and returns nonzero, so Git aborts.

The dialog deliberately labels two different things:

1. **Exact signed payload:** the bytes supplied to GPG. This includes the proposed commit/tag object headers and message.
2. **Derived review information:** repository labels, branch, diffstat, and textual diff reconstructed from Git objects. A commit's signed tree hash commits to file content, but the textual diff is not literally part of GPG's input.

Diffs are generated with `git --no-pager`, `--no-ext-diff`, and `--no-textconv`; repository content is never interpolated into AppleScript, JXA, or shell source. Dialog data travels only through mode-0600 files and argument values. Summary control characters are sanitized.

## Fail-closed cases

A signing request is rejected before GPG runs when the real-GPG path or UI helper is missing, a recognized commit/tag payload cannot be safely parsed against available Git objects, or a secure temporary area cannot be created. Once the preview and GPG are engaged, a **Cancel** decision, a preview process that exits without approval, or any outcome other than a completed signature kills GPG before it produces a signature. Unknown signing formats still receive a clearly labeled exact-payload review.

Non-signing operations require a valid real-GPG configuration too; when configured correctly, they use `exec` for transparent argument, descriptor, signal, stdout/stderr, and exit behavior. For signing, stdout and stderr remain connected directly to GPG, and the wrapper propagates GPG's exact exit code and forwards termination signals. The wrapper never writes UI or diagnostic text to stdout because Git expects the detached signature there.

## Threat model and limitations

This tool protects against accidentally producing an unexpected Git OpenPGP signature: the payload is reviewed while your hardware key waits, and the deliberate physical confirmation is what completes the signature. It makes concurrent agent-driven requests attributable at review time and serializes them behind a single hardware confirmation. It does not replace GnuPG signature security, hardware-key confirmation, repository access controls, or careful review.

Important limitations:

- The preview is shown while GnuPG is already engaged, so the hardware confirmation is the authorization gate. This is a deliberate trade for the touch-to-sign workflow: unlike a design that contacts GPG only after a software approval, GnuPG and gpg-agent are invoked for every signing request. A key whose policy requires no touch (for example, a cached PIN and touch disabled) can therefore complete signing before the preview is meaningfully reviewed; keep the hardware touch requirement enabled so signing always blocks on a deliberate action.
- A process already running as your macOS account can modify user-owned wrapper/configuration files, tamper with Git objects between review and later use, simulate UI, or invoke GPG directly.
- The derived diff reflects objects available when the preview is built. The signed tree hash—not the rendered diff—is authoritative.
- Binary and very large changes can make a full textual report unwieldy; the exact payload's hex view remains byte-preserving.
- Git object formats that do not resemble standard commit, annotated-tag, or push-certificate payloads appear as `unknown`.
- The wrapper is intentionally for Git's GPG interface, not a general-purpose replacement for every GPG client.
- The absolute real-GPG path must remain executable. If a package-manager upgrade removes it, reinstall with the new path.

## Troubleshooting and recovery

If Git reports `gpg failed to sign the data`, check the wrapper's stderr, then verify:

```sh
git config --global --get gpg.openpgp.program
cat ~/.config/git-gpg-preview/config
ls -l ~/.local/bin/git-gpg-preview
```

If no dialog appears, ensure the current macOS session can present AppKit UI and that `dialog.jxa` is installed. Dialog/UI failures intentionally abort signing. A stale lock owned by a dead process is recovered automatically. To inspect the lock without deleting an active request:

```sh
cat ~/Library/Caches/git-gpg-preview/dialog.lock
```

Do not work around a blocked workflow with `--no-gpg-sign`. Recover the original exact Git setting instead:

```sh
cd ~/git-gpg-preview
./uninstall.sh
```

The uninstaller restores all previously recorded `gpg.openpgp.program` values, or unsets the key if it was originally absent. It removes installed wrapper/configuration files but deliberately leaves any audit log. If the repository is unavailable, run its `uninstall.sh` from a backup copy; the recovery state lives in `~/.local/state/git-gpg-preview/`.

## Tests

`./tests/run.sh` uses a fake GPG and a noninteractive fake dialog in an isolated home directory. It covers normal and initial commits, merge commits, annotated tags, push certificates, unknown/binary payloads, hostile Unicode content, cancellation, verification pass-through, GPG failure status, stdout purity, exact stdin/argument forwarding, concurrent queueing, stale lock recovery, safe diff options, and audit logging.

## License

MIT. See [LICENSE](LICENSE).
