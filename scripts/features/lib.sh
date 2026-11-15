#!/bin/bash
# ############################################ #
#  Shared helpers for the surprise features.    #
#  Sourced by feature_runner.sh and by every    #
#  feature script. Nothing here talks to the    #
#  frame engine (main.sh / scripts/process.sh). #
# ############################################ #

# feature_depcheck <cmd...> : fail loudly when a dependency is missing
feature_depcheck(){
	local missing="" c
	for c in "$@"; do
		command -v "$c" >/dev/null 2>&1 || missing+=" ${c}"
	done
	if [[ -n "${missing}" ]]; then
		printf '[FATAL] surprise feature "%s" is missing dependencies:%s\n' \
			"${SURPRISE_FEATURE_ID:-runner}" "${missing}" >&2
		return 1
	fi
	return 0
}

# feature_log <status> <message...>
#   status: √ = success | x = failure | S = skipped (nothing posted)
#   Appends to "<SURPRISE_STATE_DIR>/<feature_id>.log".
feature_log(){
	local dir="${SURPRISE_STATE_DIR:-fb/surprise}"
	mkdir -p "${dir}"
	printf '[%s] %s %s\n' "${1}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${*:2}" \
		>> "${dir}/${SURPRISE_FEATURE_ID:-runner}.log"
}

# pick_candidate <log_file> <state_dir>
#   Prints ONE random line of <log_file> whose post URL is not yet listed in
#   <state_dir>/featured.txt. Featured entries store the full original log
#   line, so exclusion is an exact-match grep. When every line has been
#   featured once, the featured list resets automatically (a new "tour" of
#   the archive starts).
#   NOTE: everything streams through pipes - never hold the whole log in a
#   shell variable (bash pattern matching on multi-MB strings is quadratic).
pick_candidate(){
	local log_file="${1}" state_dir="${2}" featured line
	[[ -s "${log_file}" ]] || {
		printf '[FATAL] log file missing or empty: %s\n' "${log_file}" >&2
		return 1
	}
	mkdir -p "${state_dir}"
	featured="${state_dir}/featured.txt"
	if [[ -s "${featured}" ]]; then
		line="$(grep -F -v -f "${featured}" "${log_file}" | grep 'https://facebook\.com/' | shuf -n 1)"
	else
		line="$(grep 'https://facebook\.com/' "${log_file}" | shuf -n 1)"
	fi
	if [[ -z "${line}" ]]; then
		printf '[i] every post has been featured once - starting a new tour of the archive\n' >&2
		: > "${featured}"
		line="$(grep 'https://facebook\.com/' "${log_file}" | shuf -n 1)"
	fi
	[[ -n "${line}" ]] || return 1
	printf '%s\n' "${line}"
}
