# Deploying admin-accounts

This Edge Function is behind **Admin > Accounts** on the site. A site admin
makes simple accounts there that skip email confirmation: for testing, for
demos and for the Google Play reviewers. From the same tab the admin can
reset such an account's password, turn its demo flag on or off and delete
it. Only accounts made there can be changed there, and never a site admin's
account.

- **Create**: the login is made already confirmed, with a strong password
  made by the function. The password is shown once on the page and is never
  stored or logged. The profile is made by the database exactly as for a
  sign-up, so the first sign-in needs nothing more.
- **Demo accounts** (on by default) are left out of the public numbers: the
  Home counters, the Meta (global and community), deck records, public deck
  popularity and copies, and the "N players" on Explore. Everything else
  works as for any account, so a reviewer sees the real site.
- **Reset password** gives a new password (shown once) and signs the account
  out everywhere (every session and refresh token is removed), so whoever
  knew the old password loses access. Tokens already handed out expire within
  the hour.
- **Delete** erases the account exactly as the site's own **Delete account**
  does (`erase_user_data`, then the login, run as that account), in one
  transaction, and blanks the email and note kept for it. An account that
  still owns a community with players is refused, as Delete account refuses
  it. A deleted demo account's old games stay out of the numbers.
- Reset password, and turning Demo on, are refused for an account that also
  signs in with Google or Discord (a real person may have claimed that
  address).
- At most 30 new accounts per admin in 24 hours, enforced in the database
  under a lock, so requests sent at the same moment cannot go past it.

The page calls it with the signed-in admin's token. The function checks the
token (`auth.getUser`) and then that the user is in `site_admins` (read with
the service role); anyone else gets 401 or 403 with no detail. Browsers may
call it only from `https://seekers-league.com`. (For local test pages,
`http://127.0.0.1` and `http://localhost` are allowed only when the secret
`ADMIN_ACCOUNTS_ALLOW_LOCAL` is `1`; do not set it on the live project.)

## Before you start

Run `migration-2026-11-29-admin-accounts.sql` in Supabase Dashboard > SQL
Editor. It adds the tables `admin_accounts` and `admin_account_slots`
(service role only), the helpers `is_demo_user()` and `demo_keys()`, the
service-role functions the tab needs (`admin_accounts_list`,
`admin_account_take_slot`, `admin_account_free_slot`, `admin_account_state`,
`admin_account_set_demo`, `admin_account_signout`, `admin_account_erase`), the
demo exclusions in `site_counts()`, `meta_duels()` and `public_leagues`, and
`public_leagues.roster_count`. The rows at the end must all say `ok = true`.
Until an account is marked demo, every number stays exactly as before.

## Deploy order

Any order works:

1. **SQL**: `migration-2026-11-29-admin-accounts.sql`.
2. **This function**: from the dashboard (below).
3. **Site**: push `index.html`.

If the site goes first, Admin > Accounts says "Deploy the admin-accounts
function first". If the function goes before the SQL, it answers "Run
migration-2026-11-29-admin-accounts.sql first" and makes nothing.

## Deploy from the dashboard

1. Open the project in the Supabase Dashboard and go to **Edge Functions**.
2. Choose **Deploy a new function** > **Via Editor**.
3. Name it exactly `admin-accounts`.
4. Delete the sample code, paste the whole content of `index.ts` from this
   folder, and click **Deploy function**.
5. Open the function's **Details** (or Settings) and turn **Verify JWT** OFF,
   then save. The code checks the user and `site_admins` itself; with Verify
   JWT on, the browser's preflight request (which carries no token) is
   refused and the page says "Deploy the admin-accounts function first".
6. No secrets are needed. Supabase provides `SUPABASE_URL` and the API keys
   to every function automatically. The function uses the newer keys
   (`SUPABASE_PUBLISHABLE_KEYS`, `SUPABASE_SECRET_KEYS`) when the runtime
   provides them, and otherwise the legacy `SUPABASE_ANON_KEY` and
   `SUPABASE_SERVICE_ROLE_KEY`. It needs the secret (service role) key.

From the command line instead (Supabase CLI, in the repository folder):

```sh
supabase functions deploy admin-accounts --project-ref mrcciuwekqijitngvojc --no-verify-jwt
```

To update it later, open the function, choose **Code**, paste the new
`index.ts` and deploy again. Check that Verify JWT is still off.

Leave **Authentication > Sign In / Providers > Confirm email** as it is: it
still applies to everyone who signs up on the site. Only accounts made here
skip it.

## Test it

On the site, signed in as a site admin: **Admin > Accounts**. The list
should load ("No accounts made here yet.", "0 of 30 made in the last 24
hours"). From the browser console:

```js
const { data, error } = await sb.functions.invoke("admin-accounts", { body: { action: "list" } });
console.log(data, error);
```

Expected: `{ ok: true, accounts: [], made_24h: 0, max_24h: 30 }`. Then make
an account in the tab, copy its password and sign in with it in a private
window.

Notes the tab can show:

- "Deploy the admin-accounts function first": the function is missing, has
  another name, or Verify JWT is on.
- "Run migration-2026-11-29-admin-accounts.sql first": the SQL has not run.
- "Only site admins can manage accounts. Sign in again if you are one.": the
  session expired or the account is not in `site_admins`; sign out and in
  again.

Answers (always JSON):

- `{ ok: true, ... }`: done. `create` and `reset_password` include the
  password, once; `reset_password` also says `signed_out`.
- `{ ok: false, code, message }` with HTTP 200: refused, with a fixed
  English message: `bad_email`, `bad_name`, `bad_note`, `email_taken`,
  `rate_limited`, `password_rule` (the project's password requirements
  refused the generated password), `not_found` (not made here), `deleted`,
  `is_admin`, `other_login`, `owns_community`, `not_ready` (the SQL has not
  run), `error`.
- 401 `unauthorized` (no token, a bad one, a guest), 403 `forbidden` (not a
  site admin, or a page on another site), 405, 413, 400, 503
  `not_configured` (a key is missing), 500 `error`.

The Logs show only the action, the step and a short error code, never
emails, names, notes, passwords, tokens or user ids.

## Notes

- Passwords: 16 characters from 56 that cannot be mistaken for each other
  (no 0 O o 1 l I), drawn with `crypto.getRandomValues`, written
  `xxxx-xxxx-xxxx-xxxx` (about 93 bits). Each has an upper case letter, a
  lower case letter, a digit and hyphens, so it passes any Supabase password
  requirement and the site's 8-character minimum.
- If the project does not let the database touch the auth tables, a reset
  still works but cannot sign out open sessions: the panel says so, and
  Delete is then the way to cut access.
- A deleted account's row stays in `admin_accounts` (marked deleted, email
  and note blanked, with the keys its tournament entries got), so a deleted
  demo account's old games stay out of the public numbers.
- `demo_keys()` is readable by anyone (the page needs it to filter the
  Meta): it tells which accounts are demo accounts, nothing more.
- `www.seekers-league.com` is not an allowed origin (the site is not served
  from it). Add it to `PROD_ORIGIN` handling in `index.ts` if that changes.
