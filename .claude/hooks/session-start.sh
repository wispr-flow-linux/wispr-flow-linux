#!/usr/bin/env bash
#
# Claude Code SessionStart hook: make sure the lint and test tools the
# pre-push hook relies on exist. Meant for remote or fresh sessions; on a
# set-up host every tool is present and this prints one line and exits.
#
# Installs only what is missing, only with a passwordless sudo (`sudo -n`),
# via apt or dnf. A host with neither, or with a sudo that wants a
# password, is reported and left alone. actionlint has no distro package
# on Ubuntu, so it comes from its GitHub release when curl is available.
#
# Wired by .claude/settings.json.
#
# SC2024: the redirects after `sudo` are meant to run as the user, so the
# log under $HOME/.cache stays user-owned; that is the point, not a slip.
# shellcheck disable=SC2024

log_file="${XDG_CACHE_HOME:-$HOME/.cache}/wispr-flow-linux/session-start.log"
mkdir -p "$(dirname "$log_file")"

log() {
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$log_file"
}

# command -> package name, same on apt and dnf.
declare -A packages=(
	[jq]=jq
	[shellcheck]=shellcheck
	[bats]=bats
	[codespell]=codespell
	[gh]=gh
)

missing=()
for cmd in jq shellcheck bats codespell gh actionlint; do
	command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done

if ((${#missing[@]} == 0)); then
	log 'All tools present'
	echo 'Lint/test tools present: jq shellcheck bats codespell gh actionlint'
	exit 0
fi

log "Missing: ${missing[*]}"

pkg_manager=''
if command -v apt-get >/dev/null 2>&1; then
	pkg_manager='apt'
elif command -v dnf >/dev/null 2>&1; then
	pkg_manager='dnf'
fi

if [[ -z $pkg_manager ]] || ! sudo -n true 2>/dev/null; then
	log 'No apt/dnf or no passwordless sudo; not installing'
	echo "Missing lint/test tools: ${missing[*]} (install them by hand)"
	exit 0
fi

installed=()
failed=()

install_pkg() {
	local pkg="$1"
	if [[ $pkg_manager == 'apt' ]]; then
		sudo -n apt-get install -y -qq "$pkg" >> "$log_file" 2>&1
	else
		sudo -n dnf install -y -q "$pkg" >> "$log_file" 2>&1
	fi
}

install_actionlint() {
	local json url
	command -v curl >/dev/null 2>&1 || return 1
	json=$(curl -fsSL \
		https://api.github.com/repos/rhysd/actionlint/releases/latest) \
		|| return 1
	url=$(printf '%s' "$json" \
		| grep -o '"browser_download_url"[^}]*linux_amd64\.tar\.gz"' \
		| grep -o 'https://[^"]*')
	[[ -n $url ]] || return 1
	curl -fsSL "$url" | sudo -n tar xz -C /usr/local/bin actionlint
}

if [[ $pkg_manager == 'apt' ]]; then
	sudo -n apt-get update -qq >> "$log_file" 2>&1
fi

for cmd in "${missing[@]}"; do
	if [[ $cmd == 'actionlint' ]]; then
		if install_actionlint >> "$log_file" 2>&1; then
			installed+=("$cmd")
		else
			failed+=("$cmd")
		fi
		continue
	fi
	if install_pkg "${packages[$cmd]}"; then
		installed+=("$cmd")
	else
		failed+=("$cmd")
	fi
done

msg=''
((${#installed[@]} > 0)) && msg="Installed: ${installed[*]}."
((${#failed[@]} > 0)) && msg+=" Failed: ${failed[*]} (install by hand)."
log "$msg"
echo "$msg"
exit 0
