#!/bin/bash
# ############################################ #
#  Feature: booru_guess                         #
# ############################################ #
# 1. Picks a random past post from fb/log.txt (never repeats until the whole
#    archive has been featured once).
# 2. Downloads that post's image from the Graph API (full_picture).
# 3. Runs it through a WD14 booru tagger (scripts/features/booru_tagger.py).
# 4. Keeps ONLY the U149 roster names (scripts/features/booru_roster.conf) —
#    every other detected character is dropped.
# 5. Re-uploads the image with the detected names as the caption — names
#    only, nothing else ("momoka sakurai\nchie sasaki").
#
# Contract (see scripts/features/README.md):
#   exit 0 = posted, exit 1 = error, exit 3 = skipped (nothing posted)

set -u

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

feature_depcheck curl jq python3 file || exit 1

# defaults (surprise.conf values are inherited through the environment)
: "${FRMENV_API_ORIGIN:=https://graph.facebook.com}"
: "${SURPRISE_FBAPI_VER:=v23.0}"
: "${SURPRISE_STATE_DIR:=fb/surprise}"
: "${FRMENV_FBTOKEN:=}"
: "${BG_MODEL_DIR:=fb/surprise/.model}"
: "${BG_MODEL_REPO:=SmilingWolf/wd-eva02-large-tagger-v3}"
: "${BG_CHAR_THRESH:=0.55}"
: "${BG_GEN_THRESH:=0.35}"
: "${BG_MAX_ATTEMPTS:=5}"
: "${BG_CAPTION_SEPARATOR:=$'\n'}"
: "${BG_DRYRUN_SAMPLE:=frames/frame_500.jpg}"
DRY="${FRMENV_DRY_RUN:-0}"

FEATURE_STATE="${SURPRISE_STATE_DIR}/booru_guess"
mkdir -p "${FEATURE_STATE}"
TMP_IMG="${FEATURE_STATE}/.candidate.img"

# --- load the roster map (danbooru_tag -> caption name) ---
declare -A ROSTER
while IFS=$'\t' read -r tag name; do
	ROSTER["${tag}"]="${name}"
done < <(awk -F'|' '!/^[[:space:]]*#/ && NF>=2 {
	gsub(/^[ \t\r]+/, "", $1); gsub(/[ \t\r]+$/, "", $1);
	sub(/[ \t]+#.*$/, "", $2);
	gsub(/^[ \t\r]+/, "", $2); gsub(/[ \t\r]+$/, "", $2);
	if ($1 != "" && $2 != "") print $1 "\t" $2
}' scripts/features/booru_roster.conf)

(( ${#ROSTER[@]} > 0 )) || { feature_log 'x' "roster map is empty (scripts/features/booru_roster.conf)"; exit 1; }

# filter_cast <tags_json>
#   Sets CAST_NAMES (newline-joined caption names, best-confidence first)
#   and CAST_DETAILS ("name (0.87) ..." for the log). Deduplicates (the
#   producer fires under several tags). Non-roster tags are dropped.
filter_cast(){
	local tags_json="$1" ranked tag conf name
	CAST_NAMES="" ; CAST_DETAILS=""
	declare -A SEEN
	ranked="$(jq -r --argjson t "${BG_CHAR_THRESH}" \
		'.characters | to_entries | map(select(.value >= $t)) | sort_by(-.value) | .[] | "\(.key)\t\(.value)"' \
		<<< "${tags_json}" 2>/dev/null)" || return 1
	while IFS=$'\t' read -r tag conf; do
		[[ -n "${tag:-}" ]] || continue
		name="${ROSTER[${tag}]:-}"
		[[ -n "${name}" ]] || continue
		[[ -n "${SEEN[${name}]:-}" ]] && continue
		SEEN["${name}"]="1"
		CAST_NAMES+="${name}"$'\n'
		CAST_DETAILS+="${name} (${conf}) "
	done <<< "${ranked}"
	CAST_NAMES="${CAST_NAMES%$'\n'}"
	return 0
}

ok=0
line="" ; frame_no="" ; episode="" ; post_id="" ; pic_url=""

for ((attempt = 1; attempt <= BG_MAX_ATTEMPTS; attempt++)); do
	line="$(pick_candidate "fb/log.txt" "${FEATURE_STATE}")" || {
		feature_log 'x' "no candidates available from fb/log.txt"
		exit 1
	}
	frame_no="$(sed -nE 's/^\[.\] Frame: ([0-9]+), Episode .*/\1/p' <<< "${line}")"
	episode="$(sed -nE 's/^\[.\] Frame: [0-9]+, Episode ([^ ]+).*/\1/p' <<< "${line}")"
	post_id="${line##*https://facebook.com/}"
	printf '[i] attempt %s/%s: %s\n' "${attempt}" "${BG_MAX_ATTEMPTS}" "${line}"

	if [[ "${DRY}" = "1" ]]; then
		# no token needed: exercise the whole tagging pipeline on a repo sample
		cp -f "${BG_DRYRUN_SAMPLE}" "${TMP_IMG}" || {
			printf '[FATAL] dry-run sample missing: %s\n' "${BG_DRYRUN_SAMPLE}" >&2
			exit 1
		}
	else
		# fetch the original image of the picked post
		meta="$(curl -s --max-time 30 \
			"${FRMENV_API_ORIGIN}/${SURPRISE_FBAPI_VER}/${post_id}?fields=full_picture&access_token=${FRMENV_FBTOKEN}")"
		err_code="$(jq -r '.error.code // empty' 2>/dev/null <<< "${meta}")"
		if [[ "${err_code}" = "190" ]]; then
			feature_log 'x' "token expired or invalid (code 190) - renew TOK_FB (see README)"
			exit 1
		fi
		pic_url="$(jq -r '.full_picture // empty' 2>/dev/null <<< "${meta}")"
		if [[ -z "${pic_url}" ]]; then
			printf '[i] no full_picture for post %s, rerolling\n' "${post_id}"
			continue
		fi
		curl -fsSL --max-time 60 "${pic_url}" -o "${TMP_IMG}" || {
			printf '[i] download failed for post %s, rerolling\n' "${post_id}"
			continue
		}
		mime="$(file -b --mime-type "${TMP_IMG}" 2>/dev/null || printf 'unknown')"
		case "${mime}" in
			image/jpeg|image/png|image/webp|image/gif) : ;;
			*) printf '[i] not an image (%s) for post %s, rerolling\n' "${mime}" "${post_id}" ; continue ;;
		esac
	fi

	# --- tag it ---
	tags_json="$(python3 scripts/features/booru_tagger.py \
		--image "${TMP_IMG}" \
		--model-dir "${BG_MODEL_DIR}" \
		--model-repo "${BG_MODEL_REPO}" \
		--char-thresh "${BG_CHAR_THRESH}" \
		--gen-thresh "${BG_GEN_THRESH}")" || {
		feature_log 'x' "booru tagger failed (attempt ${attempt})"
		rm -f "${TMP_IMG}"
		exit 1
	}
	filter_cast "${tags_json}" || { feature_log 'x' "could not parse tagger output"; rm -f "${TMP_IMG}"; exit 1; }

	if [[ -n "${CAST_NAMES}" ]]; then
		ok=1
		break
	fi
	printf '[i] no U149 roster character detected (post %s), rerolling\n' "${post_id:-sample}"
done

if (( ok == 0 )); then
	rm -f "${TMP_IMG}"
	feature_log 'S' "no U149 roster character found in ${BG_MAX_ATTEMPTS} candidates - nothing posted"
	exit 3
fi

# --- caption: names only, separated by BG_CAPTION_SEPARATOR ---
caption="${CAST_NAMES//$'\n'/${BG_CAPTION_SEPARATOR}}"

if [[ "${DRY}" = "1" ]]; then
	printf '[DRY] detected cast: %s\n' "${CAST_DETAILS}"
	printf '[DRY] would upload %s with this caption:\n%s\n' "${BG_DRYRUN_SAMPLE}" "${caption}"
	exit 3 # dry run never posts, never marks the archive
fi

[[ -n "${FRMENV_FBTOKEN}" ]] || {
	rm -f "${TMP_IMG}"
	feature_log 'x' "no token (FRMENV_FBTOKEN is empty)"
	exit 1
}

# --- re-upload the image with the cast caption ---
resp="$(curl -s --max-time 120 -w '\n%{http_code}' -X POST \
	--retry 2 --retry-connrefused --retry-delay 7 \
	-F "message=${caption}" \
	-F "source=@${TMP_IMG}" \
	"${FRMENV_API_ORIGIN}/me/photos?access_token=${FRMENV_FBTOKEN}&published=1")"
rm -f "${TMP_IMG}"

status="$(tail -n 1 <<< "${resp}")"
body="$(head -n -1 <<< "${resp}")"

if [[ "${status}" != "200" ]]; then
	error_code="$(jq -r '.error.code // empty' 2>/dev/null <<< "${body}")"
	error_msg="$(jq -r '.error.message // empty' 2>/dev/null <<< "${body}")"
	feature_log 'x' "upload failed (frame=${frame_no} episode=${episode}) http=${status} code=${error_code} msg=${error_msg}"
	case "${error_code}" in
		190) printf '[HINT] error 190: token invalid or expired - regenerate TOK_FB (see README).\n' >&2 ;;
		200) printf '[HINT] error 200: token missing pages_manage_posts permission.\n' >&2 ;;
	esac
	exit 1
fi

new_id="$(jq -r '.id // empty' 2>/dev/null <<< "${body}")"

# --- mark as featured + log ---
printf '%s\n' "${line}" >> "${FEATURE_STATE}/featured.txt"
feature_log '√' "frame=${frame_no} episode=${episode} src_post=${post_id} -> new_post=${new_id} cast=[${CAST_DETAILS}]"

printf '[i] SUCCESS posted: https://facebook.com/%s\n' "${new_id}"
