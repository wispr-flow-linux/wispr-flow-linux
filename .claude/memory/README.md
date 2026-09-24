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
- [`pr-triage-plan-2026-09.md`](pr-triage-plan-2026-09.md) — the September
  2026 plan for the 17 open PRs, the 1.6.897 audit, and the pipeline
  practices to transfer from claude-desktop-debian.
- [`wispr-1.6.897-audit.md`](wispr-1.6.897-audit.md) — Phase 1 results: which
  anchors drifted on 1.6.897 and how they were re-anchored, runtime smoke
  results, the build-tree gotchas hit along the way, and the gate audit of
  the new `win32` reads (with the `~/Library` finding behind #100).
- [`wispr-1.6.937-audit.md`](wispr-1.6.937-audit.md) — the 1.6.937 gate
  re-audit: the three new `process.platform` reads and six new flag sites
  (none reach Linux), the code-split renderer tree (170 chunks, no platform
  reads outside the eight named renderers), the macOS-26 accessibility_drop
  panel, and the Notetaker deferral that now applies to Linux.
- [`handover-2026-09-22.md`](handover-2026-09-22.md) — the prompt to paste
  into a fresh session: where the triage stands, open PRs, next actions,
  the conventions that are not written down elsewhere.
