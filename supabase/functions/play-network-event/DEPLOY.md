# Deploying play-network-event

This Edge Function reads an official Play Network event page on
malediction.gg and saves the event as a listing of a community
(table `pn_events`). Only organizers of a community can call it.

## Before you start

Run `migration-2026-11-08-communities.sql` in Supabase Dashboard > SQL Editor.
The function needs the `pn_events` table and the `pn_fetch_allow()` function
from that migration. The check query at the end of the migration should show
`ok = true` on every row.

## Deploy from the dashboard

1. Open the project in the Supabase Dashboard and go to **Edge Functions**.
2. Choose **Deploy a new function** > **Via Editor**.
3. Name it exactly `play-network-event`.
4. Delete the sample code, paste the whole content of `index.ts` from this
   folder, and click **Deploy function**.
5. Open the function's **Details** (or Settings) and turn **Verify JWT** OFF,
   then save. The code checks the signed-in user itself (this also keeps
   working with the newer API keys).
6. No secrets are needed. Supabase provides `SUPABASE_URL` and the API keys
   to every function automatically. The function uses the newer keys
   (`SUPABASE_PUBLISHABLE_KEYS`, `SUPABASE_SECRET_KEYS`) when the runtime
   provides them, and otherwise the legacy `SUPABASE_ANON_KEY` and
   `SUPABASE_SERVICE_ROLE_KEY`. If neither is available (for example the
   legacy keys were turned off and the newer ones are not passed to
   functions), every call answers `not_allowed` and the site falls back to
   typing the event in by hand: check the function's Logs and the
   project's API keys settings.

To update it later, open the function, choose **Code**, paste the new
`index.ts` and deploy again. Check that Verify JWT is still off.

## Test it

On the site, signed in as an organizer of a community that is not archived:
open the community, add an event, and paste an official link, for example
`https://malediction.gg/play-network/events/single/393/torneo-un-friendly-la-tana-dellotaku/`.
The listing should appear with its title, date, venue and number of players.

From the browser console on the site (signed in), you can also call it
directly:

```js
const { data, error } = await sb.functions.invoke("play-network-event", {
  body: { league_id: "<community id>", url: "https://malediction.gg/play-network/events/single/393/torneo-un-friendly-la-tana-dellotaku/" },
});
console.log(data, error);
```

Expected answers:

- `{ ok: true, event: {...} }`: the listing was saved (`fetch_ok: true`).
- `{ ok: false, error: "not_allowed", ... }`: you are signed out, or not an
  organizer of that community.
- `{ ok: false, error: "bad_url", ... }`: the link is not an event page link.
- `{ ok: false, error: "event_not_found", ... }`: try an event id that does
  not exist, such as `/single/999999/x/`.

The function's **Logs** tab in the dashboard shows errors. It never logs
links, names or tokens, only short error codes.

## Limits

- Each look-up is logged in `pn_fetch_log`: at most 20 per account and 300
  for the whole site per hour (`rate_limited` beyond that). The log keeps an
  account id, a community and a time, and is purged after two days.
- The same Play Network event is read at most once a minute per function
  instance; repeated calls get the same answer.
- The function only ever requests
  `https://malediction.gg/play-network/events/single/<id>/<slug>/`, with a
  10 second timeout, a 3 MB size limit, no automatic redirects, and the
  User-Agent `SeekersLeague/1.0 (+https://seekers-league.com)`.
- It stores how many players registered, never who.
