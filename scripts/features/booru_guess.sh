#!/bin/bash
# ############################################ #
#  Feature: booru_guess                         #
# ############################################ #
# 1. Examines BG_MAX_ATTEMPTS random past posts from fb/log.txt, one by
#    one (distinct within a run; featured.txt prevents repeats across runs).
# 2. Downloads each post's image from the Graph API (photos: images[],
#    posts: full_picture).
# 3. Runs each image through the WD14 booru tagger
#    (scripts/features/booru_tagger.py) and classifies the candidate:
#      u149  = at least one U149 roster member detected
#              (scripts/features/booru_roster.conf)
#      side  = no roster member, but some other character is detected
#              (side/extra/guest characters - their names are posted too)
#      none  = no character detected at all (scenery, empty scene, ...)
# 4. Drops the "none" candidates and posts ONE of the remaining ones,
#    drawn at random, with the caption "Frame: N, Episode E" followed by
#    the detected names; "no wife" when no candidate had any character
#    (or set BG_REQUIRE_CHARACTER=1 to skip the run instead of posting).
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
: "${BG_MODEL_DIR:=${HOME}/.cache/wd14-model}"
: "${BG_MODEL_REPO:=SmilingWolf/wd-eva02-large-tagger-v3}"
: "${BG_CHAR_THRESH:=0.55}"
: "${BG_GEN_THRESH:=0.35}"
: "${BG_MAX_ATTEMPTS:=5}"
: "${BG_CAPTION_SEPARATOR:=$'\n'}"
: "${BG_REQUIRE_CHARACTER:=0}"
: "${BG_DRYRUN_SAMPLE:=frames/frame_500.jpg}"
DRY="${FRMENV_DRY_RUN:-0}"

FEATURE_STATE="${SURPRISE_STATE_DIR}/booru_guess"
mkdir -p "${FEATURE_STATE}"

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

# clean_tag <danbooru_tag> -> display name ("yuuki_haru" -> "haru yuuki")
# Side characters have no roster entry, so their tag is cleaned up for the
# caption instead: parenthesized series qualifiers are dropped
# ("takao_(azur_lane)" -> "takao") and underscores become spaces.
clean_tag(){
	local t="$1"
	while [[ "${t}" == *_\(* ]]; do t="${t%_(*}"; done
	printf '%s' "${t//_/ }"
}

# classify_cast <tags_json>
#   Sets CAST_NAMES (newline-joined caption names, best-confidence first),
#   CAST_DETAILS ("name (0.87) ..." for the log) and the counters
#   CAST_U149 / CAST_SIDE. Roster tags are mapped to their caption name;
#   every OTHER detected character counts as a side character and is kept
#   (cleaned up) instead of being dropped. Deduplicates names.
classify_cast(){
	local tags_json="$1" ranked tag conf name
	CAST_NAMES="" ; CAST_DETAILS="" ; CAST_U149=0 ; CAST_SIDE=0
	declare -A SEEN
	ranked="$(jq -r --argjson t "${BG_CHAR_THRESH}" \
		'.characters | to_entries | map(select(.value >= $t)) | sort_by(-.value) | .[] | "\(.key)\t\(.value)"' \
		<<< "${tags_json}" 2>/dev/null)" || return 1
	while IFS=$'\t' read -r tag conf; do
		[[ -n "${tag:-}" ]] || continue
		name="${ROSTER[${tag}]:-}"
		if [[ -n "${name}" ]]; then
			CAST_U149=$(( CAST_U149 + 1 ))
		else
			name="$(clean_tag "${tag}")"
			CAST_SIDE=$(( CAST_SIDE + 1 ))
		fi
		[[ -n "${SEEN[${name}]:-}" ]] && continue
		SEEN["${name}"]="1"
		CAST_NAMES+="${name}"$'\n'
		CAST_DETAILS+="${name} (${conf}) "
	done <<< "${ranked}"
	CAST_NAMES="${CAST_NAMES%$'\n'}"
	return 0
}

# cast_class_from_counts -> u149 | side | none
cast_class_from_counts(){
	if (( CAST_U149 > 0 )); then printf 'u149'
	elif (( CAST_SIDE > 0 )); then printf 'side'
	else printf 'none'
	fi
}

# caption block + log note from the last classify_cast run
build_caption_block(){
	if [[ -n "${CAST_NAMES}" ]]; then
		CAST_BLOCK="${CAST_NAMES}"
		CAST_NOTE="${CAST_DETAILS}"
	else
		CAST_BLOCK="no wife"
		CAST_NOTE="none - posted as no wife"
	fi
}

# remove every candidate image still lying around
cleanup_imgs(){
	local f
	for f in "${FEATURE_STATE}"/.candidate*.img; do
		[[ -e "${f}" ]] && rm -f "${f}"
	done
}

run_tagger(){  # <image>; tagger JSON on stdout
	python3 scripts/features/booru_tagger.py \
		--image "$1" \
		--model-dir "${BG_MODEL_DIR}" \
		--model-repo "${BG_MODEL_REPO}" \
		--char-thresh "${BG_CHAR_THRESH}" \
		--gen-thresh "${BG_GEN_THRESH}"
}

# --- dry run: exercise the whole tagging pipeline on a repo sample ---
if [[ "${DRY}" = "1" ]]; then
	IMG="${FEATURE_STATE}/.candidate.img"
	cp -f "${BG_DRYRUN_SAMPLE}" "${IMG}" || {
		printf '[FATAL] dry-run sample missing: %s\n' "${BG_DRYRUN_SAMPLE}" >&2
		exit 1
	}
	tags_json="$(run_tagger "${IMG}")" || {
		feature_log 'x' "booru tagger failed (dry run)"
		rm -f "${IMG}"
		exit 1
	}
	classify_cast "${tags_json}" || {
		feature_log 'x' "could not parse tagger output (dry run)"
		rm -f "${IMG}"
		exit 1
	}
	build_caption_block
	caption="Frame: ?, Episode ?${BG_CAPTION_SEPARATOR}${CAST_BLOCK//$'\n'/${BG_CAPTION_SEPARATOR}}"
	printf '[DRY] sample classified: %s (u149 hits: %s, side hits: %s)\n' \
		"$(cast_class_from_counts)" "${CAST_U149}" "${CAST_SIDE}"
	printf '[DRY] detected cast: %s\n' "${CAST_NOTE}"
	printf '[DRY] would upload %s with this caption:\n%s\n' "${BG_DRYRUN_SAMPLE}" "${caption}"
	rm -f "${IMG}"
	exit 3 # dry run never posts, never marks the archive
fi

# --- examine candidates one by one, classify, keep the ones with people ---
# every candidate gets its own slot (image + tags + metadata) so the
# winner's image is still around after the selection below
declare -A CAND_LINE CAND_FRAME CAND_EP CAND_POST CAND_TAGS CAND_IMG CAND_CLASS
slot=0
evaluated=0
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

	img_slot="${FEATURE_STATE}/.candidate_${slot}.img"

	# fetch the original image of the picked post.
	# NOTE: fb/log.txt stores PHOTO ids (main.sh logs the id returned by
	# the photos endpoint), so try the photo-shaped query first. The
	# Graph API validates every requested field against the node type
	# and rejects the whole call with error 100 ("nonexisting field")
	# when even one field is missing - photo nodes have `images`, post
	# nodes have `full_picture`, and no node has both. So: ask for
	# `images`; on error 100 retry with `full_picture`; reroll only if
	# both fail. Any API error is printed before rerolling instead of
	# being swallowed silently.
	meta="$(curl -s --max-time 30 \
		"${FRMENV_API_ORIGIN}/${SURPRISE_FBAPI_VER}/${post_id}?fields=images&access_token=${FRMENV_FBTOKEN}")"
	err_code="$(jq -r '.error.code // empty' 2>/dev/null <<< "${meta}")"
	if [[ "${err_code}" = "190" ]]; then
		cleanup_imgs
		feature_log 'x' "token expired or invalid (code 190) - renew TOK_FB (see README)"
		exit 1
	fi
	pic_url=""
	if [[ -z "${err_code}" ]]; then
		pic_url="$(jq -r '[.images[]? | {s: .source, w: (.width // 0)}] | if length > 0 then (sort_by(-.w)[0].s // empty) else empty end' \
			2>/dev/null <<< "${meta}")"
	fi
	if [[ -z "${pic_url}" && "${err_code}" = "100" ]]; then
		# the node has no `images` field -> it is a post-like node
		printf '[i] no images field on %s (post-like node), trying full_picture\n' "${post_id}"
		meta="$(curl -s --max-time 30 \
			"${FRMENV_API_ORIGIN}/${SURPRISE_FBAPI_VER}/${post_id}?fields=full_picture&access_token=${FRMENV_FBTOKEN}")"
		err_code="$(jq -r '.error.code // empty' 2>/dev/null <<< "${meta}")"
		if [[ "${err_code}" = "190" ]]; then
			cleanup_imgs
			feature_log 'x' "token expired or invalid (code 190) - renew TOK_FB (see README)"
			exit 1
		fi
		if [[ -z "${err_code}" ]]; then
			pic_url="$(jq -r '.full_picture // empty' 2>/dev/null <<< "${meta}")"
		fi
	fi
	if [[ -z "${pic_url}" ]]; then
		if [[ -n "${err_code}" ]]; then
			printf '[i] api error %s for %s: %s, rerolling\n' "${err_code}" "${post_id}" \
				"$(jq -r '.error.message // empty' 2>/dev/null <<< "${meta}")"
		else
			printf '[i] no usable image for post %s (no images[] and no full_picture), rerolling\n' "${post_id}"
		fi
		continue
	fi
	curl -fsSL --max-time 60 "${pic_url}" -o "${img_slot}" || {
		printf '[i] download failed for post %s, rerolling\n' "${post_id}"
		continue
	}
	mime="$(file -b --mime-type "${img_slot}" 2>/dev/null || printf 'unknown')"
	case "${mime}" in
		image/jpeg|image/png|image/webp|image/gif) : ;;
		*) printf '[i] not an image (%s) for post %s, rerolling\n' "${mime}" "${post_id}" ; continue ;;
	esac

	# --- tag + classify this candidate ---
	tags_json="$(run_tagger "${img_slot}")" || {
		cleanup_imgs
		feature_log 'x' "booru tagger failed (attempt ${attempt})"
		exit 1
	}
	classify_cast "${tags_json}" || {
		cleanup_imgs
		feature_log 'x' "could not parse tagger output"
		exit 1
	}
	cast_class="$(cast_class_from_counts)"
	printf '[i] candidate %s/%s: class=%s (u149=%s, side=%s) %s\n' \
		"${attempt}" "${BG_MAX_ATTEMPTS}" "${cast_class}" "${CAST_U149}" "${CAST_SIDE}" "${CAST_DETAILS}"

	CAND_LINE[${slot}]="${line}"
	CAND_FRAME[${slot}]="${frame_no:-?}"
	CAND_EP[${slot}]="${episode:-?}"
	CAND_POST[${slot}]="${post_id}"
	CAND_TAGS[${slot}]="${tags_json}"
	CAND_IMG[${slot}]="${img_slot}"
	CAND_CLASS[${slot}]="${cast_class}"
	slot=$(( slot + 1 ))
	evaluated=$(( evaluated + 1 ))
done

if (( evaluated == 0 )); then
	cleanup_imgs
	feature_log 'S' "could not load a taggable image in ${BG_MAX_ATTEMPTS} attempts - nothing posted"
	exit 3
fi

# --- selection: keep candidates with people, drop the rest, pick one ---
pool=()
for ((s = 0; s < slot; s++)); do
	[[ "${CAND_CLASS[${s}]}" != "none" ]] && pool+=( "${s}" )
done

if (( ${#pool[@]} == 0 )); then
	# none of the examined candidates contained any character at all
	if [[ "${BG_REQUIRE_CHARACTER}" = "1" ]]; then
		cleanup_imgs
		feature_log 'S' "none of ${evaluated} candidates contained a character (BG_REQUIRE_CHARACTER=1) - nothing posted"
		exit 3
	fi
	printf '[i] none of %s candidates contained a character - posting one anyway (set BG_REQUIRE_CHARACTER=1 to skip instead)\n' "${evaluated}"
	for ((s = 0; s < slot; s++)); do pool+=( "${s}" ); done
fi

pick="${pool[RANDOM % ${#pool[@]}]}"
line="${CAND_LINE[${pick}]}"
frame_no="${CAND_FRAME[${pick}]}"
episode="${CAND_EP[${pick}]}"
post_id="${CAND_POST[${pick}]}"

# rebuild the name list from the winner's tags
classify_cast "${CAND_TAGS[${pick}]}" || {
	cleanup_imgs
	feature_log 'x' "could not parse tagger output"
	exit 1
}
build_caption_block
printf '[i] selected candidate %s of %s (class=%s)\n' "$(( pick + 1 ))" "${evaluated}" "${CAND_CLASS[${pick}]}"

# --- caption: "Frame: N, Episode E" + detected names (or "no wife") ---
caption="Frame: ${frame_no}, Episode ${episode}${BG_CAPTION_SEPARATOR}${CAST_BLOCK//$'\n'/${BG_CAPTION_SEPARATOR}}"

[[ -n "${FRMENV_FBTOKEN}" ]] || {
	cleanup_imgs
	feature_log 'x' "no token (FRMENV_FBTOKEN is empty)"
	exit 1
}

# --- re-upload the image with the cast caption ---
resp="$(curl -s --max-time 120 -w '\n%{http_code}' -X POST \
	--retry 2 --retry-connrefused --retry-delay 7 \
	-F "message=${caption}" \
	-F "source=@${CAND_IMG[${pick}]}" \
	"${FRMENV_API_ORIGIN}/me/photos?access_token=${FRMENV_FBTOKEN}&published=1")"
cleanup_imgs

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
feature_log '√' "frame=${frame_no} episode=${episode} src_post=${post_id} -> new_post=${new_id} class=${CAND_CLASS[${pick}]} cast=[${CAST_NOTE}]"

printf '[i] SUCCESS posted: https://facebook.com/%s\n' "${new_id}"
