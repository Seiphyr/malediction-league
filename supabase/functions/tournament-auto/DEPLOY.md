# Deploying tournament-auto

This Edge Function runs Swiss tournaments by themselves:

- **Pairing**: when the last result of a round is in, it pairs the next
  round.
- **Closing**: after the last result of the last round (or when fewer than
  two players are still in), it closes the tournament and names the
  champion. When first place is still shared after points, mastery,
  opponents' points and head to head, it closes with no champion ("First
  place is shared"); the organizer can reopen it.

Nobody chooses the pairings. The site only asks "check tournament X"
(`{ tid }`), from the organizer's page or from any player's page or phone
after a result. The function reads the tournament and computes the next step
with the same Swiss engine as the organizer's page: the engine is copied
byte for byte from `index.html` into `index.ts`. Then the database functions
`t_auto_pair` and `t_auto_close` lock the tournament, check that nothing
changed in between, validate and write. When several phones ask at the same
moment, one of them pairs the round and the others find nothing left to do.

Holds set by the organizer are respected:

- After **Undo round N pairings**, round N is not paired automatically. The
  organizer pairs it by hand when ready.
- After **Reopen**, the tournament never closes by itself again, and when
  rounds are left the next one is not paired by itself either. The
  organizer pairs it (after that, later rounds pair by themselves again)
  and closes the tournament by hand.

Old group tournaments are never touched.

## Before you start

Run `migration-2026-11-15-tournament-auto.sql` in Supabase Dashboard > SQL
Editor. It adds `t_auto_allow()` (who may ask), and `t_auto_pair()` and
`t_auto_close()`, which only the service role (this function) can call. The
check query at the end of the migration should show `ok = true` on every
row.

## Deploy order

1. **SQL**: `migration-2026-11-15-tournament-auto.sql`.
2. **This function**: paste `index.ts` (below).
3. **Site**: push `index.html`.

Do it when no Swiss tournament is running, and keep the steps close
together. Between step 1 and step 3, pages still on the old site (and
phones that kept the old copy) start Swiss tournament games with a PIN:
after the migration those are casual matches, so their results are not
recorded into the tournament and the organizer has to enter them by hand.
The old site also shows a waiting invitation as "Tracked match live".
After step 3, ask players to reload the site.

If the function is deployed before the SQL, every call answers
`{ ok: false, reason: "error" }` (`t_auto_allow` does not exist yet) and
nothing is written. If the site goes live before the function, its calls
fail quietly and the organizer's **Pair round N** and **Close the
tournament** buttons keep working as before.

## Deploy from the dashboard

1. Open the project in the Supabase Dashboard and go to **Edge Functions**.
2. Choose **Deploy a new function** > **Via Editor**.
3. Name it exactly `tournament-auto`.
4. Delete the sample code, paste the whole content of `index.ts` from this
   folder, and click **Deploy function**. It is a single file: the Swiss
   engine is already inside it, between the `// >>> SWISS ENGINE` and
   `// <<< END SWISS ENGINE` lines.
5. Open the function's **Details** (or Settings) and turn **Verify JWT** OFF,
   then save. The code checks the signed-in user itself (this also keeps
   working with the newer API keys).
6. No secrets are needed. Supabase provides `SUPABASE_URL` and the API keys
   to every function automatically. The function uses the newer keys
   (`SUPABASE_PUBLISHABLE_KEYS`, `SUPABASE_SECRET_KEYS`) when the runtime
   provides them, and otherwise the legacy `SUPABASE_ANON_KEY` and
   `SUPABASE_SERVICE_ROLE_KEY`. It needs the secret (service role) key:
   `t_auto_pair` and `t_auto_close` can only be called with it. Without it,
   every call answers `error`; check the function's Logs and the project's
   API keys settings.

To update it later, open the function, choose **Code**, paste the new
`index.ts` and deploy again. Check that Verify JWT is still off.

## Keep the engine in sync

The engine inside `index.ts` must stay identical to the one in `index.html`.
Whenever the Swiss engine in `index.html` changes (the block from
`/* Swiss engine.` to `/* End of the Swiss engine. */`), run from Git Bash
in the repository folder:

```sh
sh tools/sync-swiss-engine.sh
```

It copies the block into `index.ts`. Then paste the new `index.ts` in the
dashboard as above. To only check, without changing anything:

```sh
sh tools/sync-swiss-engine.sh --check
```

It prints "in sync" and exits 0, or prints `DRIFT` and exits 1. Never edit
the engine lines in `index.ts` by hand.

## Test it

On the site, signed in as the organizer of a running Swiss tournament (or as
one of its players with a linked account): enter the last result of a round.
Within a few seconds the next round should appear with the note "Round N was
paired automatically."

From the browser console on the site (signed in):

```js
const { data, error } = await sb.functions.invoke("tournament-auto", {
  body: { tid: "<tournament id>" },
});
console.log(data, error);
```

Expected answers:

- `{ ok: true, did: "paired", round, rev }`: the next round was paired.
- `{ ok: true, did: "closed", rev, champion }`: the tournament was closed;
  `champion` is the winner's player key, or `null` when first place is
  shared.
- `{ ok: true, did: "none" }`: nothing to do yet (a result is missing, the
  tournament is not running, or it was already done by another phone).
- `{ ok: true, did: "none", why: "hold" }`: the organizer undid this round's
  pairings; it waits for **Pair round N**.
- `{ ok: true, did: "none", why: "stale" }`: the tournament kept changing
  during three tries in a row; the next ask will do it.
- `{ ok: false, reason: "not_allowed" }`: you are signed out, signed in as a
  guest, not the organizer, not a player of it with a linked account, or a
  player who dropped; or the id is not valid.
- `{ ok: false, reason: "rate_limited" }`: this account asked more than 60
  times in the last hour (3000 on the whole site). The page does not ask
  again for that change; **Pair round N** and **Close** still work.
- `{ ok: false, reason: "error" }`: something failed (see the Logs).

Ask twice in a row: the second answer is `did: "none"`.

Then check the SQL side in the SQL Editor (read only):

```sql
select id, status, rev, payload->'auto' as auto, payload->'hold' as hold,
       payload->'ac' as closed_automatically
from public.tournaments where id = '<tournament id>';
```

After an automatic pairing `auto` is `{"r": N}`; after an automatic close
`closed_automatically` is `true`. `hold` is `{"pair": N}` after an undo and
`{"close": true, "pair": N}` after a reopen with rounds left (`pair` goes
when the organizer pairs round N).

The function's **Logs** tab in the dashboard shows errors. It never logs
payloads, names, results or tokens, only short error codes. A log line
`refused bad_pairs` would mean the engine and the database rules disagree:
run `sh tools/sync-swiss-engine.sh --check` and report it.

## Limits

- A player who drops between rounds may already be paired for the next
  round: it is paired a few seconds after the last result. Dropping them
  then gives their opponent a forfeit win (3 points, like a bye), as a
  drop during a round always did. To pair without them instead, the
  organizer taps **Undo round N pairings** before any result of the new
  round is in, marks the drop, then **Pair round N**.
- Every call reads one tournament row and, at most three times, calls
  `t_auto_pair` or `t_auto_close`. Pairing 256 players takes about 25 ms.
- With every page closed nothing is paired: a result saved by the 48-hour
  auto-save is paired the next time a player or the organizer opens the
  site.
- Only Swiss tournaments that are running are changed. For drafts, closed
  tournaments and old group tournaments the answer is `did: "none"` (or
  `not_allowed` for someone who is not their organizer).
