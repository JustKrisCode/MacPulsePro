# Security Policy

MacPulse Pro can delete files and terminate processes, so safety bugs are treated as security issues.

## Supported versions

Only the latest release on `main` receives fixes.

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private reporting:
**Security → Report a vulnerability** on this repository.

Include the affected version, macOS version, steps to reproduce, and impact. You should receive an acknowledgement
within 7 days.

## In scope

- Any way to make the cleaner remove or move data outside an approved location, follow a symlink, cross a volume,
  or act on a path that changed after it was scanned
- Removing every copy of a duplicate, or deleting PROTECTED/UNKNOWN items
- Signalling a process other than the one the user confirmed (PID reuse), or a protected/system process
- Shell or command injection through file names, process names or configuration
- Secrets leaking through reports, logs, exports or the UI (process arguments are expected to be redacted)
- Privilege escalation or anything that requires/abuses administrator rights

## Out of scope

- Data removed after the user explicitly confirmed it, within documented behavior
- Values that macOS itself reports inaccurately
