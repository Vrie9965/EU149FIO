#!/bin/bash
# ############################################ #
#  EU149FIO surprise runner (dedicated)         #
# ############################################ #
# Runs ONE surprise feature per invocation:
#   - Scheduled (surprise.yml cron, 2x/day): FRMENV_SURPRISE_CHOICE=auto
#     -> 50/50 pick between booru_guess and random_reshare, day after day,
#     until you disable the workflow (Actions > surprise runner > ... >
#     Disable workflow) or delete it.
#   - Manual (workflow_dispatch): pick "booru_guess", "random_reshare"
#     or "auto" in the Run workflow dropdown.
#
# Fully separate from the frame engine (main.sh). Self-contained: it does
# not use scripts/features/registry.conf.
#
# Exit codes: 0 = a feature posted (or a dry-run skip); 3 = nothing was
# posted, so the run deliberately shows FAILED (red) instead of silently
# succeeding; other non-zero = failure.

set -u

CHOICE="${FRMENV_SURPRISE_CHOICE:-auto}"

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

FEATURES=(booru_guess random_reshare)

# --- resolve which feature runs ---
picked=""
case "${CHOICE}" in
	auto)
		printf '[i] surprise runner choice: auto (50/50 between booru_guess and random_reshare)\n'
		last="$(cat "${STATE_DIR}/last_feature.txt" 2>/dev/null || true)"
		picked="${FEATURES[RANDOM % ${#FEATURES[@]}]}"
		# avoid running the same feature back-to-back (one reroll)
		if [[ -n "${last}" && "${picked}" = "${last}" ]]; then
			picked="${FEATURES[RANDOM % ${#FEATURES[@]}]}"
		fi
		;;
	booru_guess|random_reshare)
		picked="${CHOICE}"
		printf '[i] surprise runner choice: %s (manually selected)\n' "${picked}"
		;;
	*)
		printf '[FATAL] unknown feature choice "%s" (use: auto, booru_guess, random_reshare)\n' "${CHOICE}" >&2
		exit 1
		;;
esac

printf '[i] feature runner picked: %s\n' "${picked}"

# --- execute the feature (isolated child process) ---
export SURPRISE_FEATURE_ID="${picked}"
export SURPRISE_STATE_DIR="${STATE_DIR}"

rc=0
bash "scripts/features/${picked}.sh" || rc=$?

printf '%s' "${picked}" > "${STATE_DIR}/last_feature.txt"

# --- log the outcome (runner entries go to runner.log) ---
SURPRISE_FEATURE_ID="runner"
summary=""
dry_note=""
[[ "${FRMENV_DRY_RUN:-0}" = "1" ]] && dry_note=" (dry run - nothing is ever posted)"
case "${rc}" in
	0) feature_log '√' "feature=${picked} exit=0${dry_note}"
	   summary="**posted**${dry_note} - \`${picked}\` finished successfully" ;;
	3) feature_log 'S' "feature=${picked} exit=3 (skipped, nothing posted)${dry_note}"
	   summary="**skipped** - nothing was posted this slot${dry_note}. Reason: \`fb/surprise/${picked}.log\`"
	   if [[ "${FRMENV_DRY_RUN:-0}" = "1" ]]; then
	       rc=0 # a dry run never posts by definition - stay green
	   else
	       rc=3 # a real slot with nothing posted = failed run (red), so it gets seen
	   fi
	   ;;
	*) feature_log 'x' "feature=${picked} exit=${rc}"
	   summary="**failed** - \`${picked}\` exited with code ${rc}. See the step log and \`fb/surprise/${picked}.log\`" ;;
esac

# --- visible outcome on the Actions run page (no-op outside Actions) ---
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
	{
		printf '## Surprise feature run\n\n'
		printf 'feature: `%s`\n\nresult: %s\n' "${picked}" "${summary}"
	} >> "${GITHUB_STEP_SUMMARY}" 2>/dev/null || :
fi

exit "${rc}"
