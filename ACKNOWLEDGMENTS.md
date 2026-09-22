# Acknowledgments

People whose fix, report or diagnosis shaped a change on `main`. Updated on
every merged external PR and whenever an issue author's snippet or root-cause
work is used, in the order the work landed.

| Who | What |
|---|---|
| @khamsakamal48 | Re-anchored `helper-env.sh` on `{sentryDSN:` after 1.6.774 moved the helper's spawn env into a factory (#55, carried in #80). The `latest.json` installer resolver and the AppStream icon fix (#55, carried in #84). `linux-main-shortcut-defaults.sh`: the `-1` push-to-talk keycode that fresh Linux profiles were seeded with (#55, fixes #33 and #46). |
| @jaikr-dev | `linux-hub-focusable.sh`: the Hub window came up override-redirect on X11 (#39, fixes #36). |
| @Techyid613 | Reported #36 and sent an independent, byte-identical fix (#45). |
| @bits-orio | Reported #56, the same override-redirect Hub on another X11 desktop. |
| @vascode2 | Traced the immovable Hub to `focusable:false` stripping `_NET_WM_ACTION_MOVE` from `_NET_WM_ALLOWED_ACTIONS` (#72, #74). |
| @rajivranjanmars | The push-to-talk and shortcut-recorder troubleshooting section, and the onboarding line in `--doctor` (#37). |
| @caio-passos | The `wl-copy` hang as a paste-failure cause, with the four-second check and the `xclip` shim (#42). |
| @jcartu | `linux-early-singleton.sh`: SIGABRT on a second launch, found through `coredumpctl` (#51). |
| @crafteraadarsh | `linux-disable-pill-drag.sh`: the stranded drag overlay on Wayland (#66). |
| @Anirudh-K96 | The real fixed-output hash for the Nix helper fetch (#40). |
