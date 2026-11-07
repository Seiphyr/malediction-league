# Deploying play-network-event

This Edge Function reads an official Play Network event page on
malediction.gg. It has two modes:

- **Listing** (`{ league_id, url }` or `{ id }`): saves the event as a
  listing of a community (table `pn_events`). Only organizers of the
  community can call it. It keeps how many players registered, never who,
  and the event's settings: number of rounds (`num_rounds`), round length
  in minutes (`round_minutes`) and game mode (`game_mode`, 1x1 or 2x2).
- **Tournament** (`{ tournament_id, known? }`): copies the registered players
  of the tournament's Play Network event into that tournament: nickname,
  malediction.gg profile id, avatar, Discord handle and the deck locked for
  the event (name, link, Seeker, terrain, card list). First and last names
  are never read. `known` is the site's card list (collection number to
  name), sent by the page so card ids become the site's names. Only the
  tournament's organizer can call it, and only before the tournament starts.

## Before you start

Run the migrations in Supabase Dashboard > SQL Editor, in date order:

- `migration-2026-11-08-communities.sql`: the `pn_events` table and the
  `pn_fetch_allow()` function (listing mode).
- `migration-2026-11-11-tournaments.sql`: the tournament columns and the
  `t_fetch_allow()` and `t_import()` functions (tournament mode).
- `migration-2026-11-14-swiss.sql`: the `num_rounds`, `round_minutes` and
  `game_mode` columns of `pn_events`, and `t_import()` with its fourth
  argument `p_meta` (the event's settings, used to suggest the number of
  Swiss rounds).
- `migration-2026-11-19-pn-decklists.sql`: the `tournament_pn` table and the
  `t_import()` that stores avatars, Discord handles and decks.

The check query at the end of each migration should show `ok = true` on
every row.

## Deploy order

Phase 3 (tournaments) goes live in this order:

1. **SQL**: `migration-2026-11-11-tournaments.sql`.
2. **Site**: `index.html` with the tournament page and the new privacy text
   (the privacy page must describe the player import before any import runs).
3. **This function**: paste the new `index.ts` (below).

If the function is deployed before the SQL, the tournament mode answers
`upstream_error` (the `t_fetch_allow` call fails), and the listing mode keeps
working as before.

Swiss tournaments go live in this order:

1. **SQL**: `migration-2026-11-14-swiss.sql` (the new `pn_events` columns
   and the 4-argument `t_import` must exist first).
2. **Site**: `index.html`.
3. **This function**: paste the new `index.ts`.

Between steps 1 and 3 the old function keeps working: it does not write the
new columns, and it calls `t_import` with three arguments, which the new
`t_import` accepts because `p_meta` has a default. Until step 3, new
tournaments have no Play Network round count (`pn.rounds` is empty) and the
page suggests the number of rounds from the Malediction Tournament Guide
table.

Do not deploy this function before step 1 of the Swiss order: every listing
save would then fail ("The event was read but could not be saved", because
the new columns do not exist yet) and every player import would answer
`upstream_error` (no `t_import` with `p_meta`).

Decks from the Play Network (2026-11-19) go live in this order:

1. **SQL**: `migration-2026-11-19-pn-decklists.sql` (table `tournament_pn`,
   new `t_import`, `t_deck_get`, `t_deck_set`, `t_deck_pub`,
   `t_auto_before`).
2. **Site**: `index.html` (the privacy notice and the create-tournament
   sheet describe the new data: pictures, Discord handles and decks; the
   page sends `known`, shows the imported decks, the avatars and the
   opponent's Discord handle).
3. **This function**: paste the new `index.ts`. Only from here are
   pictures, Discord handles and decks read from the Play Network, so the
   privacy notice that describes them is already live.

Each step works with the one before it. The old function with the new SQL:
it sends no decks, so nothing changes (no avatars, no decks). The new page
with the old function: the old function refuses requests over 4 KB, and
the card list makes this one about 6 KB, so it answers `bad_url`; the page
then asks once more without the list and the import works as before (no
decks, no avatars, today's toast). The new function with the old page
(only if steps 2 and 3 were swapped): no `known` is sent, so card names
come from the Play Network page and no card is reported as unknown. If
this function were deployed before step 1, imports would still work (the
old `t_import` ignores the new fields), but nothing would be stored.

The names in `known` come from the organizer's page, so the function uses
one only when it matches the Play Network page's own name for that card;
otherwise the card keeps its Play Network name and counts as unknown.

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
   project's API keys settings. The tournament mode needs the secret
   (service role) key too: `t_import` can only be called with it.

To update it later, open the function, choose **Code**, paste the new
`index.ts` and deploy again. Check that Verify JWT is still off.

## Test it: listing mode

On the site, signed in as an organizer of a community that is not archived:
open the community, add an event, and paste an official link, for example
`https://malediction.gg/play-network/events/single/393/torneo-un-friendly-la-tana-dellotaku/`.
The listing should appear with its title, date, venue and number of players.

The event's settings are saved with the listing. Check them in the SQL
Editor (read only):

```sql
select pn_id, format, num_rounds, round_minutes, game_mode
from public.pn_events where pn_id = 393;
```

For event 393 expect `Swiss`, `1`, `60`, `1x1`. Play Network shows `0` for
a setting the organizer left empty (event 323 has `num_rounds = 0`); that
`0` is stored as it is, and a tournament treats it as "not set". A value
outside 0 to 100 rounds or 0 to 1440 minutes, or a game mode other than
1x1 or 2x2, is saved as empty.

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

## Test it: tournament mode

On the site, signed in as the person who linked a listing: open the
community's Events tab and choose **Run as a tournament** on that listing.
The tournament page should open with the registered players listed, and the
toast "Players updated from the Play Network: N registered, A new, R
removed." N should equal the number of players on the official page.

From the browser console (signed in as that organizer):

```js
const { data, error } = await sb.functions.invoke("play-network-event", {
  body: { tournament_id: "<tournament id>" },
});
console.log(data, error);
```

Expected answers:

- `{ ok: true, tournament: { id, rev, status: "draft" }, registrants: { total, added, removed, linked } }`:
  the players were merged. The list itself is never sent back; the page
  re-reads the tournament. `warning: "count_mismatch"` means the number of
  players read differs from the page's own count; `warning: "too_many"`
  means more than 256 players registered and only 256 were kept. In both
  cases (and when the page shows no count) nobody is removed from the
  tournament: players leave the list only when it was read in full.
- Call it again within 30 seconds: `rate_limited`.
- Signed in as someone else: `not_allowed` ("Only the organizer of this
  tournament can update its players.").
- After **Start the tournament**: `started` ("The tournament has started, so
  its list of players is fixed.").
- A community that is archived: `archived`.
- `parse_error` ("The list of registered players could not be read from the
  Play Network page. Add players by hand."): the page had neither the
  members list nor the Players tab list. The tournament's players are left
  as they were.

Then check the SQL side in the SQL Editor (read only):

```sql
select id, status, rev, jsonb_array_length(payload->'entrants') as players,
       payload#>>'{pn,n}' as official_count, payload#>>'{pn,at}' as imported_at,
       payload#>>'{pn,rounds}' as pn_rounds, payload#>>'{pn,system}' as pn_system,
       payload#>>'{pn,minutes}' as pn_minutes, payload#>>'{pn,gmode}' as pn_game_mode
from public.tournaments where id = '<tournament id>';
```

The last four columns come from `p_meta` (the event's settings, never
player data). For event 393: `1`, `Swiss`, `60`, `1x1`. A `0` round count
is kept as empty.

## Test it: decks

Play Network shows the decks of an event only once its organizer has
pressed Start there (the event is then Ongoing). Before that the answer
has `decks.hidden: true` and `decks.pre` = the players who have linked a
deck; decks imported earlier are kept. So: start the event on Play
Network, then tap **Update from the Play Network** on the tournament, then
start the tournament here (after our start the players and decks are
fixed).

The answer gains `decks: { n, miss, unk, part, hidden, pre }`: decks
imported, players without one (they register theirs by hand), cards the
site does not know (in all decks), decks read only in part (Seeker and
terrain exact), whether Play Network still hides decks, players with a
linked deck. Check the stored rows in the SQL Editor (read only):

```sql
select pid, deck_st, seeker, terrain, unk_n, unk, discord is not null as has_discord, fetched_at
from public.tournament_pn where tournament_id = '<tournament id>';
select user_id, src, pn_pid, seeker, terrain, locked_at
from public.tournament_decks where tournament_id = '<tournament id>';
```

`deck_st` is `locked` when the list matched Play Network's check hashes of
the locked deck (`linked`: the deck as it is now, when there is no lock),
`partial` when only part of it could be read (Play Network cuts its list at
40 cards; the function then reads the deck page, and a deck page that could
not be read this time is tried again on the next update). Each linked
player's deck is copied into `tournament_decks` with `src = 'pn'`.

The parser can be checked offline too: the pure block also holds
`deckPlan`, `deckFinish`, `deckStateOf`, `mapDeck` and the hash functions
(they use `crypto.subtle`, so the local page must be served from https,
127.0.0.1 or a file).

The parser can also be checked offline, without deploying: the block between
`// ---- registrants (pure) ----` and `// ---- end registrants ----` is plain
JavaScript. Copy it (with `clean`, `decodeEntities`, `toCount`,
`sliceLiteral`, `literalStart`, `NAMED_ENTITIES` and `MAX_PAGE_BYTES`, with
their TypeScript types removed) into a local page, load a saved event page as
text and call `readRegistrants(html)`: `list.length` should equal the page's
`registered_participants` value.

The function's **Logs** tab in the dashboard shows errors. It never logs
links, names, the players list or tokens, only short error codes.

## Limits

- Each look-up (both modes) is logged in `pn_fetch_log`: at most 20 per
  account and 300 for the whole site per hour (`rate_limited` beyond that).
  The log keeps an account id, a community and a time, and is purged after
  two days. In tournament mode, the same tournament can be imported at most
  once every 30 seconds.
- In listing mode, the same Play Network event is read at most once a minute
  per function instance; repeated calls get the same answer. The tournament
  mode always reads the page fresh (players are never cached).
- The function only ever requests
  `https://malediction.gg/play-network/events/single/<id>/<slug>/`, with a
  10 second timeout, a 3 MB size limit, no automatic redirects, and the
  User-Agent `SeekersLeague/1.0 (+https://seekers-league.com)`. In
  tournament mode it may also request the deck pages linked on that event
  page, only `https://malediction.gg/play-network/decks/view/<slug>/<hash>/`
  or `.../decks/snapshot/<this event id>/<this player's profile id>/`
  (www too): at most 32 per update, 4 at a time, none started after 20
  seconds, 8 seconds and 3 MB each, at most one redirect (to a link of the
  same shape).
- A request is at most 32 KB (`known` is about 7 KB).
- A listing stores how many players registered, never who, plus the
  event's number of rounds, round length and game mode. A tournament
  stores each registered player's Play Network nickname (at most 40
  characters), malediction.gg profile id, avatar (only
  `malediction.gg/wp-content/uploads/` images, stored as https), Discord
  handle (2 to 40 characters) and deck (name, link, Seeker, terrain,
  legacy, card list with the site's names: main at most 60 cards, side 15,
  9 copies, 64 names; a deck over a limit is not imported), at most 256
  players. First and last names, deck descriptions and registration times
  are never read.
- Who sees what: the card lists never leave the database. The Seeker and
  terrain: the organizer and the player while the tournament is in
  registration or running, everyone once it is closed. Unknown card names:
  the organizer. Discord handles: the organizer, and each player only for
  the opponent of their current game. Avatars: everyone who can see the
  tournament. Everything goes with the tournament when it is deleted.
