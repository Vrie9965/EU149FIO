# Surprise Features

A small, modular event system for the page: **twice a day** (6am & 6pm JST)
a runner picks **one feature at random** from a registry and lets it post.
The frame-posting engine (`main.sh` / `config.conf`) is untouched — this
system is fully separate and only reads the page's posting history.

```
.github/workflows/surprise.yml        cron "0 9,21 * * *" (= 06:00/18:00 JST)
        │
        ▼
scripts/feature_runner.sh             picks ONE feature from the registry
        │   sources surprise.conf
        ▼
scripts/features/registry.conf        the feature list (pipe-separated)
        │
        ├── scripts/features/booru_guess.sh      feature: booru tagger guess
        │       └── booru_tagger.py (WD14 ONNX)  + booru_roster.conf (cast map)
        └── scripts/features/random_reshare.sh   feature: random old-frame reshare

fb/surprise/                          all logs & state, committed back by CI
```

## The registry

`scripts/features/registry.conf`, one feature per line:

```
feature_id|enabled|weight|description
booru_guess|1|1|Download a random past frame, detect the U149 cast...
random_reshare|1|1|Reshare a random old frame post...
```

- `enabled`: `1` = eligible, `0` = temporarily retired.
- `weight`: positive integer. Weight `2` is picked twice as often as `1`.
  Keep everything at `1` for a uniform lottery.
- The runner avoids running the same feature twice in a row (one reroll,
  see `RUNNER_AVOID_REPEAT` in `surprise.conf`).

**Adding a feature later**: write `scripts/features/<id>.sh` following the
contract below, then add one line to the registry. Nothing else changes.

## Feature contract

Every feature script:

- is executed from the repo root with the environment already populated
  (`FRMENV_FBTOKEN`, `FRMENV_API_ORIGIN`, `SURPRISE_*`, `BG_*`, …);
- posts to Facebook itself (via `curl` + Graph API);
- appends its own history to `fb/surprise/<feature_id>.log` using
  `feature_log` from `scripts/features/lib.sh`;
- keeps its "already used" state under `fb/surprise/<feature_id>/`;
- exits `0` when it posted, `1` on error, `3` when it deliberately skipped
  (runner treats `3` as "nothing posted this slot" and stays green);
- never touches the frame engine or other features' state.

Shared helpers live in `scripts/features/lib.sh` (dependency check, logging,
and `pick_candidate` — a random-line picker with exact-match no-repeat
exclusion that automatically restarts the tour once the archive is used up).

## Configuration

All knobs live in **`surprise.conf`** (repo root) — see the comments there.
Env vars set before calling the runner (e.g. from CI) pass through to
features; secrets like the Facebook token are **not** stored here.

## Local testing (no token needed)

```bash
# full pipeline dry-run: picks a feature, tags the sample image, prints
# what WOULD be posted. Nothing touches Facebook, nothing marks state.
FRMENV_DRY_RUN=1 bash scripts/feature_runner.sh

# tagger directly on any image:
python3 scripts/features/booru_tagger.py --image frame_1974.jpg \
    --model-dir fb/surprise/.model \
    --model-repo SmilingWolf/wd-eva02-large-tagger-v3
```

The first tagger run downloads the model (~1.3 GB for the default
`wd-eva02-large-tagger-v3`) into `fb/surprise/.model/` (git-ignored).
CI caches it between runs.

## CI notes (`.github/workflows/surprise.yml`)

- GitHub cron is **UTC**. The workflow uses `0 9,21 * * *` = **18:00 / 06:00
  Asia/Tokyo (JST)**. Shift the two hour numbers if your audience lives
  elsewhere (`local = UTC + offset`). Scheduled runs can drift a few minutes
  past the hour — normal for GitHub Actions.
- Required secret: `TOK_FB` (same one the frame engine uses; needs
  `pages_manage_posts`, `pages_read_engagement`, `pages_show_list`).
- After every run the workflow commits `fb/surprise/**` back (featured
  lists, logs) so nothing ever repeats across runs.
- `workflow_dispatch` has a **dry_run** boolean input — trigger it manually
  first to smoke-test the whole pipeline without posting.

## Removed / replaced

- `scripts/reshare_random.sh` → replaced by `scripts/features/random_reshare.sh`
  (same output format, no hardcoded page id, no-repeat tour of the archive).
- `.github/workflows/reshare.yml` → replaced by `surprise.yml`; the reshare
  now happens only when the runner picks it.
