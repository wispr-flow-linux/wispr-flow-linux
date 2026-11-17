#!/usr/bin/env bash
#
# Create or update the shared label set in every wispr-flow-linux repo.
#
# Reads .github/labels.txt ("name|color|description" per line) and makes
# each repo match it. Labels missing from the file are left alone; this
# never deletes. Needs an authenticated gh with write access to the repos.
#
# Usage: scripts/maint/sync-labels.sh [--dry-run] [owner/repo ...]

readonly DEFAULT_REPOS=(
	wispr-flow-linux/wispr-flow-linux
	wispr-flow-linux/helper
	wispr-flow-linux/native-modules
	wispr-flow-linux/worker
)

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 1
labels_file="$script_dir/../../.github/labels.txt"

die() {
	echo "sync-labels: $*" >&2
	exit 1
}

# Percent-encode a label name for the REST path (spaces and colons).
urlencode() {
	local s=$1 out='' c i
	for (( i = 0; i < ${#s}; i++ )); do
		c=${s:i:1}
		case $c in
			[a-zA-Z0-9._~-]) out+=$c ;;
			*) out+=$(printf '%%%02X' "'$c") ;;
		esac
	done
	printf '%s' "$out"
}

# Print "name|color|description" for every label already on a repo.
existing_labels() {
	local repo=$1
	gh api --paginate "repos/$repo/labels?per_page=100" \
		--jq '.[] | "\(.name)|\(.color)|\(.description // "")"'
}

apply_label() {
	local repo=$1 verb=$2 name=$3 color=$4 desc=$5
	local -a call=(-X POST "repos/$repo/labels" -f name="$name")

	if [[ $verb == update ]]; then
		call=(-X PATCH "repos/$repo/labels/$(urlencode "$name")")
	fi
	gh api "${call[@]}" -f color="$color" -f description="$desc" \
		>/dev/null || echo "  failed to $verb $name" >&2
}

sync_repo() {
	local repo=$1 dry=$2
	local current name color desc line have verb
	local -A have_line=()

	current=$(existing_labels "$repo") || {
		echo "  cannot read labels on $repo, skipping" >&2
		return 1
	}
	while IFS= read -r line; do
		[[ -n $line ]] || continue
		have_line[${line%%|*}]=$line
	done <<< "$current"

	while IFS='|' read -r name color desc; do
		[[ -z $name || $name == '#'* ]] && continue
		have=${have_line[$name]-}
		if [[ -z $have ]]; then
			verb=create
		elif [[ $have != "$name|$color|$desc" ]]; then
			verb=update
		else
			continue
		fi
		echo "  $verb $name"
		[[ $dry == 1 ]] && continue
		apply_label "$repo" "$verb" "$name" "$color" "$desc"
	done < "$labels_file"
}

main() {
	local dry=0 repo status=0
	local -a repos=()

	while (( $# > 0 )); do
		case $1 in
			--dry-run) dry=1 ;;
			-h|--help)
				sed -n '3,9p' "${BASH_SOURCE[0]}" |
					sed 's/^# \{0,1\}//'
				return 0
				;;
			-*) die "unknown option: $1" ;;
			*) repos+=("$1") ;;
		esac
		shift
	done
	(( ${#repos[@]} > 0 )) || repos=("${DEFAULT_REPOS[@]}")

	[[ -r $labels_file ]] || die "missing $labels_file"
	command -v gh >/dev/null 2>&1 || die 'gh is not installed'

	for repo in "${repos[@]}"; do
		echo "$repo"
		sync_repo "$repo" "$dry" || status=1
	done
	return "$status"
}

main "$@"
