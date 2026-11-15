#!/bin/bash
# ############################################ #
#  Feature: random_reshare                      #
# ############################################ #
# Extracted from the old scripts/reshare_random.sh (retired with its workflow).
# Picks a random frame post from fb/log.txt and shares its link on the page
# feed, exactly like the original - but without hardcoded page id/token
# wiring, with no-repeat tracking, and as a pluggable feature module.
#
# Contract (see scripts/features/README.md):
#   exit 0 = shared, exit 1 = error, exit 3 = skipped (nothing posted)

set -u

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

feature_depcheck curl jq || exit 1

# defaults (surprise.conf values are inherited through the environment)
: "${FRMENV_API_ORIGIN:=https://graph.facebook.com}"
: "${SURPRISE_FBAPI_VER:=v23.0}"
: "${SURPRISE_PAGE_ID:=222489564281150}"
: "${SURPRISE_STATE_DIR:=fb/surprise}"
: "${FRMENV_FBTOKEN:=}"
DRY="${FRMENV_DRY_RUN:-0}"

LOG_FILE="fb/log.txt"
FEATURE_STATE="${SURPRISE_STATE_DIR}/random_reshare"

if [[ "${DRY}" = "1" ]]; then
	printf '[DRY] random_reshare would pick a random post from %s and share it on page %s\n' "${LOG_FILE}" "${SURPRISE_PAGE_ID}"
	line="$(pick_candidate "${LOG_FILE}" "${FEATURE_STATE}")" || exit 3
	frame_info="$(awk -F 'https' '{print $1}' <<< "${line}" | sed -E 's/^\[[^]]*\][[:space:]]*//' | sed 's/[[:space:]]*$//')"
	frame_url="$(awk '{print $NF}' <<< "${line}")"
	printf '[DRY] would post: "%s" + link %s\n' "${frame_info}" "${frame_url}"
	exit 3 # dry run never posts, never marks the archive
fi

[[ -n "${FRMENV_FBTOKEN}" ]] || { feature_log 'x' "no token (FRMENV_FBTOKEN is empty)"; exit 1; }

# --- verify the token still manages the page (compact diagnostics) ---
# A PAGE token answers /me with the page id itself and lists nothing in
# /me/accounts - so only fall back to the accounts check for other tokens.
me_id="$(curl -s --max-time 30 "${FRMENV_API_ORIGIN}/${SURPRISE_FBAPI_VER}/me?fields=id&access_token=${FRMENV_FBTOKEN}" | jq -r '.id // empty' 2>/dev/null)"
if [[ "${me_id}" != "${SURPRISE_PAGE_ID}" ]]; then
	verify="$(curl -s --max-time 30 "${FRMENV_API_ORIGIN}/${SURPRISE_FBAPI_VER}/me/accounts?access_token=${FRMENV_FBTOKEN}")"
	if ! jq -e --arg id "${SURPRISE_PAGE_ID}" '.data[]? | select(.id == $id)' >/dev/null 2>&1 <<< "${verify}"; then
		printf '[WARN] page %s not found in the token pages. Token may be missing pages_manage_posts or is expired.\n' "${SURPRISE_PAGE_ID}" >&2
		jq -r '.data[]? | "  - \(.id): \(.name)"' <<< "${verify}" 2>/dev/null >&2 || true
		feature_log 'i' "page ${SURPRISE_PAGE_ID} not found in token pages, attempting to post anyway"
	fi
fi

# --- pick a candidate ---
line="$(pick_candidate "${LOG_FILE}" "${FEATURE_STATE}")" || {
	feature_log 'x' "no candidate available from ${LOG_FILE}"
	exit 1
}
frame_info="$(awk -F 'https' '{print $1}' <<< "${line}" | sed -E 's/^\[[^]]*\][[:space:]]*//' | sed 's/[[:space:]]*$//')"
frame_url="$(awk '{print $NF}' <<< "${line}")"
message="${frame_info}"

printf '[i] sharing: %s (%s)\n' "${frame_info}" "${frame_url}"

# --- share it ---
body="$(curl -s --max-time 60 -w '\n%{http_code}' -X POST \
	-F "message=${message}" \
	-F "link=${frame_url}" \
	"${FRMENV_API_ORIGIN}/${SURPRISE_FBAPI_VER}/${SURPRISE_PAGE_ID}/feed?access_token=${FRMENV_FBTOKEN}")"

status="$(tail -n 1 <<< "${body}")"
resp="$(head -n -1 <<< "${body}")"

if [[ "${status}" != "200" ]]; then
	error_code="$(jq -r '.error.code // empty' 2>/dev/null <<< "${resp}")"
	error_msg="$(jq -r '.error.message // empty' 2>/dev/null <<< "${resp}")"
	feature_log 'x' "share failed (${frame_info}) http=${status} code=${error_code} msg=${error_msg}"
	case "${error_code}" in
		190) printf '[HINT] error 190: token invalid or expired - regenerate TOK_FB (see README).\n' >&2 ;;
		200) printf '[HINT] error 200: token missing pages_manage_posts permission.\n' >&2 ;;
	esac
	exit 1
fi

new_id="$(jq -r '.id // empty' 2>/dev/null <<< "${resp}")"

# --- mark as featured + log ---
printf '%s\n' "${line}" >> "${FEATURE_STATE}/featured.txt"
feature_log '√' "shared (${frame_info}) -> https://facebook.com/${new_id}"

printf '[i] SUCCESS shared: https://facebook.com/%s\n' "${new_id}"
