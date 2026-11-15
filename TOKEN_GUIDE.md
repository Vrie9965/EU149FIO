# Facebook Token Guide — stop renewing `TOK_FB` every 60 days

If you've been regenerating a token every ~2 months for years: that's the
**extended user token** (60 days, no auto-renew — Meta never documented a
way to keep it alive). There are two ways to stop doing that. Pick ONE:

| Method | What you get | Effort |
|---|---|---|
| **A. Page access token** *(recommended)* | A token that **never expires** | One-time, ~5 minutes |
| **B. Refresh the 60-day token monthly** | A fresh 60 days each time | Manual, once a month |

Method A is all this bot actually needs: it only posts *as the Page*, and
a Page token minted from a long-lived user token has **no expiration
date** (documented Graph API behavior).

---

## Method A — never-expiring Page token (recommended, one-time)

You need: the Facebook account that is **admin of the Page**, and your
`APP_ID` + `APP_SECRET` (from <https://developers.facebook.com/apps/> →
your app → **Settings → Basic**).

### Step 1 — short-lived user token

1. Open the [Graph API Explorer](https://developers.facebook.com/tools/explorer/).
2. In the **Application** dropdown (top right), pick **your app** — not
   the default "Graph API Explorer" app, or the exchange in step 2 will
   fail with a `client_id` mismatch.
3. In **Permissions**, add exactly:
   - `pages_show_list`
   - `pages_read_engagement`
   - `pages_manage_posts`
4. Click **Generate Access Token** and approve the popup (it asks which
   Page you act for — allow yours). Copy the token (starts with `EAAG…`).
   It is valid only ~1–2 hours; that's fine, step 2 consumes it right away.

### Step 2 — exchange for a 60-day user token

Paste your short-lived token into this URL and open it (or `curl` it),
replacing `APP_ID`, `APP_SECRET`, `SHORT_TOKEN`:

```bash
curl -s "https://graph.facebook.com/v21.0/oauth/access_token\
?grant_type=fb_exchange_token&client_id=APP_ID\
&client_secret=APP_SECRET&fb_exchange_token=SHORT_TOKEN"
```

The `access_token` in the JSON answer is your **long-lived user token**
(~60 days). Copy it.

⚠️ This URL contains your **app secret** — treat it like a password.
Never paste the full URL into issues, screenshots, or chat. (Any current
Graph version works; `v21.0` is used here.)

### Step 3 — trade the 60-day user token for a Page token

```bash
curl -s "https://graph.facebook.com/v21.0/me/accounts?access_token=LONG_LIVED_USER_TOKEN"
```

Find your Page in the list and copy its `access_token`. Single-Page
account? This is equivalent:

```
https://graph.facebook.com/v21.0/PAGE_ID?fields=access_token&access_token=LONG_LIVED_USER_TOKEN
```

This Page token is the permanent one. **The step-2 exchange is what makes
it permanent**: a Page token minted from a *short-lived* user token
inherits that short expiry, one minted from a *long-lived* user token
never expires.

### Step 4 — verify in the debugger

Open the [Access Token Debugger](https://developers.facebook.com/tools/debug/accesstoken/)
and paste the Page token. Check:

- **Expires** → must say **Never**
- **Scopes** → must list `pages_manage_posts`, `pages_read_engagement`,
  `pages_show_list`
- Sanity check that it acts as the Page:

```bash
curl -s "https://graph.facebook.com/v21.0/me?access_token=PAGE_TOKEN"
# must return the PAGE's id and name — not your personal profile
```

### Step 5 — store it

Repo → **Settings → Secrets and variables → Actions** → update `TOK_FB`
with the Page token. Done. You never repeat this unless the token gets
invalidated (see below).

---

## Method B — keep the 60-day token, refresh it monthly

An *unexpired* long-lived user token can be exchanged for a fresh one by
re-running the exact same URL from step 2 with the current token as
`fb_exchange_token` — you get a new ~60-day token. Check it in the
debugger, update `TOK_FB`, set a monthly calendar reminder. That's the
whole routine you've been doing for 3 years, minus the "generate from
scratch" part.

(A CI job can't fully automate this: writing the new token back into
Actions Secrets would require handing CI an admin credential, which is
worse than a one-minute manual refresh.)

If you also use the optional `TOK_GIF` secret, it's the same kind of
Facebook access token — refresh it the same way.

---

## What kills a "never expires" token

Still permanent until one of these happens:

- The admin removes the app / revokes its permissions
  (**Facebook → Settings → Apps and Websites / Business Integrations**)
- That admin **loses their Page role**
- A security reset on the account (password change, "log out everywhere"
  — can invalidate issued tokens)

Symptom: workflow logs show an `OAuthException` / "access token" error
where posts used to succeed. Fix: redo Method A (2 minutes), update
`TOK_FB`.

## Security notes (public repo, private secrets)

- `TOK_FB` lives in **GitHub Actions Secrets**: encrypted server-side,
  masked as `***` if it ever appears in logs, and **not** exposed to
  pull requests from forks. A public repo cannot leak it.
- A leaked Page token can only act **as the Page** (post, comment, read
  the Page's own content with the three scopes above). It cannot touch
  your personal profile, friends, or messages.
- If a token ever *does* leak (e.g. you pasted it somewhere public):
  **Facebook → Settings → Apps and Websites → remove the app** — that
  kills every token the app issued — then redo Method A. Rotate the app
  secret too if you're being careful.
- The app secret is used only in the step-2 exchange URL. It is never
  stored in this repo; the workflows only read the finished `TOK_FB`.
