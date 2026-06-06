# Security Policy

Hey! Found a security bug? Report it to me privately via [GitHub Security
Advisories](https://github.com/wispr-flow-linux/wispr-flow-linux/security/advisories/new).
Please don't open a public issue or post details in Discussions — let me get a
fix out first.

## Scope

I'll be honest about what I can actually fix here. This project is an unofficial
Linux port: a **clean-room Rust helper** plus a **repackaging pipeline** for the
proprietary Wispr Flow Electron app. The boundary matters, so here's the map.

| Area | In scope | Out of scope |
|------|----------|--------------|
| Rust helper ([wispr-flow-linux/helper](https://github.com/wispr-flow-linux/helper), pinned via `helper-version.txt`) | ✅ injection backends, IPC handling, uinput/clipboard/AT-SPI surface — tracked in that repo | — |
| Packaging (`scripts/packaging/`) | ✅ deb / rpm / AppImage makers, udev rule, file perms | — |
| Launcher & doctor (`scripts/launcher-common.sh`, `scripts/doctor.sh`) | ✅ the `wispr-flow --doctor` surface, lock handling, the launcher rename | — |
| App patches (`scripts/patches/`) | ✅ `helper-resolver.sh`, `mac-gates.sh`, the V8/sqlite patch | — |
| CI (`.github/workflows/`) | ✅ the lint + unit-test gate workflows, secret handling | — |
| The Wispr Flow app itself | — | ❌ the proprietary Electron app, its bundle logic |
| Wispr's servers / API / account flow | — | ❌ report to [Wispr Flow](https://wisprflow.ai) |
| Upstream Windows / macOS apps | — | ❌ not built or shipped here |

The short version: **in scope** = the Rust helper, the packaging/launcher/doctor
scripts, the CI, and the patches this repo ships. **Out of scope** = the
proprietary Wispr Flow application, Wispr's backend services, and the upstream
Windows/macOS apps. I can't fix those, and I shouldn't be the public record for
them either — those belong in Wispr's own channels.

## Input-device access (by design)

Before you file this one as a bug: yes, the helper touches input devices, and
that's on purpose. Push-to-talk and keystroke injection both need it, so the
bundled udev rule grants that access to the **active-session user** via
`TAG+="uaccess"` (with the `input` group + `0660` as a cross-distro fallback):

- **read `/dev/input/event*`** — the global key monitor that detects the
  push-to-talk hotkey and drives the in-app shortcut recorder.
- **write `/dev/uinput`** — synthesizing keystrokes for paste / `SimulateKeyPress`.

I want to be clear that this is a deliberate trade-off, not a vulnerability.
Reading evdev means any process running **as the logged-in user** can observe
keystrokes — and that's already true for X11 clients and any `/dev/uinput`
writer. `uaccess` scopes the grant to the active local session rather than all
users, which is the minimum a global-hotkey dictation app needs, and it mirrors
how tools like `ydotool`/`kanata` work. I put the `--install-udev-rules` path
and the doctor's input-access check in place precisely so this stays explicit
and auditable. Now, if you find the surface widening in a way I *didn't* intend
— say, a rule handing access to inactive sessions or to all users — that's a
real bug, and it's in scope.

## What to include in a report

- Reproducer: commands, environment, distro / desktop / session type
  (Wayland/X11).
- Output of `wispr-flow --doctor` if relevant.
- Affected version(s) — the release tag you installed from (or
  `git describe --tags`), and the bundled Wispr Flow app version.
- Any related upstream advisories or CVEs you found while investigating.

## Response

GitHub Advisories ping me (@aaddrick) directly. I usually acknowledge within a
few days. After that, turnaround really depends on where the bug lives — helper,
packaging, and launcher bugs I can normally turn around fast. Patches against the
minified upstream bundle are the slow ones: sometimes I have to wait for a
tractable anchor to show up in a future Wispr Flow release before there's
anything stable to patch against.
