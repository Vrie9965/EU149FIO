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
#   <state_dir>/featured.txt AND that this run has not drawn before: a
#   per-run session file in /tmp remembers the drawn lines, so a run that
#   examines several candidates always gets distinct ones. Featured entries
#   store the full original log line, so exclusion is an exact-match grep.
#   When every line has been excluded once, both lists reset automatically
#   (a new "tour" of the archive starts).
#   NOTE: everything streams through pipes - never hold the whole log in a
#   shell variable (bash pattern matching on multi-MB strings is quadratic).
pick_candidate(){
	local log_file="${1}" state_dir="${2}" featured line session
	[[ -s "${log_file}" ]] || {
		printf '[FATAL] log file missing or empty: %s\n' "${log_file}" >&2
		return 1
	}
	mkdir -p "${state_dir}"
	featured="${state_dir}/featured.txt"
	# per-run session in /tmp: lines this run already drew; keyed by the
	# caller's PID so parallel runs never collide, and never committed
	session="${TMPDIR:-/tmp}/surprise_tried_${SURPRISE_FEATURE_ID:-general}_$$"
	local exclude=()
	[[ -s "${featured}" ]] && exclude+=( "${featured}" )
	[[ -s "${session}" ]] && exclude+=( "${session}" )
	if (( ${#exclude[@]} > 0 )); then
		line="$(grep -F -v -f <(sort -u "${exclude[@]}") "${log_file}" | grep 'https://facebook\.com/' | shuf -n 1)"
	else
		line="$(grep 'https://facebook\.com/' "${log_file}" | shuf -n 1)"
	fi
	if [[ -z "${line}" ]]; then
		printf '[i] no fresh candidates left - resetting the exclusion list and starting a new tour\n' >&2
		: > "${featured}"
		: > "${session}" 2>/dev/null || :
		line="$(grep 'https://facebook\.com/' "${log_file}" | shuf -n 1)"
	fi
	[[ -n "${line}" ]] || return 1
	printf '%s\n' "${line}" >> "${session}"
	printf '%s\n' "${line}"
}
