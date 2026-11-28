# Play Network rounds on the Seekers League event page — technical plan

Status: PLAN ONLY, 2026-11-27. Nothing built. Not committed (like PROVE.md).
This is the design after a review against the code. Product questions for the owner are at the end.

## What PN exposes (checked 2026-11-27, event 663, also with no login)
- `window.playNetworkCurrentEventData`: event_state (Upcoming/Ongoing/Completed), officially_finished,
  system_name (Swiss), tiebreaker_name/mode, num_rounds, round_duration_minutes, report_matches, type_name,
  game_mode_name, co_hosts, and `rounds`:
  `{"1":{status, matches:[{id, table_number, is_bye, event_round_number, team_a_players:[{user_id, member_id, nickname, slot_index, is_float}], team_b_players}]}}`.
  These pending pairings have NO profile_url.
- `.compMatchResult[data-match-json]` (reported games): id, event_round_number, is_bye, is_draw, winning_team,
  team_a/b_score, match_played_turns, result_status, team_a/b_seeker/terrain, and players with nickname and
  profile_url (`/app/profile/<publicId>/`). The players also carry **first_name: never read it**.
- Ranking table `.compRankRow*`: rank, player, deck, Tournament Points, W-L-D, Mastery Differential.
- Generating rounds and reporting go through admin-ajax with the organiser's nonces. **SL can only read.**

## Decisions folded in from the review
1. Status moves must keep `payload.fmt='swiss'`, with rounds=n_rounds and gm=[]. The tournaments_v3_shape
   check allows only null or swiss, and deck lock/publish (t_auto_before), t_auto_after, push_t_after and the
   client's swIsSwiss all depend on fmt.
2. Bump `tournaments.rev` only when status or payload changes. Mirror-only updates move a separate `srev`.
3. Names: `t_pn_sync` already exists (the deck sync). Use `pn_live`: body.pn_live, t_pn_live_allow,
   t_pn_live_put, table tournament_pn_live.
4. In-flight guard: a `claimed_at` column with a ~20 s TTL, set by the gate. An advisory lock is released
   before the fetch, so it does not stop a second fetch.
5. RLS: enable RLS. Grant SELECT explicitly. Revoke INSERT, UPDATE and DELETE explicitly (Supabase defaults
   grant them). Visibility of running games to strangers depends on owner question 5: use the
   player_matches predicate unless the owner says PN-public is fine.
6. Never read user_id. Join pending pairings by nickname, on the client, against payload.entrants[].name.
   A duplicate or missing nickname shows as unmatched (nickname only).
7. PN rank stays in tournament_pn_live.rank. On close, write payload.standings and champion only for matched
   entrants, and set champion=null when rank 1 is unmatched. Do not use t_sw_close_apply.
8. t_reopen, t_unstart and discard refuse 'pn_rounds' on PN-rounds events. Otherwise the next sync would
   undo them.
9. Never for mode='demo'. Only for clash events whose PN type_name is Tournament.
10. The gate refuses when hidden_at is set (takedown). Put never touches hidden_at.
11. Use the check constraint `rounds_src='sl' or status is not null` instead of editing guard_tournament.
12. Keep check-in for PN-rounds events, but never call t_drop_absent and hide "Drop absent".
13. PN rounds send no "you're paired" push in Phase 1. Say so in the UI or add it in Phase 2.
14. t_auto_allow answers 'pn' (did:none), and swKickOk/swAutoDue skip PN-rounds events.
15. Cut from Phase 1: importing while running, the "not confirmed" tag (show Confirmed results only), the
    organiser's 30 s override, and the Home Next-up kick.
16. Accept the data only when the card count matches the non-pending matches in rounds[]. Otherwise answer
    'incomplete' and keep the last good mirror. The 1.5 MB literal cap applies to this mode only. The 3 MB
    page cap stays.
17. Only ONE FK: tournament_pn_live.tournament_id → tournaments (the PGRST201 trap).
18. Every new or replaced function uses `security definer set search_path = public, pg_temp`, including
    the trigger functions this plan touches.

## Phase 1
**DB (one migration, run by the owner; appended to schema.sql):**
- `tournaments.rounds_src text not null default 'sl' check in ('sl','pn')`.
  - Set to 'pn' on import when pn_event_id is set, the PN type is Tournament, and mode='clash'.
  - Changeable only by t_rounds_src while the event is a draft and gm is empty, if owner question 1 says "choice".
- `tournament_pn_live` columns:
  - tournament_id: PK and the only FK, on delete cascade;
  - pn_state, cur_round, n_rounds, system, tiebreak;
  - rounds jsonb: `[{r, status, games:[{id, tb, a:{pid,nick}, b:{pid,nick}, bye, draw, win, sa, sb, turns, sk_a, tr_a, sk_b, tr_b}]}]`;
  - rank jsonb: `[{rank, pid, nick, tp, w, l, d, md}]`;
  - hash, srev, fetched_at, claimed_at, ok, err;
  - a size check under 512 KB.
- `t_pn_live_allow(p_tid)`: who may trigger a fetch, the freshness rules, the claim, and logging to
  pn_fetch_log only on a real fetch.
  - Freshness: Ongoing 60 s; Upcoming 10 min within 3 h of the start, otherwise 6 h; Completed fetched once
    after it finishes, then never again.
  - Caps: 120 an hour site-wide (inside the existing 300); the per-user 20 an hour counts real fetches only.
- `t_pn_live_put(...)`, service_role only:
  - upserts the mirror and moves srev only when the hash changes;
  - on the first Ongoing: draft → running with fmt swiss;
  - on Completed: → closed, with standings and champion for matched entrants only.
- Refusals with 'pn_rounds' in t_pair, t_result, t_start pairing, t_close, t_reopen, t_unstart and
  t_drop_absent; 'pn' in t_auto_allow.

**Edge function (play-network-event):**
- A new `pn_live` mode that reuses parsePnUrl, fetchPage, readCapped, literalStart, sliceLiteral and
  parseEvent.
- New parsers:
  - readRounds: an allowlist, with NO user_id;
  - readMatchCards: bounded, picks keys, profile_url → pid, never first_name;
  - readRanking.
- Fail closed: keep the last good mirror; logs carry codes only; the answer has no names.
- Deploying it needs the owner's OK (Supabase CLI, Verify JWT stays off, never --prune).

**Client:**
- t3Load embeds tournament_pn_live.
- For PN-rounds events, evTabs shows by state:
  - Upcoming: Players / Check-in / Settings;
  - Ongoing: Rounds / Standings / Players;
  - Completed: Result / Rounds / Standings / Players.
- New pnRoundsPanel, pnGameHtml and pnStandingsHtml, with column names as PN gives them and bdFmt/esc
  everywhere.
- swActsHtml, swResultSheet, swPnSheet and swOrgTodo return early for these events.
- t3Poll calls pnLiveKick, once per srev with back-off.
- A "Refresh from Play Network" button, a "Rounds and results come from Play Network" line with the time
  of the last update, and a View on Play Network link.

**Tests:**
- Edge unit tests on three saved PN pages (Upcoming, Ongoing with a bye and a draw, Completed). A deep
  scan must find no first_name and no user_id; also test truncation → incomplete.
- Behaviour SQL on mkdb3.sh + invfix.sql (row-guarded checks need rows).
- A harness suite `pnrounds` in runslot.

## Phase 2
- "Your game this round" and the tracker know the PN opponent (tvNextFor / t3NextSw / paintHomeNext /
  tnMyActive).
- t_duel_start_pn ties the duel to t_ref `pn:<round>:<matchId>`. The PN result stays the record.
- Optionally the paired push.

## Phase 3 (future, separate)
- PN results feed the Meta and site_counts, de-duped against tracked duels by the PN match id.

## Open product questions (owner)
1. Should a PN-linked Tournament use PN rounds automatically, or should the organiser choose (default PN)?
2. Should unconfirmed results be hidden (Phase 1 cut) or shown with a tag later?
3. When PN finishes the event, should SL close it automatically?
4. Is the scope only Tournaments (no Casual Play or Demo Day)?
5. While the event is running, should people who are not in it see the PN pairings and standings on SL
   (PN shows them publicly)?
