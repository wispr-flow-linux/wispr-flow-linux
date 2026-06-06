[< Back to learnings](index.md)

# The helper spawn env — why injection died but recording worked

Hey! The app spawns the native helper with a **replacement** environment object
that contains only telemetry keys. It never spreads `process.env`. On macOS and
Windows the helper reaches the OS through native APIs and needs no session env,
so upstream never propagated it. The Linux helper does need it. Backend detection
gates on the session display vars, so with them stripped it silently picks the
no-op `stub` injector and nothing ever gets typed. The mic still records and
shortcuts still fire, which is what makes this so confusing.

**Source files:**

- [`scripts/patches/helper-env.sh`](../../scripts/patches/helper-env.sh) — the fix (prepends `...process.env,`)
- [`src/backend/mod.rs`](https://github.com/wispr-flow-linux/helper/blob/main/src/backend/mod.rs) (in the `wispr-flow-linux/helper` repo) — `pick_injector()`, the env gate
- [`scripts/patches/helper-resolver.sh`](../../scripts/patches/helper-resolver.sh) — PATCH NOTE #3 (the original misdiagnosis)

## The symptom

Keyboard shortcuts work. The tray shows recording. Transcription happens. But no
text lands in the focused field. The app log is unambiguous:

```
[error] Helper service stderr { stderr: 'ERROR ... PasteText failed: no backend available (stub)' }
```

And the helper's own startup log jumps straight to the stub with **no**
intervening Wayland/X11 warning:

```
WARN  ...backend] injection: stub (no-op) — OS integration disabled
INFO  ...backend] backend: stub (no active-app provider)
```

## The key realization

Here's what finally clicked for me. `pick_injector()` (mod.rs) only reaches the
stub *without logging anything about Wayland or X11* when **both
`WAYLAND_DISPLAY` and `DISPLAY` are empty/unset** in the helper's environment:

```rust
fn pick_injector() -> Box<dyn Backend> {
    if env_set("WAYLAND_DISPLAY") { /* uinput → wayland backend */ }
    if env_set("DISPLAY")         { /* XTEST → x11 backend */ }
    log::warn!("injection: stub (no-op) — OS integration disabled");
    Box::new(stub::StubBackend)
}
```

The helper spawn site in the bundle (`.webpack/main/index.js`) is:

```js
helper.process = spawn(s, {
  stdio: ["pipe","pipe","pipe","pipe"],
  env: { sentryDSN, environment, segmentWriteKey, postHogProjectKey, sentryLocalDebug }
})
```

That `env:` object **replaces** the child environment. It does not spread
`process.env`. So the helper inherits none of `WAYLAND_DISPLAY`, `DISPLAY`,
`XDG_RUNTIME_DIR`, or `DBUS_SESSION_BUS_ADDRESS`. Backend detection then sees no
session and falls to the stub.

## Why recording and shortcuts still worked

Keypress capture (`key capture: evdev (/dev/input)`) reads input devices
directly and needs no session env, so push-to-talk and the shortcut recorder
keep working. That asymmetry is the fingerprint of this bug: input *in* is fine,
text *out* is dead. Recording, transcription, and the gRPC path all live in the
Electron process, which has a full env. Only the helper child is starved.

## The fix

Prepend `...process.env,` to the spawn's env object. Now the session env
propagates, and the telemetry keys that follow still override anything of the
same name. `helper-env.sh` does this as a surgical, idempotent, marker-guarded
patch, in the same family as `helper-resolver.sh` / `mac-gates.sh`. It's applied
by `build-linux.sh` and enforced by `verify-patches.sh` (`WISPR_LINUX_HELPER_ENV`).

## The trap to avoid

`helper-resolver.sh` PATCH NOTE #3 originally read "the Rust helper may ignore
[the env keys]; harmless." I had that wrong. A *replacement* env is a silent
feature-killer. It quietly strips the session vars the helper depends on, and
the only symptom is that text never lands. So when you audit a child-spawn on
Linux, always check whether `env:` spreads the parent or replaces it.
