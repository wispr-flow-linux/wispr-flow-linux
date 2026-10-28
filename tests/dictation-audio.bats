#!/usr/bin/env bats

@test "dictation audio mutes and pauses only what it changed, then restores it" {
	dir="$BATS_TEST_TMPDIR"
	cat > "$dir/index.js" <<-'EOF'
	const $state={RA:{prefs:{user:{}},hubWindow:{}}};
	const $dict={ZZ:{uuid:"fixture"}},$log=()=>({info(){}});
	const $ipc={send(){}},$events={LF:{DictationStatus:"status"}};
	function update(e){$log().info(`updateDictationStatus: ${e}`,{customAttributes:{uuid:$dict.ZZ.uuid}}),(0,$ipc.send)($state.RA.hubWindow,$events.LF.DictationStatus,e);$dict.ZZ.status=e}
	require("node:readline").createInterface({input:process.stdin}).on("line",line=>{
		const message=JSON.parse(line);
		$state.RA.prefs.user=message.prefs;
		update(message.status);
	});
	EOF
	bash "$BATS_TEST_DIRNAME/../scripts/patches/linux-dictation-audio.sh" "$dir/index.js"
	cat > "$dir/pactl" <<-'EOF'
	#!/usr/bin/env bash
	case "${0##*/} $*" in
	'pactl --format=json list sinks')
		echo '[{"name":"speakers","mute":false},{"name":"headphones","mute":true}]' ;;
	'playerctl --list-all') printf 'browser\nspotify\n' ;;
	'playerctl --player browser status') cat "${0%/*}/browser" ;;
	'playerctl --player spotify status') echo Paused ;;
	*) echo "${0##*/} $*" >> "${0%/*}/log" ;;
	esac
	if [[ $* == *' pause' ]]; then echo Paused > "${0%/*}/$2"; fi
	EOF
	chmod +x "$dir/pactl"
	ln -s pactl "$dir/playerctl"
	echo Playing > "$dir/browser"
	PATH="$dir:$PATH"
	# The app exits at the end of stdin while the speakers are still muted.
	run node "$dir/index.js" <<-'EOF'
	{"status":"initializing","prefs":{"shouldMuteAudio":true}}
	{"status":"listening","prefs":{"shouldMuteAudio":true}}
	{"status":"dismissed","prefs":{}}
	{"status":"initializing","prefs":{}}
	{"status":"idle","prefs":{}}
	{"status":"initializing","prefs":{"shouldPauseAudio":true}}
	{"status":"processing","prefs":{"shouldPauseAudio":true}}
	{"status":"initializing","prefs":{"shouldMuteAudio":true}}
	EOF
	[[ "$status" -eq 0 ]]
	diff - "$dir/log" <<-'EOF'
	pactl set-sink-mute speakers 1
	pactl set-sink-mute speakers 0
	playerctl --player browser pause
	playerctl --player browser play
	pactl set-sink-mute speakers 1
	pactl set-sink-mute speakers 0
	EOF
}
