# Safety model and threat model

## Defaults

- Every analysis is read-only. `disk clean` is a dry run unless `--apply` is given, and the app always runs a dry run
  before it shows the confirmation sheet.
- The default cleanup mode is **Move to Trash**, which is recoverable. Permanent deletion is a separate choice and is
  only possible for rules that allow it. The Trash itself can only be emptied permanently, and the UI says so.
- Processes are never terminated automatically. Termination is graceful first (an app is asked to quit, a non-app
  receives SIGTERM). SIGKILL needs a second, separate confirmation.
- MacPulse makes no network connections, needs no root, and never changes SIP, TCC, kernel or thermal settings.

## Cleanup classification

| Class | Meaning | Can be cleaned? |
|---|---|---|
| SAFE | Verified rebuildable data (developer and browser caches, old logs) | Yes, after selection and confirmation |
| REVIEW | Possibly useful (Caches folders of unknown apps, npx/Gradle caches, Playwright browsers, old installers, Trash, duplicates) | Yes, after selection and confirmation |
| PROTECTED | Documents, media, source code, databases, credentials, configuration, app data, backups | Never; shown for transparency only |
| UNKNOWN | Not recognized | Never |

Candidates come only from an explicit catalog of locations (`CleanupCatalog`). Nothing is ever chosen because of
its name alone ("cache", "build") or its size.

## Path validation (`PathGuard`)

A path can be acted on only if all of these hold:

1. It is absolute, contains no `..` or `.` components and no NUL byte.
2. After resolving every symlink in its **parent** chain with `realpath`, it lies strictly inside an approved root,
   or exactly matches an approved whole-item path. The final component is never followed, so a symlink is treated as
   the link itself and is never selectable.
3. It is not inside a denied location. Denied locations always win, even over an allowlisted root:
   `/System /usr /bin /sbin /etc /Library /Applications /opt /Volumes`, Keychains, `.ssh`, `.gnupg`, Preferences,
   Application Support, Group Containers, iCloud Drive, Messages, Mail, Photos, Calendars, LaunchAgents, Safari,
   `.config`, any `.git` directory, and the personal folders (Documents, Desktop, Pictures, Movies, Music). The
   personal folders are allowed only for Trash-mode actions on files the user picked explicitly.
4. It is on the same device as its root and is not a mount point.

## Time-of-check / time-of-use

Each candidate records its `(device, inode, type)` at scan time. Right before acting, the cleaner:

1. rescans (CLI) or reuses the validated selection (app),
2. checks the running owners again (bundle IDs and process names) and skips anything that is in use,
3. revalidates the path and compares device, inode and type, skipping the item if anything changed,
4. checks write permission,
5. revalidates once more immediately before the irreversible step.

Deletion uses `fts` with `FTS_PHYSICAL | FTS_XDEV`, so symlinks are unlinked and never followed, and other volumes
are never entered. Every entry is checked against the root's device. Bytes freed are counted from the blocks of
inodes actually unlinked (the last link only), so hard-linked data is not reported as reclaimed.

## Concurrency, cancellation, audit

- An exclusive `flock` prevents concurrent cleanups across the CLI, the app and the monitor (exit code 75 /
  `E_BUSY`).
- Cancelling (Ctrl-C in the CLI) stops after the current entry and reports partial progress honestly.
- Every real cleanup item is written to `cleanup_history`: path, class, method, estimated bytes, measured removed
  bytes, status, detail, and the Trash location when applicable. The volume free-space change is measured and
  labelled as including other system activity.
- Results are never reported as successful without verification. Partial failures are reported with sample errors.

## Duplicates

A duplicate group's ID encodes its size. The cleaner refuses a selection that would remove every copy, and the UI
also prevents selecting the last remaining copy.

## Processes and PID reuse

A process is identified by `(pid, start time in µs)`. Before any signal, the current start time is re-read with
`sysctl(KERN_PROC_PID)`. If it differs, nothing is sent (`identityMismatch`). The following are always refused:

- PID ≤ 1
- MacPulse itself
- system processes (Apple paths or root)
- essential session processes (WindowServer, loginwindow, Dock, Finder…)
- processes owned by other users

Bulk termination by name (`killall`/`pkill` style) does not exist.

## Threats considered

| Threat | Mitigation |
|---|---|
| Symlink planted in a cache pointing at user data | Parent-chain resolution, no-follow deletion, symlink targets not selectable |
| Path swapped between scan and delete | Inode/device/type revalidation (twice) |
| Mounted volume inside a cache folder | `FTS_XDEV` + per-entry device check + mount-point refusal |
| Shell injection through file names | No shell anywhere; argv-only execution; osascript receives text via `argv` |
| PID reuse | Start-time identity check before every signal |
| Two cleanups at once | Non-blocking exclusive lock |
| Secrets leaking into reports/UI | Process arguments matching token/password/key patterns are redacted; reports exclude arguments |
| Unbounded database growth | Age and row-count retention; process table never fully persisted |
