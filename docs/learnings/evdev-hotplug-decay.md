[< Back to learnings](index.md)

# evdev hotplug decay — push-to-talk that dies quietly, hours later

Hey! This one hid for weeks in plain sight: push-to-talk (and the shortcut
recorder — same stream, see [global-key-monitor.md](global-key-monitor.md))
worked after every app start and then **stopped hours or days into the
session**, with `--doctor` all-green and nothing in the logs anyone read.
The mechanism, the churn that triggers it, how it stayed invisible, and the
tooling that now exists so it can never hide again.

**Source files:**

- helper `src/capture/evdev.rs` (in the
  [`wispr-flow-linux/helper`](https://github.com/wispr-flow-linux/helper)
  repo) — the capture loop; the fix is
  [helper#7](https://github.com/wispr-flow-linux/helper/issues/7) /
  [helper#8](https://github.com/wispr-flow-linux/helper/pull/8)
- [`scripts/doctor.sh`](../../scripts/doctor.sh) — the `Monitor liveness`
  probe this bug motivated
- [`scripts/ptt-trace.sh`](../../scripts/ptt-trace.sh) — durable failure-moment
  capture
- [`scripts/patches/status-interval-log-ratelimit.sh`](../../scripts/patches/status-interval-log-ratelimit.sh)
  — stops the log spam that was destroying the evidence

## The mechanism

Helper ≤ v0.1.2 enumerated `/dev/input` **once**, at capture start. Each
keyboard got a blocking reader thread; when a device node went away the read
failed with `ENODEV` and the thread returned **permanently**. No inotify
watch, no rescan, no respawn — the watched set only ever shrank. Meanwhile:

- `IsReady` keepalive pings the helper **main loop**, which stays perfectly
  healthy while capture is dead — so the app never relaunches it.
- `CheckStaleKeys` re-opens devices per query (`EVIOCGKEY`), so stale-key
  recovery kept answering correctly — it heals stuck *keys*, never dead
  *readers*.
- `--doctor` checked static prerequisites only (readability, group
  membership, binary launches), all of which stay green forever.

So every layer that could have noticed reported healthy while the actual
event stream was gone.

## /dev/input churns far more than you think

The trigger isn't exotic hardware. On the machine that surfaced this:

- **RustDesk** destroys and re-creates its uinput keyboard **every hour on
  the hour** (any remote-desktop agent may do the like).
- The USB keyboard (Keychron K2) re-enumerated on replug/reset — nine
  `read ended: No such device (os error 19)` lines across one week of logs.
- A **Bluetooth mouse** (Logitech G604) exposes a *keyboard* HID interface
  (macro buttons) and gets a fresh event node on every reconnect.
- Suspend/resume re-enumerates USB downstream devices wholesale.

Multi-day app sessions are normal, so "the keyboard's node was re-created at
least once since app start" converges on certainty. One session showed PTT
firing for the last time ~9 h in, then dead for three more days of uptime.

## Why the evidence kept vanishing

Two leaked status-window intervals log `Window is destroyed, ignoring …` at
~6.4 lines/s once the Flow Bar is torn down — 98% of `main.log`, ~1.2 MiB/h
against a 3 MiB rotation with a single `main.old.log`. **All history older
than ~5 h was gone** by the time anyone looked, including the failure moment.
The helper's stderr (which *did* say `read ended: No such device`) survives
only in `launcher.log` — 30 MB, append-only, and nobody greps it.

Two field tricks that made the week-old history readable anyway:

- `launcher.log` lines carry time-of-day but no date; the helper's stderr
  lines embed full UTC timestamps. Grep those as **date anchors**, then map
  any other line to a date by line-number interpolation.
- The app logs `Handling action from keycodes: …` only when a chord
  *matches*. Counting those per session dates exactly when PTT last fired —
  and a press that matches nothing logs **nothing**, which is why user
  reports of "it stopped" have no log signature.

## The traps this sets for a diagnostician

- **The deployed binary may not be the repo.** The affected machine ran a
  *locally built* helper (with the hotplug fix) that still reported
  `--version` `0.1.2` — identical to the broken release. Check mtimes and
  sizes against the pinned release asset (`helper-version.txt`) before
  reasoning from source. A `.orig` beside the binary is the tell.
- **"Ctrl+V still triggers actions" does not prove the keyboard stream is
  alive** — `162+86 → paste_event` matches on paste *tracking*, and those
  events can come from another device (remote-desktop uinput, mouse macro
  buttons) while the physical keyboard's reader is dead.
- **A green doctor proved nothing** until it grew the liveness probe below.

## The fix, and the observability that backs it

- **Helper** ([helper#8](https://github.com/wispr-flow-linux/helper/pull/8)):
  a hotplug monitor thread rescans on inotify
  `IN_CREATE|IN_ATTRIB|IN_MOVED_TO` under `/dev/input` (`IN_ATTRIB` because
  udev applies the `uaccess` ACL *after* node creation) with a 10 s backstop;
  readers deregister on exit so returning devices are re-adopted. The rescan
  must skip the helper's **own** uinput injection keyboard by `EVIOCGNAME` —
  it is created after capture starts, so only a rescan can see it, and
  watching it would echo every injected keystroke back as user input.
- **Doctor**: `Monitor liveness` compares the running helper's open
  `/proc/<pid>/fd` event nodes against the keyboard-capable devices present
  (KEY_A+KEY_Z bits in `/proc/bus/input/devices`), and reports the selected
  capture backend. A decayed monitor now shows up as a named unwatched
  keyboard instead of an all-green lie.
- **Trace**: `scripts/ptt-trace.sh start` keeps a spam-filtered, rotation-
  proof `main.log` follower plus a timestamped `udevadm monitor` input trail,
  so the next "it stopped working at some point" has a failure moment on
  disk.
- **Spam**: the two leaked-interval log sites are sampled 1-in-600 by
  [`status-interval-log-ratelimit.sh`](../../scripts/patches/status-interval-log-ratelimit.sh)
  so rotation keeps real history. (Upstream's actual bug — the intervals
  should die with the window — is worth reporting to Wispr; the flagged-off
  `tap-watchdog` feature suggests they already fight the mac flavor of "the
  key event source died".)
