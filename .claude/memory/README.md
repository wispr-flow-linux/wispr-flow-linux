# Cross-VM testing memory

Operational knowledge from manual VM validation (e.g. issue #32) — committed so
it carries across test VMs and survives agent session resets. This complements
[`docs/learnings/`](../../docs/learnings/index.md) (code-level learnings) with
**environment/runtime test knowledge**: how to launch and drive the app on a real
desktop, the gotchas that block testing, and per-issue validation status.

Read the relevant file before doing VM validation work, and append new hard-won
learnings here.

- [`vm-testing-notes.md`](vm-testing-notes.md) — building a test `.deb`, launching
  and driving the app, and the operational gotchas (GPU, window management,
  microphone, keybind).
- [`issue-32-validation.md`](issue-32-validation.md) — live status of the issue
  #32 manual UX validation: what's tested where, results, and decisions.
