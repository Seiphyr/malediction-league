# Deploying push-send

This Edge Function delivers the site's notifications to players' phones and
computers (Web Push), also while the site is closed.

The database queues every notification in the table `push_outbox`: a new
round, a player joining your match, a result to confirm, a new event or a
reminder, a board notice. Then it calls this function through `pg_net`
("kick"), and the pg_cron job `sl-push` calls it once a minute for the rest
(notifications queued for later, retries). The function takes up to 40
notifications at a time (`push_claim`, as the service role), encrypts each
one for each of the player's devices, sends it to the browser's push service
(Google, Mozilla, Apple, Microsoft), and reports back (`push_done`). Devices
that no longer exist are removed; busy push services are tried again later.

Nobody's browser calls this function. It needs no CORS and no signed-in
user: the only way in is a shared secret, which the database sends in the
`x-push-secret` header.

## Before you start

You need three values. They are handed over to you **separately**, as
three small text files; they are not in the repository and must never be
committed or pasted anywhere else:

| File | What it is | Goes to |
|---|---|---|
| `public.txt` (87 characters) | VAPID public key: the raw P-256 point `0x04‖X‖Y`, base64url without `=` | function secret `VAPID_PUBLIC_KEY` (the same value is already inside `index.html` as `SL_VAPID_PUB`) |
| `private.txt` (43 characters) | VAPID private key: the 32-byte scalar `d`, base64url without `=` | function secret `VAPID_PRIVATE_KEY` |
| `cron-secret.txt` (43 characters) | the shared secret between the database and the function | Vault secret `sl_push_secret` **and** function secret `PUSH_CRON_SECRET` (the same value in both places) |

The public and private keys are a pair: browsers subscribe with the public
key, and push services accept only messages signed with its private key.
Never generate new keys once players have turned notifications on: every
existing subscription would stop working until each player turns
notifications on again.

Copy each value exactly, with no space or line break before or after it.

## Deploy order

1. **Database > Extensions**: turn on **pg_net** (schema `extensions`).
   pg_cron is already on. Also check that **supabase_vault** is on (it is by
   default).
2. **SQL Editor**: run `migration-2026-11-22-push.sql`. If pg_net is still
   off (or cannot be created), the file stops with the error "pg_net is not
   installed ... Nothing was changed." and changes nothing: turn pg_net on
   (step 1) and run the file again. The check list at its end must then show
   `true` on every row.
3. **SQL Editor**: store the shared secret in Vault (paste the content of
   `cron-secret.txt` between the quotes):

   ```sql
   select vault.create_secret('<content of cron-secret.txt>', 'sl_push_secret', 'push-send shared secret');
   ```

   Optionally, only if the project URL ever changes, also store the
   function's address:

   ```sql
   select vault.create_secret('https://<project>.supabase.co/functions/v1/push-send', 'sl_push_url', 'push-send address');
   ```

   To change the secret later:

   ```sql
   select vault.update_secret((select id from vault.secrets where name = 'sl_push_secret'), '<new secret>');
   ```

   (Fallback only if Vault is not available: `insert into public.push_config(k, v) values ('secret', '<secret>')
   on conflict (k) do update set v = excluded.v;`. Vault is preferred: the
   table keeps the secret as plain text. When both exist, Vault wins.)
4. **This function**: deploy it from the dashboard (below), with **Verify JWT
   OFF**.
5. **Edge Functions > Secrets**: add the four secrets (below).
6. **Test the function** with the curl below: it must answer
   `{"ok":true,"claimed":0,...}`.
7. **Site**: publish `index.html` and `sw.js` as usual.
8. On the site: **Account > Notifications**, tap **Turn on notifications on
   this device**, then **Send a test notification**. Try it on Android
   Chrome, on a desktop browser and on an iPhone from the Home Screen icon.
9. Then delete the three key files. Keep a copy of them only in a password
   manager if you want one.

If the steps are swapped:

- **Site before SQL**: the Notifications pane says "Notifications are not
  available yet"; nothing else changes.
- **SQL before the function** (or a function secret missing): the kicks
  fail quietly, notifications wait in `push_outbox` and expire after their
  time to live (at most 7 days, most of them hours). Nothing is lost on the
  site itself.
- **SQL before pg_net**: the SQL stops with "pg_net is not installed" and
  installs nothing, so the site behaves as in "Site before SQL". Turn pg_net
  on and run the SQL again.
- **Vault secret and `PUSH_CRON_SECRET` differ**, or **Verify JWT is on**:
  every kick gets 401 and nothing is delivered (see how to tell the two apart
  under "How to read them" below).

## Deploy from the dashboard

1. Open the project in the Supabase Dashboard and go to **Edge Functions**.
2. Choose **Deploy a new function** > **Via Editor**.
3. Name it exactly `push-send`.
4. Delete the sample code, paste the whole content of `index.ts` from this
   folder, and click **Deploy function**. It is a single file with no
   imports.
5. Open the function's **Details** (or Settings) and turn **Verify JWT** OFF,
   then save. The database's call carries no user token; the function
   checks the `x-push-secret` header itself.
6. Go to **Edge Functions > Secrets** (Manage secrets) and add:

   | Name | Value |
   |---|---|
   | `VAPID_PUBLIC_KEY` | the content of `public.txt` (87 characters) |
   | `VAPID_PRIVATE_KEY` | the content of `private.txt` (43 characters) |
   | `VAPID_SUBJECT` | `https://seekers-league.com` (optional: this is also the default) |
   | `PUSH_CRON_SECRET` | the content of `cron-secret.txt`, the same value as the Vault secret of step 3 |

   Supabase provides `SUPABASE_URL` and the API keys to every function
   automatically. The function uses the newer secret key
   (`SUPABASE_SECRET_KEYS`) when the runtime provides it, and otherwise the
   legacy `SUPABASE_SERVICE_ROLE_KEY`: `push_claim` and `push_done` can only
   be called with it.

To update it later, open the function, choose **Code**, paste the new
`index.ts` and deploy again. Check that Verify JWT is still off. The secrets
stay.

## Test it

From Git Bash, in the folder that holds `cron-secret.txt` (reading the file
keeps the secret out of your shell history):

```sh
curl -s -X POST "https://mrcciuwekqijitngvojc.supabase.co/functions/v1/push-send?wait=1" \
  -H "x-push-secret: $(cat cron-secret.txt)"
```

Expected answers:

- `{"ok":true,"claimed":0,"sent":0,"retry":0,"failed":0,"gone":0,"ms":...}`:
  working, and nothing was waiting. After a test notification from the site
  you may see `"claimed":1,"sent":1` instead.
- Without `?wait=1`: HTTP 202 `{"ok":true,"started":true}`. This is what the
  database gets: the function answers at once and keeps sending in the
  background (pg_net stops waiting after 8 seconds).
- 401 `{"ok":false,"code":"forbidden"}`: the header does not match
  `PUSH_CRON_SECRET`.
- 401 with another answer, such as `Missing authorization header` or
  `Invalid JWT`: **Verify JWT** is on for the function. The function itself
  never ran (nothing in its Logs): turn Verify JWT off and save.
- 503 `{"ok":false,"code":"not_configured"}`: `PUSH_CRON_SECRET`,
  `VAPID_PUBLIC_KEY` or `VAPID_PRIVATE_KEY` is missing.
- 503 `{"ok":false,"code":"vapid_mismatch"}`: the two VAPID values are not a
  pair, or one was cut when pasting.
- 502 `{"ok":false,"code":"claim_failed",...}`: `push_claim` failed: the
  migration is not run, or the service key is missing (see the Logs).
- 502 `{"ok":false,"code":"done_failed",...}`: `push_done` failed twice in
  a row. Those notifications go out again after their 2-minute lease, so a
  device may show one twice.
- 405 for anything but POST, 413 for a body over 1 KB.

Then check the SQL side in the SQL Editor (read only):

```sql
select kind, created_at, sent_at, attempts, last_error from push_outbox order by id desc limit 20;
select jobname, schedule from cron.job;
select count(*) from push_subscriptions;
select status_code, error_msg, created from net._http_response order by created desc limit 5;
```

How to read them:

- `push_outbox`: `sent_at` set with an empty `last_error` = delivered.
  `last_error` can be `http_429` / `http_5xx` / `timeout` / `net` /
  `deadline` while a retry waits (`attempts` goes up, at most 6), `gave_up:...`
  after the last try, `expired` (its time to live passed before it could be
  sent), `stale:<reason>` (the thing it was about changed before it was
  sent, or the player switched that kind off: this is normal),
  `no_subscription`, `gone` (every device of that player was gone), `host`
  or `bad_keys` (a bad subscription) or `too_big`.
- `cron.job` must show `sl-push` with `* * * * *`.
- `net._http_response` (the answers to the database's kicks, kept for a few
  hours):
  - **202** = working;
  - **401** = one of two things; the `content` column tells them apart
    (`select status_code, content from net._http_response order by created desc limit 5;`):
    - `{"ok":false,"code":"forbidden"}`: the Vault secret `sl_push_secret`
      and the function secret `PUSH_CRON_SECRET` differ;
    - anything else, such as `Missing authorization header` or `Invalid JWT`,
      and no line in the function's Logs: **Verify JWT** is on (a redeploy
      can turn it back on). Turn it off and save;
  - **503** = a function secret is missing (or the VAPID keys are no pair);
  - **404** = the function is not deployed under the name `push-send`;
  - an `error_msg` with no `status_code` = the function did not answer within
    8 seconds or could not be reached (the rows are tried again on the next
    minute).
- If `push_outbox` rows stay unsent, `cron.job` shows `sl-push`, and
  `net._http_response` gets no new rows for several minutes, the pg_net
  worker has stopped. Run:

  ```sql
  select net.worker_restart();
  ```

Also check once that `net` is **not** listed in **Settings > API > Exposed
schemas** (it is not by default), so site visitors can never reach
`net.http_post` through the API.

The function's **Logs** tab shows one line per run, for example
`push-send: run {"claimed":3,"sent":3,"retry":0,"failed":0,"gone":0,"ms":420,"codes":{}}`.
It never logs endpoints, keys, user ids or notification text, only counts
and the short codes listed above.

## Limits

- At most 400 notifications per run, 40 per claim, 8 sent at once. No new
  claim after 30 seconds; a batch still running 60 seconds after its claim
  stops starting new sends and its untried notifications are retried
  (`deadline`). The cron run of the next minute picks up the rest.
- Time budget: in the worst case a claim is reported 91 seconds after it was
  taken (60 s, one 10 s send still running, `push_done` twice with a 10 s
  timeout), inside its 2-minute lease, and a run ends within about 121
  seconds, inside the 150-second limit of the free plan. Keep these numbers
  in step if you change the constants at the top of `index.ts`, or a
  notification can be sent twice.
- Each send times out after 10 seconds and is retried. Redirects are never
  followed.
- A notification is at most 3000 bytes of JSON before encryption; a longer
  text is cut (the body first, then the title) and ends with "…".
- Only the push services of the browsers are ever called:
  `fcm.googleapis.com`, `android.googleapis.com`,
  `updates.push.services.mozilla.com`, `*.push.apple.com`,
  `*.notify.windows.com` (the same list as `push_subscribe`).
- When a player has two devices and one succeeds while the other is busy,
  the notification counts as sent: the busy device misses that one (trying
  again would show it twice on the first).
- Retries back off 1, 2, 4, 8, 16 minutes (or the push service's
  `Retry-After`, up to an hour); after 6 tries the notification is dropped.
