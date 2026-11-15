# Surprise pack v3 — the previous pack never reached your repo

## Proof: what your last run actually executed

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

## What changed in v3

- **Fetch is one API call:** `/{id}?fields=images,full_picture` — photo
  nodes answer `images[]` (largest picked), post nodes answer
  `full_picture`. No node-type guessing at all; if neither exists the
  reroll reason is printed. (This replaces the v1 metadata=1 approach and
  works whatever fb/log.txt stores.)
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
