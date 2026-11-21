[< Back to learnings](index.md)

# Hidden windows and the video wake lock

Started from the autostart entry (`--hidden`), the app kept the screen from
turning off: it held an `org.freedesktop.ScreenSaver` inhibit with reason
"Video Wake Lock" until it quit. Nothing in the port's patches or the helper
touches wake locks. The inhibit came from Chromium, because of a video playing
in a window nobody could see.
[`linux-hub-video-focus-pause.sh`](../../scripts/patches/linux-hub-video-focus-pause.sh)
is the fix.

## A never-shown window reports itself visible

The Hub is created with `show:!1` and no `paintWhenInitiallyHidden`, so
Electron's default (`true`) applies: the renderer is active, and the page's
`document.visibilityState` is `"visible"` until the window is shown and hidden
again. Anything that keys on page visibility (media, timers, Chromium's own
throttling) treats a Hub that was never shown as on screen.

## Chromium turns a playing video into a screen inhibit

Chromium takes a display-sleep wake lock, described as "Video Wake Lock", for
any playing `<video>` in a visible page, muted or not. On Linux that becomes an
`org.freedesktop.ScreenSaver.Inhibit` call, and a desktop that honours it
(COSMIC's cosmic-idle, for one) never runs its screen-off timeout. The video
here was the looping demo in the post-onboarding dialog, which the Hub renders
for any account that hasn't finished that dialog.

## Pausing once at mount does not hold

The dialog's video component attaches its source through hls.js (a
MediaSource) after the parent's effects have run. Attaching a source runs the
media load algorithm, which re-arms autoplay, so a `pause()` at mount is undone
moments later. Pausing from the `"play"` event catches every start, autoplay
included.

## Why not `paintWhenInitiallyHidden:false`

Setting it on the Hub makes the hidden page report `"hidden"`, and the wake lock
goes away. But the page then skips autoplay, and the dialog's focus handler
only resumes a video it paused itself, so opening the Hub shows the video
frozen on its first frame. The video has no controls and no click handler, so
the user has no way to start it.

## Tracing an inhibit to a window

- Watch the session bus for `Inhibit` and `UnInhibit` on
  `org.freedesktop.ScreenSaver` (`busctl --user monitor`). The caller's pid and
  the reason string name the process and the kind of lock.
- Start the app with `--remote-debugging-port=<port>` and list its pages at
  `http://127.0.0.1:<port>/json`. Evaluating
  `document.querySelectorAll('video')` in each page over the DevTools protocol
  finds the playing element. Calling `pause()` on it should release the inhibit
  at once, which confirms the cause.
