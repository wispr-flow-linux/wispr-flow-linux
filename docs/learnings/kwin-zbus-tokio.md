[< Back to learnings](index.md)

# KWin / zbus / tokio — the dispatch deadlock

Hey! On KDE, the helper learns which window is active by hosting a tiny D-Bus
service that a KWin script pushes window-activation events to. I built the first
version on the **blocking** zbus API. KDE active-app and running-apps came back
**empty** until the helper shut down, and I chased that for a while before the
cause clicked. This is the single most load-bearing concurrency invariant in the
codebase.

**Source files** (in the [`wispr-flow-linux/helper`](https://github.com/wispr-flow-linux/helper) repo):

- [`src/backend/kwin.rs`](https://github.com/wispr-flow-linux/helper/blob/main/src/backend/kwin.rs) — the KWin bridge
- [`src/backend/atspi_app.rs`](https://github.com/wispr-flow-linux/helper/blob/main/src/backend/atspi_app.rs) — the async-on-tokio pattern it now mirrors

## Overview

Wayland exposes no portable "which app is focused" protocol, so on KDE I had the
helper drive KWin's scripting engine instead. KWin JS can't return values to a
caller. But it *can* `callDBus`. So the helper:

1. Hosts a small zbus service `org.wisprflow.kwinbridge_<pid>` with a
   `Report(s)` / `ReportList(s)` method.
2. `loadScript` + `start`s a templated KWin script that connects
   `workspace.windowActivated` (and `windowAdded`/`windowRemoved`) and pushes
   `{resourceClass, resourceName, caption, pid}` to that method.
3. Caches the latest report; `GetActiveAppInfo` reads it.

That all worked in isolation. Under the full build it broke, and the reason
turned out to be a feature flag pulled in from somewhere else entirely.

## The deadlock

Here's what I found. `atspi` (used for selection reads, [D-004](../decisions.md#d-004--at-spi-as-the-universal-active-app--selection-fallback))
enables zbus's **`tokio` feature tree-wide**. That feature **disables zbus's
internal async-io executor thread** — the thread that would otherwise pump
incoming traffic on a connection.

With a zbus **blocking** service connection and no executor thread, the
connection only dispatches **incoming** method calls *while the helper itself is
making an outgoing blocking call*. So KWin's `Report` / `ReportList` callbacks
queued up. They only flushed at shutdown, when the connection drained. The cache
stayed empty the whole time, which is why `GetActiveAppInfo` and `GetRunningApps`
returned nothing for the entire session.

## The fix

The fix was to rewrite the KWin bridge to run on the **async** zbus API inside a
dedicated tokio **current-thread runtime**, kept alive for the tracker's lifetime.
It mirrors what `atspi_app.rs` already does. Incoming method calls dispatch
promptly now, because the tokio runtime is actively driving the connection.

> [!IMPORTANT]
> **Codebase rule: never host a zbus service via `zbus::blocking` here.** Any
> D-Bus service the helper exposes must run async on a live tokio runtime. See
> [D-008](../decisions.md#d-008--async-zbus-on-tokio-never-zbusblocking-for-services).

## Related KWin quirks

- **Plasma 6 renamed the API:** use `workspace.activeWindow` /
  `workspace.windowList()`. The old `activeClient` / `clientList()` are kept as a
  fallback.
- **KWin `print()` is suppressed** by default log rules. So `callDBus` (not
  journal scraping) is the reliable way to get data out of a KWin script.
- **`windowActivated(null)`** fires transiently on desktop focus, e.g. between
  app launches, and it would blank the cached active-app. The handler now skips
  totally-empty reports and keeps last-known-good.
- **Load-time `callDBus` into the helper can be intermittently delayed/dropped.**
  I've seen this as a known residual issue. The candidate mitigation is
  re-emitting on a short KWin timer plus ensuring prompt zbus replies.

## References

- [decisions.md D-005](../decisions.md#d-005--per-compositor-active-app-providers),
  [D-008](../decisions.md#d-008--async-zbus-on-tokio-never-zbusblocking-for-services).
