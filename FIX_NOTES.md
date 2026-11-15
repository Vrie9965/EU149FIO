# Surprise pack v3.1 — Graph API field-validation fix

## Why the last run failed (and what went right)

The good news first: pack v3 IS live now — the log shows
`[i] surprise runner choice: booru_guess (manually selected)` — and the
skip = red semantics you asked for worked: the run failed with exit 3
instead of pretending success. Because the failure is now loud, the real
error finally surfaced:

```
[i] api error 100 for 122271849128200694:
    (#100) Tried accessing nonexisting field (full_picture), rerolling
```

The Graph API validates every requested field against the node type and
rejects the WHOLE call with error 100 if even one field does not exist on
that node. Photo nodes have `images`, post nodes have `full_picture`, and
no node has both — so v3's single call `?fields=images,full_picture` is
invalid on every node type. v3.1 uses a fallback chain instead:

1. `?fields=images` — photo nodes (the normal case: fb/log.txt stores
   photo ids, so this succeeds on the first call)
2. on error 100 → `?fields=full_picture` — post-like nodes
3. both fail → reroll with the printed reason

The patch applies cleanly on your current master (`9da3360`). Note: your
repo still contains the old files — `.github/workflows/reshare.yml` (the
old 6x/day reshare is STILL RUNNING), `scripts/reshare_random.sh`,
`scripts/feature_runner.sh`, `scripts/features/registry.conf` — the patch
deletes them; if you apply by web UI, do the deletions this time.

## History: how the pack got here

## Proof: what your last-but-one run actually executed

Your run log shows `Run bash scripts/feature_runner.sh` and
`[i] no full_picture for post ..., rerolling` — those are the **original
pre-fix messages**. A fresh clone of your master (`8da263c`) confirms it:

| File | In your repo now | What it should be |
|---|---|---|
| `scripts/features/booru_guess.sh` | ORIGINAL (fetch bug still live) | pack v3 |
| `scripts/features/random_reshare.sh` | ORIGINAL (`Random frame. [√] …`) | pack v3 |
| `.github/workflows/surprise.yml` | OLD (calls `feature_runner.sh`) | pack v3 |
| `scripts/surprise_runner.sh` | **MISSING** | ADD from pack |
| `.github/workflows/reshare.yml` | **STILL LIVE** (6x/day reshare) | DELETE |
| `scripts/reshare_random.sh` | still there | DELETE |

So the booru character detector never ran and could never run: the
pipeline died at the download step, using the old fetch that photo IDs
can never satisfy. Nothing after it (scan → caption → upload) was reached.

## Two ways to apply

**Option A — one patch (recommended, needs git or GitHub Desktop):**
in your local clone of the repo:

```
git apply surprise_v3.patch     # from this pack
git add -A && git commit -m "apply surprise v3" && git push
```

The patch was verified with `git apply --check` against your current
master — it replaces `surprise.yml`, `booru_guess.sh`, `random_reshare.sh`,
adds `surprise_runner.sh`, and deletes `reshare.yml`, `reshare_random.sh`,
plus the now-unused `feature_runner.sh` and `registry.conf`.

**Option B — web UI, file by file (same end result):**
If you already applied v3 (your runner/workflow/reshare files match the
pack), v3.1 only needs: REPLACE `scripts/features/booru_guess.sh` and do
the DELETEs below. For a fresh repo, all of:
1. ADD `scripts/surprise_runner.sh`
2. REPLACE `.github/workflows/surprise.yml`
3. REPLACE `scripts/features/booru_guess.sh`
4. REPLACE `scripts/features/random_reshare.sh`
5. DELETE `.github/workflows/reshare.yml` (old 6x/day reshare!)
6. DELETE `scripts/reshare_random.sh`
(+ optional DELETE `scripts/feature_runner.sh`, `scripts/features/registry.conf`)

## Verify before trusting it (IMPORTANT)

1. After applying: **Actions → surprise runner → Run workflow**,
   dry_run **checked**. The log MUST start with:
   `[i] surprise runner choice: booru_guess (manually selected)`
   If you still see `[i] feature runner picked:` the new files are NOT
   live — stop and re-do the apply (this is exactly the tell that was
   missed last time).
2. Then run dry_run **unchecked**:
   - success looks like `[i] SUCCESS posted: https://facebook.com/...`
   - nothing posted now = **RED run on purpose** (you asked for this) —
     the reason is in the summary and `fb/surprise/booru_guess.log`
3. First real run downloads the WD14 model (~560 MB, one time, then
   cached by the workflow).

## What changed in v3.1

- **Fetch is a fallback chain:** `?fields=images` first; on Graph error
  100 ("nonexisting field") → `?fields=full_picture`; reroll only if both
  fail, printing the reason. Needed because the Graph API validates every
  requested field against the node type and rejects the whole call when
  one field is missing — no node has both `images` and `full_picture`.
  (This replaces v3's single combined call, which error 100 rejected on
  every node type.)
- **Skip = red:** if a real slot posts nothing, the runner exits 3 → the
  Actions run shows FAILED, so quiet slots are never mistaken for success.
  Dry runs stay green.
- Everything else from v2 unchanged: manual dropdown (`booru_guess`
  default / `random_reshare` / `auto`), 2x/day auto schedule (6am & 6pm
  JST), captions (`Frame: N, Episode E` + names, or `no wife`), page-token
  check fix, run summary on the Actions page.

## Your pipeline, step by step (as implemented)

1. Run the bot → `surprise.yml` → `scripts/surprise_runner.sh`
2. Download a FB image → `/{id}?fields=images,full_picture` → curl to tmp
3. Run booru scanner → `booru_tagger.py` (WD14) on the downloaded file
4. Detect characters + save text → `filter_cast` vs `booru_roster.conf`,
   state written under `fb/surprise/`
5. New post with detected characters as caption → `/me/photos` upload;
   caption = `Frame: N, Episode E` + names, or `no wife`
6. Cleanup → tmp image removed; `fb/surprise` state committed (the
   "surprise: feature state update" commit)
7. Finish → run summary: posted / skipped / failed (nothing posted = red)

## Test evidence (mock Graph API harness, 13 scenarios + lint, all pass)

| # | Scenario | Result |
|---|---|---|
| T1 | booru_guess with cast | caption `Frame: N, Episode E` + name, archive marked |
| T2 | no cast detected | posts anyway with `no wife` |
| T3 | expired token (190) | exit 1, logged |
| T4 | candidate without images[] or full_picture | exit 3, visible reroll reason |
| T4b | post-like candidate | full_picture fallback posts fine |
| T5 | reshare, page token | caption exactly `Frame: N, Episode E`, no false WARN |
| T6 | reshare, token missing page | WARN shown, still attempts |
| T7/T8 | runner explicit choice | runs exactly the chosen feature |
| T9 | runner auto x3 | 50/50 pool + anti-repeat works |
| T10 | bogus choice | exit 1 with clear error |
| T11 | skip (nothing posted) | **exit 3 → red run**, summary `skipped` |
| T11b | dry-run skip | exit 0 → green (a dry run never fails) |
| T12 | real failure | exit 1 → red run, summary `failed` |
