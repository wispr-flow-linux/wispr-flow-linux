#!/usr/bin/env bash
# ptt-trace.sh -- durable capture for diagnosing input-stream failures.
#
# `main.log` rotates at 3 MiB and, on affected builds, is ~98% leaked-interval
# spam, so evidence of a push-to-talk failure moment is usually destroyed
# before anyone looks (issue #48). This tool keeps a filtered, rotation-proof
# trail under ~/.cache/wispr-flow/ptt-trace/:
#
#   main-filtered.log  every main.log line except the two spam lines
#                      (tail -F follows across rotation)
#   udev-input.log     timestamped `udevadm monitor` input-subsystem events
#                      (device add/remove -- correlate failures with churn)
#
# Usage:  ptt-trace.sh start | stop | status
#
# Start it, reproduce the failure (hours/days), then read the two files side
# by side around the failure moment. Stop it when done -- the followers are
# cheap but not free.
#
# Project styleguide: tabs, [[ ]], no set -e.

trace_dir="${XDG_CACHE_HOME:-$HOME/.cache}/wispr-flow/ptt-trace"
main_log="${XDG_CONFIG_HOME:-$HOME/.config}/Wispr Flow/logs/main.log"

# The two leaked-interval lines that flood main.log (see
# scripts/patches/status-interval-log-ratelimit.sh).
spam_re='Window is destroyed, ignoring (monitorMove interval|interval for ignoreMouseEventsWhenNotInAlphaRegion)'

usage() {
	echo "usage: ${0##*/} start|stop|status" >&2
	exit 2
}

pid_alive() {
	local pid_file="$1" pid
	[[ -r $pid_file ]] || return 1
	pid=$(< "$pid_file")
	[[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

start_follower() {
	# tail -F survives electron-log's copy-truncate rotation.
	(
		tail -n 0 -F "$main_log" 2>/dev/null \
			| grep -avE --line-buffered "$spam_re" \
			>> "$trace_dir/main-filtered.log"
	) &
	echo $! > "$trace_dir/follower.pid"
}

start_udev_monitor() {
	if ! command -v udevadm &>/dev/null; then
		echo 'WARN: udevadm not found; skipping input-churn monitor' >&2
		return
	fi
	(
		udevadm monitor --udev --subsystem-match=input 2>/dev/null \
			| while IFS= read -r line; do
				printf '%(%F %T)T %s\n' -1 "$line"
			done >> "$trace_dir/udev-input.log"
	) &
	echo $! > "$trace_dir/udev.pid"
}

cmd_start() {
	mkdir -p "$trace_dir"
	if pid_alive "$trace_dir/follower.pid"; then
		echo "already running (see: ${0##*/} status)"
		return 0
	fi
	printf '%(%F %T)T === ptt-trace start ===\n' -1 \
		>> "$trace_dir/main-filtered.log"
	start_follower
	start_udev_monitor
	echo "tracing into $trace_dir"
	echo '  main-filtered.log  (spam-free main.log follower)'
	[[ -f $trace_dir/udev.pid ]] \
		&& echo '  udev-input.log     (input device add/remove)'
}

cmd_stop() {
	local f stopped=0
	for f in "$trace_dir/follower.pid" "$trace_dir/udev.pid"; do
		if pid_alive "$f"; then
			# Kill the subshell's process group children too.
			pkill -P "$(< "$f")" 2>/dev/null
			kill "$(< "$f")" 2>/dev/null
			stopped=$((stopped + 1))
		fi
		rm -f "$f"
	done
	((stopped > 0)) && echo 'stopped' || echo 'not running'
}

cmd_status() {
	local running=0
	if pid_alive "$trace_dir/follower.pid"; then
		echo "main.log follower: running (pid $(< "$trace_dir/follower.pid"))"
		running=1
	else
		echo 'main.log follower: not running'
	fi
	if pid_alive "$trace_dir/udev.pid"; then
		echo "udev monitor:      running (pid $(< "$trace_dir/udev.pid"))"
		running=1
	else
		echo 'udev monitor:      not running'
	fi
	if [[ -d $trace_dir ]]; then
		du -sh "$trace_dir" 2>/dev/null
	fi
	((running == 1))
}

case "${1:-}" in
	start)  cmd_start ;;
	stop)   cmd_stop ;;
	status) cmd_status ;;
	*)      usage ;;
esac
