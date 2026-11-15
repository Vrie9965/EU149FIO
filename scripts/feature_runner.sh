#!/bin/bash
# ############################################ #
#  EU149FIO surprise feature runner             #
# ############################################ #
# Picks ONE feature from the registry at random (weighted) and executes it.
# Scheduled twice a day by .github/workflows/surprise.yml (6am / 6pm JST).
#
# This runner is fully separate from the frame engine (main.sh):
# it only sources surprise.conf and scripts/features/*.
#
# Exit codes: 0 = a feature ran (or deliberately skipped), non-zero = failure.

set -u

# --- load + export the surprise config so features inherit it ---
[[ -f ./surprise.conf ]] || {
	printf '[FATAL] surprise.conf not found - run this script from the repo root\n' >&2
	exit 1
}
set -a
. ./surprise.conf
set +a

. scripts/features/lib.sh

feature_depcheck bash curl jq || exit 1

STATE_DIR="${SURPRISE_STATE_DIR:-fb/surprise}"
mkdir -p "${STATE_DIR}"

# --- build the weighted pool of enabled features ---
declare -a POOL_IDS=()
# shellcheck disable=SC2034  # fdesc is the human-readable registry column
while IFS='|' read -r fid fen fw fdesc; do
	[[ "${fid}" =~ ^[A-Za-z0-9_]+$ ]] || continue              # comments / blank lines
	[[ "${fen}" = "1" ]] || continue                           # disabled
	[[ "${fw}" =~ ^[0-9]+$ ]] || fw=1
	(( fw < 1 )) && fw=1
	if [[ ! -e "scripts/features/${fid}.sh" ]]; then
		printf '[WARN] registry lists "%s" but scripts/features/%s.sh is missing; skipping\n' "${fid}" "${fid}" >&2
		continue
	fi
	for ((w = 0; w < fw; w++)); do POOL_IDS+=("${fid}"); done
done < "${SURPRISE_REGISTRY}"

if (( ${#POOL_IDS[@]} == 0 )); then
	printf '[FATAL] no enabled features found in %s\n' "${SURPRISE_REGISTRY}" >&2
	exit 1
fi

# --- pick ---
picked="${POOL_IDS[RANDOM % ${#POOL_IDS[@]}]}"

# avoid running the same feature back-to-back (one reroll)
last="$(cat "${STATE_DIR}/last_feature.txt" 2>/dev/null || true)"
if [[ "${RUNNER_AVOID_REPEAT:-1}" = "1" && -n "${last}" && "${picked}" = "${last}" && ${#POOL_IDS[@]} -gt 1 ]]; then
	picked="${POOL_IDS[RANDOM % ${#POOL_IDS[@]}]}"
fi

printf '[i] feature runner picked: %s\n' "${picked}"

# --- execute the feature (isolated child process) ---
export SURPRISE_FEATURE_ID="${picked}"
export SURPRISE_STATE_DIR="${STATE_DIR}"

rc=0
bash "scripts/features/${picked}.sh" || rc=$?

printf '%s' "${picked}" > "${STATE_DIR}/last_feature.txt"

# --- log the outcome (runner entries go to runner.log) ---
SURPRISE_FEATURE_ID="runner"
case "${rc}" in
	0) feature_log '√' "feature=${picked} exit=0" ;;
	3) feature_log 'S' "feature=${picked} exit=3 (skipped, nothing posted)" ; rc=0 ;;
	*) feature_log 'x' "feature=${picked} exit=${rc}" ;;
esac

exit "${rc}"
