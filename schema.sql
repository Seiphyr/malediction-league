-- ============================================================
--  MALEDICTION LEAGUE TRACKER — Supabase schema
--  Run this in: Supabase Dashboard > SQL Editor > New query
--
--  This file was checked against the live database on 2026-08-29:
--  every column, type, default, constraint, index, policy, view and
--  function below was read back from the Postgres catalogs and matches
--  production. Two things are deliberately different:
--    * tournaments no longer declares unique (league_id, month) — see
--      the drop constraint below, which the live database still needs;
--    * handle_new_user also reads the names sent by Google and Discord.
--  Keep it that way: if you change the database, mirror it here.
-- ============================================================

-- ---------- PROFILES ----------
-- One row per auth user. Role chosen at signup.
-- The foreign key to auth.users is dropped again in SECURITY HARDENING
-- (2026-11-06): a deleted login leaves its profile behind as a tombstone.
create table if not exists profiles (
  id          uuid primary key references auth.users on delete cascade,
  display_name text not null,
  role        text not null default 'player' check (role in ('player','organizer')),
  created_at  timestamptz not null default now()
);

-- ---------- LEAGUES ----------
-- is_online, region, timezone and discord_url are added in ONLINE LEAGUES AND
-- WINDOW EVENTS (2026-11-01) at the end of this file.
create table if not exists leagues (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  location    text not null,
  city        text,
  country     text,
  description text,
  join_code   text not null unique,
  owner_id    uuid not null references profiles(id) on delete cascade,
  is_public   boolean not null default true,
  created_at  timestamptz not null default now(),
  -- scoring config
  pts_attend  numeric not null default 1,
  pts_win     numeric not null default 2,
  pts_loss    numeric not null default 0.5,
  pts_sweep   numeric not null default 1,
  next_event_bonus smallint not null default 0,
  -- set when the owner archives: history stays readable, everything else stops
  archived_at timestamptz
);

-- ---------- MEMBERSHIPS ----------
create table if not exists memberships (
  id         uuid primary key default gen_random_uuid(),
  league_id  uuid not null references leagues(id) on delete cascade,
  user_id    uuid not null references profiles(id) on delete cascade,
  is_admin   boolean not null default false,  -- co-organizer of this league
  joined_at  timestamptz not null default now(),
  dropped_at timestamptz,                     -- set when a player leaves mid-season
  unique (league_id, user_id)
);

-- ---------- SESSIONS (game nights) ----------
-- end_date and rounds (window events) are added in ONLINE LEAGUES AND WINDOW
-- EVENTS (2026-11-01) at the end of this file.
create table if not exists sessions (
  id         uuid primary key default gen_random_uuid(),
  league_id  uuid not null references leagues(id) on delete cascade,
  date       date not null,
  notes      text,
  event_url  text,                              -- optional link to the event page
  is_tournament boolean not null default false, -- tournament nights score double
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

-- ---------- ATTENDANCE ----------
-- auto (a participation row kept by a trigger) is added in ONLINE LEAGUES AND
-- WINDOW EVENTS (2026-11-01) at the end of this file.
create table if not exists attendance (
  id         uuid primary key default gen_random_uuid(),
  session_id uuid not null references sessions(id) on delete cascade,
  user_id    uuid not null references profiles(id) on delete cascade,
  unique (session_id, user_id)
);

-- ---------- MATCHES ----------
-- Meta tracking: each side records seeker + terrain played.
create table if not exists matches (
  id             uuid primary key default gen_random_uuid(),
  session_id     uuid not null references sessions(id) on delete cascade,
  league_id      uuid not null references leagues(id) on delete cascade,
  winner_id      uuid not null references profiles(id) on delete cascade,
  loser_id       uuid not null references profiles(id) on delete cascade,
  winner_seeker  text,
  loser_seeker   text,
  terrain        text,          -- legacy single-terrain column, kept for old rows
  winner_terrain text,          -- each side brings its own terrain
  loser_terrain  text,
  winner_decklist text,         -- optional decklist link, for a list hosted elsewhere
  loser_decklist  text,
  winner_deck_id  uuid,         -- a deck kept here; decks is created further down,
  loser_deck_id   uuid,         -- so the foreign keys are added at the end of the file
  reported_by    uuid references profiles(id) on delete set null,
  confirmed      boolean not null default false,
  created_at     timestamptz not null default now(),
  check (winner_id <> loser_id)
);

create index if not exists idx_matches_league on matches(league_id);
create index if not exists idx_matches_session on matches(session_id);
create index if not exists idx_sessions_league on sessions(league_id);
create index if not exists idx_memberships_league on memberships(league_id);

-- ---------- TOURNAMENTS ----------
create table if not exists tournaments (
  id         uuid primary key default gen_random_uuid(),
  league_id  uuid not null references leagues(id) on delete cascade,
  month      text not null,          -- 'YYYY-MM'
  payload    jsonb not null,         -- groups + bracket state
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now()
  -- no unique (league_id, month): a league can run several tournaments
  -- in the same month. The app picks the most recent one by default.
);

-- Existing databases created before this change still carry the old
-- constraint, which would reject the second tournament of a month:
alter table tournaments drop constraint if exists tournaments_league_id_month_key;

-- ---------- COLLECTION ----------
-- One row per user per card. Each status is stored as a copy count:
-- toggling "owned" writes the full playset for that rarity (3/2/1),
-- so a non-zero value means "I have all the copies I can play".
create table if not exists collection (
  user_id    uuid not null references profiles(id) on delete cascade,
  card_key   text not null,               -- the card name, as printed
  owned      smallint not null default 0,
  printed    smallint not null default 0,
  painted    smallint not null default 0,
  standee    smallint not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, card_key)         -- no surrogate id on this one
);

-- ---------- DECKS ----------
create table if not exists decks (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references profiles(id) on delete cascade,
  name       text not null,
  seeker     text,                        -- Seeker name; binds the deck's Legacy
  faction    text,
  url        text,                        -- optional link to an external list
  description text,                       -- how the deck plays, shown on its page
  cards      jsonb,                       -- { "Card name": copies }
  side       jsonb,
  -- 'precon' is deliberately absent: the official Seeker Decks are built into
  -- index.html and never stored here. Copying one into your own decks drops the
  -- tag, so this constraint stays as it is.
  tag        text check (tag is null or tag in ('competitive','test','fun')),
  is_public  boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()  -- touched on every save
);

-- ---------- FREE BATTLES ----------
-- Games played outside a league. The opponent is free text, so they
-- do not need an account.
create table if not exists free_battles (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references profiles(id) on delete cascade,
  result        text not null check (result in ('win','loss')),
  my_seeker     text,
  opp_seeker    text,
  my_terrain    text,
  opp_terrain   text,
  opponent_name text,
  played_on     date not null default current_date,
  created_at    timestamptz not null default now()
);

-- collection needs no extra index: its primary key is (user_id, card_key).
create index if not exists decks_user_idx on decks(user_id);
create index if not exists free_battles_user_idx on free_battles(user_id);

-- The public_leagues view lives further down, next to the policies.

-- ---------- BRINGING AN OLD DATABASE UP TO DATE ----------
-- Safe to run on a database created from an earlier version of this file.
alter table leagues     add column if not exists next_event_bonus smallint not null default 0;
alter table leagues     add column if not exists archived_at timestamptz;

-- Ownership is not just a UI matter: the "admins update leagues" policy lets
-- any co-organizer write to the row, owner_id included. This guard makes sure
-- only the current owner can hand the league over.
create or replace function guard_league_owner()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.owner_id is distinct from old.owner_id and auth.uid() <> old.owner_id then
    raise exception 'Only the league owner can hand the league over';
  end if;
  return new;
end;
$$;
drop trigger if exists league_owner_guard on leagues;
create trigger league_owner_guard before update on leagues
  for each row execute function guard_league_owner();
alter table memberships add column if not exists dropped_at timestamptz;
alter table sessions    add column if not exists event_url text;
alter table sessions    add column if not exists is_tournament boolean not null default false;
alter table matches     add column if not exists winner_terrain text;
alter table matches     add column if not exists loser_terrain text;
alter table matches     add column if not exists winner_decklist text;
alter table matches     add column if not exists loser_decklist text;
-- A pasted link could only ever describe a deck hosted somewhere else, so a
-- deck built here was impossible to attach to a result. A match now points at
-- the deck itself; the old text columns stay for rows written before this.
alter table matches     add column if not exists winner_deck_id uuid;
alter table matches     add column if not exists loser_deck_id  uuid;
-- add constraint has no "if not exists", so adding it twice has to be caught.
do $$ begin
  alter table matches add constraint matches_winner_deck_fk
    foreign key (winner_deck_id) references decks(id) on delete set null;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table matches add constraint matches_loser_deck_fk
    foreign key (loser_deck_id) references decks(id) on delete set null;
exception when duplicate_object then null; end $$;
create index if not exists idx_matches_winner_deck on matches(winner_deck_id);
create index if not exists idx_matches_loser_deck  on matches(loser_deck_id);

-- A shared deck is a list and nothing else without a few words on how it plays.
alter table decks       add column if not exists description text;
-- So a reader of a shared deck knows whether it is still the list that player
-- actually brings.
alter table decks       add column if not exists updated_at timestamptz not null default now();
-- The database owns updated_at, so no client can get it wrong or leave it out.
-- Only a change a reader would care about counts: flipping a deck public or
-- private, for instance, leaves the list exactly as it was.
create or replace function touch_deck_updated()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.updated_at = now();
    return new;
  end if;
  if new.cards       is distinct from old.cards
  or new.side        is distinct from old.side
  or new.name        is distinct from old.name
  or new.seeker      is distinct from old.seeker
  or new.description is distinct from old.description
  or new.tag         is distinct from old.tag
  or new.url         is distinct from old.url then
    new.updated_at = now();
  else
    new.updated_at = old.updated_at;
  end if;
  return new;
end;
$$;

drop trigger if exists decks_touch_updated on decks;
create trigger decks_touch_updated before insert or update on decks
  for each row execute function touch_deck_updated();
-- Card names are the keys user data is stored under, so correcting a spelling
-- means moving that data. The official database spells this card Muq'Tovor;
-- this catalogue carried a stray "g". Re-running this does nothing, because
-- the old key no longer exists afterwards.
update collection
   set card_key = 'Muq''Tovor, Bodybreaker'
 where card_key = 'Mugq''Tovor, Bodybreaker';

update decks
   set cards = (cards - 'Mugq''Tovor, Bodybreaker')
             || jsonb_build_object('Muq''Tovor, Bodybreaker', cards -> 'Mugq''Tovor, Bodybreaker')
 where jsonb_exists(cards, 'Mugq''Tovor, Bodybreaker');

update decks
   set side = (side - 'Mugq''Tovor, Bodybreaker')
            || jsonb_build_object('Muq''Tovor, Bodybreaker', side -> 'Mugq''Tovor, Bodybreaker')
 where jsonb_exists(side, 'Mugq''Tovor, Bodybreaker');


-- ============================================================
--  HELPER FUNCTIONS
--  SECURITY DEFINER + fixed search_path avoids RLS recursion.
-- ============================================================
-- Replaced in SECURITY HARDENING (2026-11-06): a dropped co-organizer no longer counts.
create or replace function is_league_admin(p_league uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from leagues l where l.id = p_league and l.owner_id = auth.uid()
  ) or exists (
    select 1 from memberships m
    where m.league_id = p_league and m.user_id = auth.uid() and m.is_admin
  );
$$;

create or replace function is_league_member(p_league uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from memberships m
    where m.league_id = p_league and m.user_id = auth.uid()
  );
$$;

create or replace function session_league(p_session uuid)
returns uuid language sql security definer stable set search_path = public as $$
  select league_id from sessions where id = p_session;
$$;

-- ============================================================
--  ROW LEVEL SECURITY
-- ============================================================
alter table profiles    enable row level security;
alter table leagues     enable row level security;
alter table memberships enable row level security;
alter table sessions    enable row level security;
alter table attendance  enable row level security;
alter table matches     enable row level security;
alter table tournaments enable row level security;
alter table collection  enable row level security;
alter table decks       enable row level security;
alter table free_battles enable row level security;

-- ---------- collection: private to its owner ----------
drop policy if exists "collection own read" on collection;
create policy "collection own read" on collection
  for select using (auth.uid() = user_id);

drop policy if exists "collection own write" on collection;
create policy "collection own write" on collection
  for insert with check (auth.uid() = user_id);

drop policy if exists "collection own update" on collection;
create policy "collection own update" on collection
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "collection own delete" on collection;
create policy "collection own delete" on collection
  for delete using (auth.uid() = user_id);

-- ---------- decks ----------
-- Two separate select policies: anyone reads the public ones, the owner
-- also reads their private ones. Policies are OR-ed together.
drop policy if exists "public decks read" on decks;
create policy "public decks read" on decks
  for select using (is_public = true);

drop policy if exists "own decks select" on decks;
create policy "own decks select" on decks
  for select using (user_id = auth.uid());

drop policy if exists "own decks insert" on decks;
create policy "own decks insert" on decks
  for insert with check (user_id = auth.uid());

drop policy if exists "own decks update" on decks;
create policy "own decks update" on decks
  for update using (user_id = auth.uid());

drop policy if exists "own decks delete" on decks;
create policy "own decks delete" on decks
  for delete using (user_id = auth.uid());

-- ---------- free battles: private to their owner ----------
-- Note: there is deliberately no update policy — a logged battle is
-- deleted and re-entered rather than edited.
drop policy if exists "fb own read" on free_battles;
create policy "fb own read" on free_battles
  for select using (auth.uid() = user_id);

drop policy if exists "fb own write" on free_battles;
create policy "fb own write" on free_battles
  for insert with check (auth.uid() = user_id);

drop policy if exists "fb own delete" on free_battles;
create policy "fb own delete" on free_battles
  for delete using (auth.uid() = user_id);

-- ---------- profiles ----------
drop policy if exists "profiles readable" on profiles;
create policy "profiles readable" on profiles
  for select using (true);

drop policy if exists "own profile insert" on profiles;
create policy "own profile insert" on profiles
  for insert with check (auth.uid() = id);

drop policy if exists "own profile update" on profiles;
create policy "own profile update" on profiles
  for update using (auth.uid() = id);

-- ---------- leagues ----------
-- Public directory: anyone (even logged out) can browse public leagues.
drop policy if exists "public leagues visible" on leagues;
create policy "public leagues visible" on leagues
  for select using (is_public or is_league_member(id));

-- Any signed-in user can create a league, and only as themselves.
-- The old rule also required profiles.role = 'organizer'. That was never a real
-- boundary (anyone can update their own profile row) and it left new users stuck:
-- you only become an owner by creating a league in the first place.
drop policy if exists "organizers create leagues" on leagues;
drop policy if exists "members create leagues" on leagues;
create policy "members create leagues" on leagues
  for insert with check (owner_id = auth.uid());

drop policy if exists "admins update leagues" on leagues;
create policy "admins update leagues" on leagues
  for update using (is_league_admin(id));

drop policy if exists "owner deletes league" on leagues;
create policy "owner deletes league" on leagues
  for delete using (owner_id = auth.uid());

-- ---------- memberships ----------
drop policy if exists "memberships visible" on memberships;
create policy "memberships visible" on memberships
  for select using (true);

-- Players join through join_league() (see the end of this file); only organizers insert rows directly.
drop policy if exists "self join" on memberships;
create policy "self join" on memberships
  for insert with check (is_league_admin(league_id));

drop policy if exists "admins manage memberships" on memberships;
create policy "admins manage memberships" on memberships
  for update using (is_league_admin(league_id));

drop policy if exists "leave or admin removes" on memberships;
create policy "leave or admin removes" on memberships
  for delete using (user_id = auth.uid() or is_league_admin(league_id));

-- Two more update policies live on the database alongside the one above.
-- The admin one reads memberships directly instead of going through
-- is_league_admin(), so it does not depend on that helper.
drop policy if exists "memberships_update_admin" on memberships;
create policy "memberships_update_admin" on memberships
  for update using (
    exists (select 1 from memberships m2
            where m2.league_id = memberships.league_id
              and m2.user_id = auth.uid() and m2.is_admin)
  ) with check (true);

drop policy if exists "memberships_update_self" on memberships;
create policy "memberships_update_self" on memberships
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ---------- sessions ----------
drop policy if exists "sessions visible" on sessions;
create policy "sessions visible" on sessions
  for select using (
    is_league_member(league_id)
    or exists (select 1 from leagues l where l.id = league_id and l.is_public)
  );

drop policy if exists "admins write sessions" on sessions;
create policy "admins write sessions" on sessions
  for insert with check (is_league_admin(league_id));

drop policy if exists "admins update sessions" on sessions;
create policy "admins update sessions" on sessions
  for update using (is_league_admin(league_id));

drop policy if exists "admins delete sessions" on sessions;
create policy "admins delete sessions" on sessions
  for delete using (is_league_admin(league_id));

-- ---------- attendance ----------
drop policy if exists "attendance visible" on attendance;
create policy "attendance visible" on attendance
  for select using (true);

-- Players can check themselves in; organizers can check anyone in.
drop policy if exists "self or admin attendance" on attendance;
create policy "self or admin attendance" on attendance
  for insert with check (
    user_id = auth.uid() or is_league_admin(session_league(session_id))
  );

drop policy if exists "self or admin remove attendance" on attendance;
create policy "self or admin remove attendance" on attendance
  for delete using (
    user_id = auth.uid() or is_league_admin(session_league(session_id))
  );

-- ---------- matches ----------
drop policy if exists "matches visible" on matches;
create policy "matches visible" on matches
  for select using (
    is_league_member(league_id)
    or exists (select 1 from leagues l where l.id = league_id and l.is_public)
  );

-- KEY RULE: a player may only report a match they personally played in.
-- Organizers may report any match in their league.
drop policy if exists "own match or admin" on matches;
create policy "own match or admin" on matches
  for insert with check (
    is_league_admin(league_id)
    or (
      reported_by = auth.uid()
      and (winner_id = auth.uid() or loser_id = auth.uid())
      and is_league_member(league_id)
    )
  );

-- Players may edit their own unconfirmed report; organizers may edit anything.
drop policy if exists "edit own unconfirmed or admin" on matches;
create policy "edit own unconfirmed or admin" on matches
  for update using (
    is_league_admin(league_id)
    or (reported_by = auth.uid() and not confirmed)
  );

drop policy if exists "delete own unconfirmed or admin" on matches;
create policy "delete own unconfirmed or admin" on matches
  for delete using (
    is_league_admin(league_id)
    or (reported_by = auth.uid() and not confirmed)
  );

-- ---------- tournaments ----------
drop policy if exists "tournaments visible" on tournaments;
create policy "tournaments visible" on tournaments
  for select using (
    is_league_member(league_id)
    or exists (select 1 from leagues l where l.id = league_id and l.is_public)
  );

drop policy if exists "admins write tournaments" on tournaments;
create policy "admins write tournaments" on tournaments
  for insert with check (is_league_admin(league_id));

drop policy if exists "admins update tournaments" on tournaments;
create policy "admins update tournaments" on tournaments
  for update using (is_league_admin(league_id));

drop policy if exists "admins delete tournaments" on tournaments;
create policy "admins delete tournaments" on tournaments
  for delete using (is_league_admin(league_id));

-- ============================================================
--  PUBLIC DIRECTORY VIEW (no auth needed)
-- ============================================================
-- The view selects the map pin, so the columns have to exist by the time it is
-- created. They are added again further down with the rest of the map work;
-- both are "if not exists", and this file is meant to run top to bottom.
alter table leagues add column if not exists lat double precision;
alter table leagues add column if not exists lon double precision;

-- "create or replace view" may only append columns to an existing view: put a
-- new one in the middle and Postgres reads it as renaming whatever already sat
-- in that position. Dropping first sidesteps that, and the pin goes last so a
-- plain replace would work too. Nothing depends on this view but the app, which
-- selects * and reads columns by name, so their order does not matter.
drop view if exists public_leagues;
create or replace view public_leagues
with (security_invoker = on) as
select
  l.id, l.name, l.location, l.city, l.country, l.description, l.created_at,
  (select count(*) from memberships m where m.league_id = l.id) as member_count,
  (select count(*) from sessions s where s.league_id = l.id)    as session_count,
  (select max(s.date) from sessions s where s.league_id = l.id) as last_session,
  l.lat, l.lon
from leagues l
where l.is_public;

-- ============================================================
--  AUTO-CREATE PROFILE ON SIGNUP
-- ============================================================
create or replace function handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name, role)
  values (
    new.id,
    -- email signup uses display_name; Google sends full_name/name,
    -- Discord sends global_name/full_name/user_name. Email prefix is the last resort.
    coalesce(
      nullif(trim(new.raw_user_meta_data->>'display_name'), ''),
      nullif(trim(new.raw_user_meta_data->>'full_name'), ''),
      nullif(trim(new.raw_user_meta_data->>'name'), ''),
      nullif(trim(new.raw_user_meta_data->>'global_name'), ''),
      nullif(trim(new.raw_user_meta_data->>'user_name'), ''),
      nullif(trim(new.raw_user_meta_data->>'preferred_username'), ''),
      split_part(new.email,'@',1)
    ),
    coalesce(new.raw_user_meta_data->>'role', 'player')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ============================================================
--  HERALDS, CONTACTS, MAP PINS AND THE NOTICE BOARD
-- ============================================================

-- ---------- profiles: what a player chooses to publish ----------
-- Everything in profiles is world-readable (see "profiles readable" below), so
-- each of these is published the moment it is filled in, and the app says so
-- where it asks for them. All of them are optional and start empty.
alter table profiles add column if not exists herald_rank     text;
alter table profiles add column if not exists discord         text;
alter table profiles add column if not exists malediction_url text;
alter table profiles add column if not exists lat             double precision;
alter table profiles add column if not exists lon             double precision;
alter table profiles add column if not exists place           text;

-- Only the four official ranks, or none at all.
alter table profiles drop constraint if exists profiles_herald_rank_check;
alter table profiles add constraint profiles_herald_rank_check
  check (herald_rank is null or herald_rank in
    ('Journeyman Herald','True Herald','Elevated Herald','Grand Herald'));

-- A pin is either absent or a real point on the globe. Half a pin is not a pin.
alter table profiles drop constraint if exists profiles_latlon_check;
alter table profiles add constraint profiles_latlon_check
  check ((lat is null) = (lon is null)
     and (lat is null or (lat between -90 and 90 and lon between -180 and 180)));

-- ---------- leagues get a pin too, for Find a league ----------
alter table leagues add column if not exists lat double precision;
alter table leagues add column if not exists lon double precision;
alter table leagues drop constraint if exists leagues_latlon_check;
alter table leagues add constraint leagues_latlon_check
  check ((lat is null) = (lon is null)
     and (lat is null or (lat between -90 and 90 and lon between -180 and 180)));

-- ---------- who may speak to everyone ----------
-- Deliberately its own table rather than a column on profiles: a player may
-- update every column of their own profile row, so a site_admin flag living
-- there would let anybody promote themselves. This table has a read policy and
-- no write policy at all, so it can only be changed from the SQL editor.
create table if not exists site_admins (
  user_id uuid primary key references profiles(id) on delete cascade,
  added_at timestamptz not null default now()
);
alter table site_admins enable row level security;
drop policy if exists "site admins readable" on site_admins;
create policy "site admins readable" on site_admins for select using (true);

create or replace function is_site_admin()
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from site_admins s where s.user_id = auth.uid());
$$;

-- ---------- the notice board ----------
-- league_id null means the message is for everyone and only a site admin may
-- write it. Otherwise it belongs to one league and its organisers own it.
create table if not exists announcements (
  id         uuid primary key default gen_random_uuid(),
  league_id  uuid references leagues(id) on delete cascade,
  author_id  uuid references profiles(id) on delete set null,
  body       text not null check (length(btrim(body)) between 1 and 1000),
  created_at timestamptz not null default now(),
  expires_at timestamptz
);
create index if not exists idx_announcements_league  on announcements(league_id);
create index if not exists idx_announcements_created on announcements(created_at desc);

alter table announcements enable row level security;

drop policy if exists "announcements visible" on announcements;
create policy "announcements visible" on announcements
  for select using (
    league_id is null
    or is_league_member(league_id)
    or exists (select 1 from leagues l where l.id = league_id and l.is_public)
  );

drop policy if exists "announcements write" on announcements;
create policy "announcements write" on announcements
  for insert with check (
    author_id = auth.uid()
    and case when league_id is null then is_site_admin() else is_league_admin(league_id) end
  );

drop policy if exists "announcements update" on announcements;
create policy "announcements update" on announcements
  for update using (
    case when league_id is null then is_site_admin() else is_league_admin(league_id) end
  );

drop policy if exists "announcements delete" on announcements;
create policy "announcements delete" on announcements
  for delete using (
    case when league_id is null then is_site_admin() else is_league_admin(league_id) end
  );

-- To be able to post to everyone, add yourself once, by hand, by account id
-- (a display name is not unique: anyone can call themselves the same):
--   insert into site_admins (user_id) values ('<your-user-uuid>');
-- Your id is under Dashboard > Authentication > Users.

-- The home page reads leagues through public_leagues, so the view has to carry
-- the pin as well or Find a league would never show one. Same definition as
-- further up, repeated here so this section can be run on its own.
drop view if exists public_leagues;
create or replace view public_leagues
with (security_invoker = on) as
select
  l.id, l.name, l.location, l.city, l.country, l.description, l.created_at,
  (select count(*) from memberships m where m.league_id = l.id) as member_count,
  (select count(*) from sessions s where s.league_id = l.id)    as session_count,
  (select max(s.date) from sessions s where s.league_id = l.id) as last_session,
  l.lat, l.lon
from leagues l
where l.is_public;

-- ============================================================
--  TOURNAMENTS: AN ENTRANT SETS THEIR OWN DECK
-- ============================================================
-- Only league admins may update a tournament, and that stays true. But an
-- organizer cannot read a player's private decks, so they could never pick
-- them on the player's behalf. This function lets the signed-in player change
-- one thing: their own line in `entrants` (Seeker, terrain, deck). It refuses
-- once any result has been recorded or the tournament is finalized, so a list
-- is fixed before play starts.
create or replace function set_tournament_entry(
  p_tournament uuid,
  p_seeker     text,
  p_terrain    text,
  p_deck       text,
  p_deck_id    text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  pl  jsonb;
  idx int;
begin
  if uid is null then
    raise exception 'Sign in first';
  end if;

  select payload into pl from tournaments where id = p_tournament for update;
  if pl is null then
    raise exception 'Tournament not found';
  end if;
  if coalesce(pl->>'v', '') <> '2' then
    raise exception 'This tournament cannot be changed';
  end if;
  if coalesce(pl->>'finalized', 'false') = 'true' then
    raise exception 'The tournament is finalized';
  end if;
  if exists (
    select 1 from jsonb_array_elements(coalesce(pl->'gm', '[]'::jsonb)) m
    where coalesce(m->>'w', '') <> ''
  ) then
    raise exception 'A result is already in — decks are locked';
  end if;

  select (o - 1)::int into idx
  from jsonb_array_elements(coalesce(pl->'entrants', '[]'::jsonb)) with ordinality as x(v, o)
  where v->>'id' = uid::text
  limit 1;
  if idx is null then
    raise exception 'You are not playing in this tournament';
  end if;

  -- A deck id is only accepted if it is the caller's own deck.
  if coalesce(p_deck_id, '') <> '' and not exists (
    select 1 from decks d where d.id::text = p_deck_id and d.user_id = uid
  ) then
    raise exception 'That deck is not yours';
  end if;

  update tournaments
  set payload = jsonb_set(
    pl,
    array['entrants', idx::text],
    (pl->'entrants'->idx) || jsonb_build_object(
      'seeker',  left(coalesce(p_seeker, ''), 80),
      'terrain', left(coalesce(p_terrain, ''), 80),
      'deck',    left(coalesce(p_deck, ''), 80),
      'deckId',  coalesce(p_deck_id, '')
    )
  )
  where id = p_tournament;
end $$;

revoke all on function set_tournament_entry(uuid, text, text, text, text) from public;
grant execute on function set_tournament_entry(uuid, text, text, text, text) to authenticated;

-- ============================================================
--  JOINING A LEAGUE, AND WHO MAY CHANGE A MEMBERSHIP
-- ============================================================
-- Until now a player joined by inserting their own membership row, and the
-- join code was only checked in the browser. The insert policy asked for
-- nothing but user_id = auth.uid(), so anyone signed in could add themselves
-- to any league, private ones included, and with is_admin = true. The update
-- policy for one's own row had the same gap.
--
-- Now:
--   * joining goes through join_league(), which checks the code (or that the
--     league is public) inside the database;
--   * only a league's organizers insert membership rows directly (that is how
--     createLeague adds the owner);
--   * a player may change their own row only to leave; organizers keep full
--     control. A trigger enforces that, since a policy cannot compare old and
--     new values.
--
-- Every existing policy on memberships is dropped first, whatever its name,
-- so a policy added by hand on the live database cannot keep the old hole open.

do $$
declare p record;
begin
  for p in select policyname from pg_policies where schemaname = 'public' and tablename = 'memberships' loop
    execute format('drop policy %I on public.memberships', p.policyname);
  end loop;
end $$;

create policy "memberships visible" on memberships
  for select using (true);

create policy "organizers add members" on memberships
  for insert with check (is_league_admin(league_id));

create policy "members update own or organizers" on memberships
  for update using (user_id = auth.uid() or is_league_admin(league_id))
  with check (user_id = auth.uid() or is_league_admin(league_id));

create policy "leave or admin removes" on memberships
  for delete using (user_id = auth.uid() or is_league_admin(league_id));

-- Not security definer on purpose: current_user is then the caller's role.
-- Requests from the site run as 'authenticated'; database functions such as
-- join_league() run as their owner and are trusted to have checked already.
create or replace function guard_membership_update()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if new.league_id is distinct from old.league_id or new.user_id is distinct from old.user_id then
    raise exception 'A membership cannot be moved';
  end if;
  if is_league_admin(old.league_id) then
    return new;
  end if;
  if new.is_admin is distinct from old.is_admin or new.joined_at is distinct from old.joined_at then
    raise exception 'Only an organizer can change that';
  end if;
  if old.dropped_at is not null and new.dropped_at is null then
    raise exception 'Use the join code to come back';
  end if;
  return new;
end $$;

drop trigger if exists membership_update_guard on memberships;
create trigger membership_update_guard before update on memberships
  for each row execute function guard_membership_update();

-- Join with a code, or straight into a public league by its id.
-- Coming back after leaving clears dropped_at, as joining always did.
create or replace function join_league(p_code text default null, p_league uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  l   leagues%rowtype;
begin
  if uid is null then
    raise exception 'Sign in first';
  end if;
  if coalesce(trim(p_code), '') <> '' then
    select * into l from leagues where upper(join_code) = upper(trim(p_code));
  elsif p_league is not null then
    select * into l from leagues where leagues.id = p_league and is_public;
  end if;
  if l.id is null then
    raise exception 'No league with that code';
  end if;
  if l.archived_at is not null then
    raise exception 'This league is archived';
  end if;
  insert into memberships (league_id, user_id) values (l.id, uid)
    on conflict (league_id, user_id) do update set dropped_at = null;
  return jsonb_build_object('id', l.id, 'name', l.name);
end $$;

revoke all on function join_league(text, uuid) from public, anon;
grant execute on function join_league(text, uuid) to authenticated;

-- ============================================================
--  FINISHING AN EVENT
-- ============================================================
-- "Finish event" used to move the event's date back a day so it would fall
-- into Past, which put events on the 1st into the previous month's standing.
-- It now stamps closed_at and leaves the date alone.
alter table sessions add column if not exists closed_at timestamptz;

-- ============================================================
--  CLOSING THE SAME KIND OF GAP ELSEWHERE
-- ============================================================
-- A review of every policy after the membership fix found more places where a
-- signed-in user could reach into a league they do not belong to.

create or replace function league_is_public(p_league uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select coalesce((select is_public from leagues where id = p_league), false);
$$;

-- A member who has not left. Players who left or were moved to Retired keep
-- reading their league's history, but no longer report results in it.
create or replace function is_active_member(p_league uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from memberships m
    where m.league_id = p_league and m.user_id = auth.uid() and m.dropped_at is null
  );
$$;

-- Checking yourself in needs an active membership, an open event and a league
-- that is not archived. Before, anyone signed in could add themselves to any
-- event of any league and collect attendance points in its standings.
create or replace function can_check_in(p_session uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1
    from sessions s
    join leagues l on l.id = s.league_id
    join memberships m on m.league_id = s.league_id
                      and m.user_id = auth.uid()
                      and m.dropped_at is null
    where s.id = p_session
      and s.closed_at is null
      and l.archived_at is null
  );
$$;

-- The owner of a league can always read it. A private league used to be
-- unreadable to its owner for the moment between creating it and adding their
-- own membership, so creating one failed.
drop policy if exists "public leagues visible" on leagues;
create policy "public leagues visible" on leagues
  for select using (is_public or owner_id = auth.uid() or is_league_member(id));

-- Who plays in a private league, and who came to its events, is now visible
-- only to its members (and to each player for their own rows).
drop policy if exists "memberships visible" on memberships;
create policy "memberships visible" on memberships
  for select using (
    user_id = auth.uid() or is_league_member(league_id) or league_is_public(league_id)
  );

drop policy if exists "attendance visible" on attendance;
create policy "attendance visible" on attendance
  for select using (
    user_id = auth.uid()
    or is_league_member(session_league(session_id))
    or league_is_public(session_league(session_id))
  );

drop policy if exists "self or admin attendance" on attendance;
create policy "self or admin attendance" on attendance
  for insert with check (
    is_league_admin(session_league(session_id))
    or (user_id = auth.uid() and can_check_in(session_id))
  );

-- A reported match must belong to an event of the same league, and a player's
-- own report cannot arrive already confirmed. Editing an unconfirmed report is
-- held to the same rules as writing it, so it cannot be moved into another
-- league or handed to two other players.
drop policy if exists "own match or admin" on matches;
create policy "own match or admin" on matches
  for insert with check (
    session_league(session_id) = league_id
    and (
      is_league_admin(league_id)
      or (
        reported_by = auth.uid()
        and not confirmed
        and (winner_id = auth.uid() or loser_id = auth.uid())
        and is_active_member(league_id)
      )
    )
  );

drop policy if exists "edit own unconfirmed or admin" on matches;
create policy "edit own unconfirmed or admin" on matches
  for update using (
    is_league_admin(league_id)
    or (reported_by = auth.uid() and not confirmed)
  ) with check (
    session_league(session_id) = league_id
    and (
      is_league_admin(league_id)
      or (
        reported_by = auth.uid()
        and not confirmed
        and (winner_id = auth.uid() or loser_id = auth.uid())
        and is_active_member(league_id)
      )
    )
  );

-- Notices are never edited from the site, and the update rule let an
-- organizer change who a notice appeared to come from. Removing it means a
-- notice can only be posted or deleted.
drop policy if exists "announcements update" on announcements;

-- ============================================================
--  APP ANALYTICS AND FEEDBACK
-- ============================================================
-- Two tables the site writes to without anyone having to be signed in.
--
-- app_events holds anonymous usage statistics: a page view, a named action or
-- an error, with a random id that lives only as long as the browser tab
-- (sessionStorage), whether someone was signed in, and a coarse device type.
-- There is deliberately no user_id, no IP address and no user agent string.
-- Paths arrive with every id and code replaced (#/league/:id/standings), and
-- action events carry no user text. Rows are kept 90 days, feedback 12 months:
-- purge_old_rows() deletes older ones every night through pg_cron (scheduled
-- at the end of this section when the project has pg_cron), every insert into
-- app_events also clears a batch of expired rows, and the admin panel purges
-- when it is opened. Nothing depends on someone opening the admin panel.
--
-- Action names the site records (see the anActs list in index.html):
--   signup_submit, signup_ok, signin_ok, oauth_start, league_join,
--   league_create, checkin, checkin_other, match_log, match_confirm,
--   event_create, notice_post, tournament_generate, tournament_result,
--   tournament_finalize, deck_save, free_battle_log, notify_on, invite_copy,
--   feedback_send.
-- Error names start with "js: ", "promise: " or "toast: ".
--
-- feedback holds bug reports and ideas sent from the site. Signed-out
-- visitors may send one too; a trigger keeps a flood of them out.
--
-- Safe to run more than once.

-- ---------- app_events ----------
create table if not exists app_events (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  sid        text not null check (length(sid) between 1 and 40),
  kind       text not null check (kind in ('view','action','error')),
  name       text not null check (length(name) between 1 and 240),
  path       text check (path is null or length(path) <= 200),
  signed_in  boolean not null default false,
  device     text check (device in ('mobile','tablet','desktop')),
  detail     jsonb check (detail is null or octet_length(detail::text) <= 1000)
);
create index if not exists app_events_created_idx on app_events (created_at);
create index if not exists app_events_kind_created_idx on app_events (kind, created_at);

-- The client cannot backdate or postdate a row.
create or replace function app_events_stamp()
returns trigger language plpgsql set search_path = public as $$
begin
  new.created_at := now();
  return new;
end $$;
drop trigger if exists app_events_stamp on app_events;
create trigger app_events_stamp before insert on app_events
  for each row execute function app_events_stamp();

alter table app_events enable row level security;
drop policy if exists "app events insert" on app_events;
create policy "app events insert" on app_events
  for insert to anon, authenticated with check (true);
drop policy if exists "app events admin read" on app_events;
create policy "app events admin read" on app_events
  for select using (is_site_admin());
drop policy if exists "app events admin delete" on app_events;
create policy "app events admin delete" on app_events
  for delete using (is_site_admin());
-- No update policy: an event is never edited.

-- Only what the site needs. Inserts go out with return=minimal, so anon never
-- needs to read the table back.
revoke all on app_events from anon, authenticated;
grant insert on app_events to anon, authenticated;
grant select, delete on app_events to authenticated;

-- The flood brake. Anyone holding the public key can insert, so the database
-- caps what it accepts: at most 50 rows in one request (the site sends 50 at
-- most), at most 1000 rows a minute and 30000 a day from everyone together.
-- Past that, inserts are refused until the window moves on; the site treats
-- the refusal like a missing table and stops sending for that tab. With rows
-- of at most about 2 KB that keeps a flood under roughly 60 MB a day.
-- Rows stay forgeable (an anonymous counter cannot tell a script from a
-- visitor), so the numbers are a guide, not evidence.
-- The same trigger clears a batch of expired rows, so the 90-day and
-- 12-month limits hold even where pg_cron is not available.
create or replace function app_events_brake()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from new_rows) > 50 then
    raise exception 'Too many events in one request.'
      using errcode = 'P0001', hint = 'rate_limited';
  end if;
  if (select count(*) from app_events where created_at > now() - interval '1 minute') > 1000
     or (select count(*) from app_events where created_at > now() - interval '1 day') > 30000 then
    raise exception 'Too many events right now.'
      using errcode = 'P0001', hint = 'rate_limited';
  end if;
  delete from app_events where id in (
    select id from app_events where created_at < now() - interval '90 days'
    order by created_at limit 2000 for update skip locked);
  delete from feedback where id in (
    select id from feedback where created_at < now() - interval '12 months'
    order by created_at limit 200 for update skip locked);
  return null;
end $$;
drop trigger if exists app_events_brake on app_events;
create trigger app_events_brake after insert on app_events
  referencing new table as new_rows
  for each statement execute function app_events_brake();

-- ---------- feedback ----------
create table if not exists feedback (
  id         uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  user_id    uuid default auth.uid() references auth.users on delete cascade,
  kind       text not null check (kind in ('bug','idea','other')),
  body       text not null check (length(body) between 3 and 4000),
  contact    text check (contact is null or length(contact) <= 200),
  page       text check (page is null or length(page) <= 200),
  context    jsonb check (context is null or octet_length(context::text) <= 4000),
  status     text not null default 'new' check (status in ('new','seen','done')),
  admin_note text check (admin_note is null or length(admin_note) <= 2000),
  updated_at timestamptz
);
create index if not exists feedback_created_idx on feedback (created_at);
create index if not exists feedback_user_created_idx on feedback (user_id, created_at);
-- Deleting an account deletes its reports, contact field included, as the
-- privacy page promises. Re-added so an older copy of this table is fixed too.
alter table feedback drop constraint if exists feedback_user_id_fkey;
alter table feedback add constraint feedback_user_id_fkey
  foreign key (user_id) references auth.users on delete cascade;

alter table feedback enable row level security;
-- A signed-in sender is recorded as themselves, a signed-out one as nobody,
-- and nothing can arrive already triaged.
drop policy if exists "feedback insert" on feedback;
create policy "feedback insert" on feedback
  for insert to anon, authenticated with check (
    ((user_id is null and auth.uid() is null) or user_id = auth.uid())
    and status = 'new'
    and admin_note is null
    and updated_at is null
  );
drop policy if exists "feedback read" on feedback;
create policy "feedback read" on feedback
  for select using (is_site_admin() or (user_id is not null and user_id = auth.uid()));
drop policy if exists "feedback admin update" on feedback;
create policy "feedback admin update" on feedback
  for update using (is_site_admin()) with check (is_site_admin());
drop policy if exists "feedback admin delete" on feedback;
create policy "feedback admin delete" on feedback
  for delete using (is_site_admin());

revoke all on feedback from anon, authenticated;
grant insert on feedback to anon;
grant select, insert, update, delete on feedback to authenticated;

-- The abuse brake. Security definer, because the count has to see every row,
-- not only the ones the sender may read. More than 20 in ten minutes from one
-- account, or more than 50 in ten minutes from signed-out visitors together,
-- is refused, and so is a text identical to one that arrived in the last hour
-- (from anyone). The time stamp is the database's, never the sender's.
-- The database sees no IP address, so signed-out senders share one bucket: a
-- flood of anonymous junk can fill it for everyone. While it is full the form
-- tells signed-out visitors to sign in (an account has its own bucket) or to
-- use the Email instead link, which is the expected way round it.
create or replace function feedback_brake()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.created_at := now();
  if exists (select 1 from feedback f
             where f.created_at > now() - interval '1 hour'
               and f.body = new.body) then
    raise exception 'This message already arrived.'
      using errcode = 'P0001', hint = 'duplicate';
  end if;
  if new.user_id is not null then
    if (select count(*) from feedback f
        where f.user_id = new.user_id
          and f.created_at > now() - interval '10 minutes') >= 20 then
      raise exception 'Too many messages in a short time. Try again in a few minutes.'
        using errcode = 'P0001', hint = 'rate_limited';
    end if;
  elsif (select count(*) from feedback f
         where f.user_id is null
           and f.created_at > now() - interval '10 minutes') >= 50 then
    raise exception 'Too many messages in a short time. Try again in a few minutes.'
      using errcode = 'P0001', hint = 'rate_limited';
  end if;
  return new;
end $$;
drop trigger if exists feedback_brake on feedback;
create trigger feedback_brake before insert on feedback
  for each row execute function feedback_brake();

-- An admin's edit carries its own time stamp.
create or replace function feedback_touch()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  new.created_at := old.created_at;
  return new;
end $$;
drop trigger if exists feedback_touch on feedback;
create trigger feedback_touch before update on feedback
  for each row execute function feedback_touch();

-- ---------- admin_stats(): what the admin panel shows ----------
-- Days are UTC days. Every list is capped, so the answer stays small.
-- The funnel counts tab sessions: viewed #/auth, then signup_submit, then
-- signup_ok, then league_join, each step within the same session. Someone who
-- confirms their email opens a new tab (a new session), so a join after
-- confirming shows up under league_join_any rather than in the last step.
create or replace function admin_stats(p_days int default 30)
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare
  d     int := greatest(1, least(coalesce(p_days, 30), 90));
  since timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_days, 30), 90)));
  r     jsonb;
begin
  if not is_site_admin() then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  with ev as (
    select * from app_events where created_at >= since
  )
  select jsonb_build_object(
    'days', d,
    'since', since,
    'generated_at', now(),
    'totals', (
      select jsonb_build_object(
        'events', count(*),
        'views', count(*) filter (where kind = 'view'),
        'actions', count(*) filter (where kind = 'action'),
        'errors', count(*) filter (where kind = 'error'),
        'sessions', count(distinct sid),
        'signed_in_sessions', count(distinct sid) filter (where signed_in)
      ) from ev
    ),
    'per_day', (
      select coalesce(jsonb_agg(jsonb_build_object(
          'day', g.day::date,
          'views', coalesce(x.views, 0),
          'sessions', coalesce(x.sessions, 0),
          'signed_in_sessions', coalesce(x.signed_in_sessions, 0)
        ) order by g.day), '[]'::jsonb)
      from generate_series(((now() at time zone 'utc')::date - (d - 1))::timestamp,
                           ((now() at time zone 'utc')::date)::timestamp,
                           interval '1 day') as g(day)
      left join (
        select (created_at at time zone 'utc')::date as day,
               count(*) filter (where kind = 'view') as views,
               count(distinct sid) as sessions,
               count(distinct sid) filter (where signed_in) as signed_in_sessions
        from ev group by 1
      ) x on x.day = g.day::date
    ),
    'top_paths', (
      select coalesce(jsonb_agg(jsonb_build_object('path', t.path, 'views', t.views, 'sessions', t.sessions)
                                order by t.views desc, t.path), '[]'::jsonb)
      from (
        select coalesce(path, '') as path, count(*) as views, count(distinct sid) as sessions
        from ev where kind = 'view'
        group by 1 order by 2 desc, 1 limit 25
      ) t
    ),
    'devices', (
      select coalesce(jsonb_agg(jsonb_build_object('device', t.device, 'sessions', t.sessions, 'events', t.events)
                                order by t.sessions desc), '[]'::jsonb)
      from (
        select coalesce(device, 'unknown') as device, count(distinct sid) as sessions, count(*) as events
        from ev group by 1
      ) t
    ),
    'top_actions', (
      select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'count', t.n, 'sessions', t.sessions)
                                order by t.n desc, t.name), '[]'::jsonb)
      from (
        select name, count(*) as n, count(distinct sid) as sessions
        from ev where kind = 'action'
        group by name order by 2 desc, 1 limit 40
      ) t
    ),
    'errors', (
      select coalesce(jsonb_agg(jsonb_build_object(
          'name', t.name, 'count', t.n, 'hits', t.hits, 'sessions', t.sessions,
          'first_seen', t.first_seen, 'last_seen', t.last_seen,
          'sample_path', t.sample_path, 'sample_detail', t.sample_detail
        ) order by t.sessions desc, t.last_seen desc), '[]'::jsonb)
      from (
        select name,
               count(*) as n,
               sum(case when jsonb_typeof(detail -> 'n') = 'number'
                        then least((detail ->> 'n')::numeric, 100000) else 1 end) as hits,
               count(distinct sid) as sessions,
               min(created_at) as first_seen,
               max(created_at) as last_seen,
               (array_agg(path order by created_at desc))[1] as sample_path,
               (array_agg(detail order by created_at desc))[1] as sample_detail
        from ev where kind = 'error'
        group by name
        order by count(distinct sid) desc, max(created_at) desc
        limit 50
      ) t
    ),
    'funnel', (
      select jsonb_build_object(
        'auth_view', count(*) filter (where a),
        'signup_submit', count(*) filter (where a and s),
        'signup_ok', count(*) filter (where a and s and o),
        'league_join', count(*) filter (where a and s and o and j),
        'signup_ok_any', count(*) filter (where o),
        'league_join_any', count(*) filter (where j)
      )
      from (
        select sid,
               bool_or(kind = 'view' and path like '#/auth%') as a,
               bool_or(kind = 'action' and name = 'signup_submit') as s,
               bool_or(kind = 'action' and name = 'signup_ok') as o,
               bool_or(kind = 'action' and name = 'league_join') as j
        from ev group by sid
      ) f
    ),
    'feedback', (
      select jsonb_build_object(
        'total', count(*),
        'new', count(*) filter (where status = 'new'),
        'seen', count(*) filter (where status = 'seen'),
        'done', count(*) filter (where status = 'done'),
        'in_period', count(*) filter (where created_at >= since)
      ) from feedback
    )
  ) into r;

  return r;
end $$;
revoke all on function admin_stats(int) from public, anon;
grant execute on function admin_stats(int) to authenticated;

-- ---------- purge_old_rows(): the 90-day and 12-month limits ----------
-- Statistics older than 90 days and feedback older than 12 months go. Nobody
-- can call this over the API; pg_cron runs it every night (below), the
-- app_events trigger clears expired rows in batches, and purge_app_events()
-- lets the admin panel run it on demand.
create or replace function purge_old_rows()
returns integer language plpgsql security definer set search_path = public as $$
declare n integer; m integer;
begin
  delete from app_events where created_at < now() - interval '90 days';
  get diagnostics n = row_count;
  delete from feedback where created_at < now() - interval '12 months';
  get diagnostics m = row_count;
  return n + m;
end $$;
revoke all on function purge_old_rows() from public, anon, authenticated;

-- The admin panel calls this each time it is opened.
create or replace function purge_app_events()
returns integer language plpgsql security definer set search_path = public as $$
begin
  if not is_site_admin() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return purge_old_rows();
end $$;
revoke all on function purge_app_events() from public, anon;
grant execute on function purge_app_events() to authenticated;

-- Every night at 03:17 UTC through pg_cron. If the extension cannot be turned
-- on here (Dashboard > Database > Extensions), the rest of this section still
-- runs and the trigger above keeps the limits. Re-running replaces the job.
do $$
begin
  begin
    create extension if not exists pg_cron with schema pg_catalog;
  exception when others then
    raise notice 'pg_cron is not available (%); expired rows are cleared by the app_events trigger only.', sqlerrm;
  end;
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      perform cron.unschedule(j.jobid) from cron.job j where j.jobname = 'sl-purge-old-rows';
      perform cron.schedule('sl-purge-old-rows', '17 3 * * *', 'select public.purge_old_rows()');
    exception when others then
      raise notice 'Could not schedule sl-purge-old-rows (%).', sqlerrm;
    end;
  end if;
end $$;

-- ============================================================
--  OPPONENT CONFIRMATION (confirm_match)
-- ============================================================
-- A reported match used to wait for an organizer. Now the player on the other
-- side of the report can confirm it too: the winner or the loser who is not
-- the one who reported it, while still an active member of the league.
-- Organizers can confirm any match of their league. Nothing else about a
-- match changes here, and the update policies on matches stay as they are.
-- An archived league takes no confirmations. Confirming a match that is
-- already confirmed does nothing, so "Confirm all" can be repeated safely.
-- The site falls back to the organizer's direct update until this exists.
--
-- The reporter can still edit an unconfirmed report, so the caller passes the
-- players, Seekers and terrains it showed, and the match is confirmed only
-- when the row still says exactly that. Otherwise it is refused with
-- "This match was changed ...", and the site reloads the list.
--
-- Safe to run more than once.
drop function if exists confirm_match(uuid);
create or replace function confirm_match(
  p_match uuid,
  p_winner uuid, p_loser uuid,
  p_winner_seeker text, p_loser_seeker text,
  p_winner_terrain text, p_loser_terrain text)
returns void language plpgsql security definer set search_path = public as $$
declare m matches%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Sign in to confirm a match' using errcode = '42501';
  end if;
  select * into m from matches where id = p_match for update;
  if not found then
    raise exception 'Match not found' using errcode = 'P0002';
  end if;
  if not (
    is_league_admin(m.league_id)
    or (
      auth.uid() in (m.winner_id, m.loser_id)
      and m.reported_by is distinct from auth.uid()
      and is_active_member(m.league_id)
    )
  ) then
    raise exception 'Only your opponent or an organizer can confirm this match' using errcode = '42501';
  end if;
  if exists (select 1 from leagues l where l.id = m.league_id and l.archived_at is not null) then
    raise exception 'This league is archived' using errcode = '42501';
  end if;
  if m.confirmed then
    return;
  end if;
  if m.winner_id is distinct from p_winner
     or m.loser_id is distinct from p_loser
     or m.winner_seeker is distinct from p_winner_seeker
     or m.loser_seeker is distinct from p_loser_seeker
     or m.winner_terrain is distinct from p_winner_terrain
     or m.loser_terrain is distinct from p_loser_terrain then
    raise exception 'This match was changed since you opened it. Check it again before confirming.'
      using errcode = 'P0001', hint = 'sl_match_changed';
  end if;
  update matches set confirmed = true where id = p_match;
end $$;
revoke all on function confirm_match(uuid, uuid, uuid, text, text, text, text) from public, anon;
grant execute on function confirm_match(uuid, uuid, uuid, text, text, text, text) to authenticated;

-- ============================================================
--  RETIRED PLAYERS CANNOT REJOIN BY THEMSELVES
-- ============================================================
-- join_league() clears dropped_at, so a player an organizer had retired could
-- come straight back with the join code (or one tap on a public league).
-- memberships.dropped_by now records who set dropped_at: the player when they
-- leave, the organizer when they retire someone. A trigger fills it in, so
-- nobody can write it directly. join_league() lets a player back in only when
-- they were the one who left; anyone else is told to ask an organizer, who
-- can restore them (clearing dropped_at clears dropped_by too).
-- Rows dropped before this column existed have no dropped_by and are treated
-- as retired by an organizer, the safe reading.
alter table memberships add column if not exists dropped_by uuid;

create or replace function stamp_membership_drop()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.dropped_at is null then
    new.dropped_by := null;
  elsif old.dropped_at is null then
    new.dropped_by := auth.uid();
  else
    new.dropped_by := old.dropped_by;
  end if;
  return new;
end $$;

drop trigger if exists membership_drop_stamp on memberships;
create trigger membership_drop_stamp before update on memberships
  for each row execute function stamp_membership_drop();

create or replace function join_league(p_code text default null, p_league uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  l   leagues%rowtype;
  m   memberships%rowtype;
begin
  if uid is null then
    raise exception 'Sign in first';
  end if;
  if coalesce(trim(p_code), '') <> '' then
    select * into l from leagues where upper(join_code) = upper(trim(p_code));
  elsif p_league is not null then
    select * into l from leagues where leagues.id = p_league and is_public;
  end if;
  if l.id is null then
    raise exception 'No league with that code';
  end if;
  if l.archived_at is not null then
    raise exception 'This league is archived';
  end if;
  select * into m from memberships where league_id = l.id and user_id = uid;
  if found and m.dropped_at is not null and m.dropped_by is distinct from uid then
    raise exception 'An organizer retired you from this league. Ask them to restore you.'
      using errcode = '42501';
  end if;
  insert into memberships (league_id, user_id) values (l.id, uid)
    on conflict (league_id, user_id) do update set dropped_at = null;
  return jsonb_build_object('id', l.id, 'name', l.name);
end $$;

revoke all on function join_league(text, uuid) from public, anon;
grant execute on function join_league(text, uuid) to authenticated;

-- ============================================================
--  SELF CHECK-IN OPENS ON THE DAY OF THE EVENT
-- ============================================================
-- A player could check themselves in to an event days ahead, and the
-- standings counted that attendance at once. Checking yourself in now also
-- needs the event date to have begun. Leagues have no time zone, so "begun"
-- means begun anywhere on Earth: the date in UTC+14, the earliest zone
-- ('Etc/GMT-14' is UTC+14; the sign in Etc/ names is inverted). The app hides
-- check-in until the event date in the viewer's own time zone, which is never
-- later than that. Organizers are not affected: the attendance insert policy
-- lets is_league_admin() check anyone in at any time without this function.
create or replace function can_check_in(p_session uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1
    from sessions s
    join leagues l on l.id = s.league_id
    join memberships m on m.league_id = s.league_id
                      and m.user_id = auth.uid()
                      and m.dropped_at is null
    where s.id = p_session
      and s.closed_at is null
      and l.archived_at is null
      and s.date <= (now() at time zone 'Etc/GMT-14')::date
  );
$$;

-- ============================================================
--  A TOURNAMENT BELONGS TO AN EVENT AND SCORES THROUGH IT
-- ============================================================
-- A tournament (groups and bracket, payload v2) used to live on its own: its
-- results counted in win rates and the meta but never in the standings, and
-- it checked nobody in. Now a tournament is linked to a Tournament event
-- (tournaments.session_id) and sync_tournament() makes that event's matches
-- say exactly what the tournament says:
--   * every decided game becomes one confirmed match of the event, with each
--     player's Seeker, terrain and deck from their tournament entry. A game is
--     found again by matches.t_ref, its place in the payload:
--       'g:<i>'      the i-th entry of payload.gm (0-based), a group game;
--       'b:<r>:<k>'  payload.bracket[r][k] (0-based), a knockout game.
--     A bye (one side empty) was never played and is not a match. A corrected
--     result updates its match, a cleared one deletes it, and discarding the
--     tournament deletes them all (on delete cascade);
--   * every entrant is checked in to the event. Nobody is ever checked out;
--   * a finalized tournament closes its event, a reopened one reopens it;
--   * the event becomes a Tournament event for good (is_tournament, t_linked).
-- Entrant ids are profile ids (the app picks entrants from the league's
-- members). An id with no profile behind it, an account deleted since, is
-- left out of the matches and the attendance instead of failing the call.
--
-- Points: the app counts a match with a tournament_id double. At an event with
-- t_linked set, any other match (logged by hand) counts once. Events from
-- before this change have t_linked false and no tournament matches, so an
-- is_tournament event of theirs still counts every match double, as it did.
-- t_linked stays set when the tournament is discarded, so such an event does
-- not fall back to the old rule.
--
-- The app calls sync_tournament() after every change it saves to a linked
-- tournament. Until this section has run it links nothing and works as before.
-- Safe to run more than once.
alter table tournaments add column if not exists session_id uuid references sessions(id) on delete set null;
alter table matches     add column if not exists tournament_id uuid references tournaments(id) on delete cascade;
alter table matches     add column if not exists t_ref text;
alter table sessions    add column if not exists t_linked boolean not null default false;

-- One tournament per event: two would each open and close the same event from
-- their own payload. (An earlier draft of this section made a plain index.)
drop index if exists idx_tournaments_session;
create unique index if not exists tournaments_session_one
  on tournaments(session_id) where session_id is not null;
create unique index if not exists matches_tournament_ref
  on matches(tournament_id, t_ref) where tournament_id is not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'matches_t_ref_needed') then
    alter table matches add constraint matches_t_ref_needed
      check (tournament_id is null or t_ref is not null);
  end if;
end $$;

-- A match with a tournament_id counts double and the app will not edit or
-- delete it, so only sync_tournament() may write these two columns. The match
-- policies let a player write their own report and an organizer any match,
-- with any value in them; this trigger refuses a request from the site that
-- sets them on a new match or changes them on an existing one.
-- Not security definer on purpose: current_user is then the caller's role.
-- Requests from the site run as 'authenticated' or 'anon'; sync_tournament()
-- runs as its owner and passes, as does the SQL editor.
create or replace function guard_match_tournament()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.tournament_id is not null or new.t_ref is not null then
      raise exception 'Tournament results are recorded in the Tournament tab' using errcode = '42501';
    end if;
  elsif new.tournament_id is distinct from old.tournament_id or new.t_ref is distinct from old.t_ref then
    raise exception 'Tournament results are recorded in the Tournament tab' using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists match_tournament_guard on matches;
create trigger match_tournament_guard before insert or update on matches
  for each row execute function guard_match_tournament();

-- The decided games of a v2 payload, one row per game, in the shape of a
-- match. Not callable over the API: only sync_tournament() uses it.
create or replace function tournament_games(p jsonb)
returns table (
  ref text, winner_id uuid, loser_id uuid,
  winner_seeker text, loser_seeker text,
  winner_terrain text, loser_terrain text,
  winner_deck_id uuid, loser_deck_id uuid
)
language sql stable set search_path = public as $$
  with ent as (
    select distinct on (e->>'id')
           e->>'id' as id,
           nullif(left(coalesce(e->>'seeker', ''), 80), '')  as seeker,
           nullif(left(coalesce(e->>'terrain', ''), 80), '') as terrain,
           nullif(e->>'deckId', '') as deck_id
    from jsonb_array_elements(case when jsonb_typeof(p->'entrants') = 'array' then p->'entrants' else '[]'::jsonb end) as e
    where jsonb_typeof(e) = 'object' and e->>'id' is not null
    order by e->>'id'
  ),
  raw as (
    -- group game: { g, a, b, w } where w is the winner's id (or null)
    select 'g:' || (x.o - 1) as ref,
           x.m->>'a' as a, x.m->>'b' as b,
           case when x.m->>'w' = x.m->>'a' then 'a'
                when x.m->>'w' = x.m->>'b' then 'b' end as side
    from jsonb_array_elements(case when jsonb_typeof(p->'gm') = 'array' then p->'gm' else '[]'::jsonb end)
         with ordinality as x(m, o)
    where jsonb_typeof(x.m) = 'object'
    union all
    -- knockout game: { a: {id} | null, b: {id} | null, winner: 'a' | 'b' | null }
    select 'b:' || (r.o - 1) || ':' || (q.o - 1),
           q.m->'a'->>'id', q.m->'b'->>'id', q.m->>'winner'
    from jsonb_array_elements(case when jsonb_typeof(p->'bracket') = 'array' then p->'bracket' else '[]'::jsonb end)
         with ordinality as r(rd, o)
    cross join lateral jsonb_array_elements(case when jsonb_typeof(r.rd) = 'array' then r.rd else '[]'::jsonb end)
         with ordinality as q(m, o)
    where jsonb_typeof(q.m) = 'object'
  ),
  won as (
    select raw.ref,
           case when raw.side = 'a' then raw.a else raw.b end as w,
           case when raw.side = 'a' then raw.b else raw.a end as l
    from raw
    where raw.side in ('a', 'b') and raw.a is not null and raw.b is not null and raw.a <> raw.b
  )
  select won.ref, pw.id, pl.id, ew.seeker, el.seeker, ew.terrain, el.terrain, dw.id, dl.id
  from won
  join profiles pw on pw.id::text = won.w
  join profiles pl on pl.id::text = won.l
  left join ent ew on ew.id = won.w
  left join ent el on el.id = won.l
  left join decks dw on dw.id::text = ew.deck_id
  left join decks dl on dl.id::text = el.deck_id;
$$;

revoke all on function tournament_games(jsonb) from public, anon, authenticated;

create or replace function sync_tournament(p_tournament uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := auth.uid();
  v_t    tournaments%rowtype;
  v_s    sessions%rowtype;
  v_fin  boolean;
  v_refs text[];
  v_up   int := 0;
  v_del  int := 0;
  v_att  int := 0;
begin
  if v_uid is null then
    raise exception 'Sign in first' using errcode = '42501';
  end if;
  select * into v_t from tournaments where id = p_tournament for update;
  if not found then
    raise exception 'Tournament not found' using errcode = 'P0002';
  end if;
  if not is_league_admin(v_t.league_id) then
    raise exception 'Only an organizer of this league can do that' using errcode = '42501';
  end if;
  if exists (select 1 from leagues l where l.id = v_t.league_id and l.archived_at is not null) then
    raise exception 'This league is archived' using errcode = '42501';
  end if;
  if v_t.session_id is null then
    raise exception 'This tournament is not linked to an event' using errcode = 'P0001';
  end if;
  select * into v_s from sessions where id = v_t.session_id for update;
  if not found or v_s.league_id <> v_t.league_id then
    raise exception 'The tournament''s event is not in its league' using errcode = 'P0001';
  end if;
  if coalesce(v_t.payload->>'v', '') <> '2' then
    raise exception 'This tournament cannot be linked to an event' using errcode = 'P0001';
  end if;
  v_fin := coalesce(v_t.payload->>'finalized', 'false') = 'true';

  select coalesce(array_agg(g.ref), '{}') into v_refs from tournament_games(v_t.payload) g;

  delete from matches mt
  where mt.tournament_id = v_t.id
    and not (mt.t_ref = any (v_refs));
  get diagnostics v_del = row_count;

  insert into matches (session_id, league_id, winner_id, loser_id,
                       winner_seeker, loser_seeker, winner_terrain, loser_terrain,
                       winner_deck_id, loser_deck_id, reported_by, confirmed,
                       tournament_id, t_ref)
  select v_s.id, v_t.league_id, g.winner_id, g.loser_id,
         g.winner_seeker, g.loser_seeker, g.winner_terrain, g.loser_terrain,
         g.winner_deck_id, g.loser_deck_id, v_uid, true,
         v_t.id, g.ref
  from tournament_games(v_t.payload) g
  on conflict (tournament_id, t_ref) where tournament_id is not null do update set
    session_id     = excluded.session_id,
    league_id      = excluded.league_id,
    winner_id      = excluded.winner_id,
    loser_id       = excluded.loser_id,
    winner_seeker  = excluded.winner_seeker,
    loser_seeker   = excluded.loser_seeker,
    winner_terrain = excluded.winner_terrain,
    loser_terrain  = excluded.loser_terrain,
    winner_deck_id = excluded.winner_deck_id,
    loser_deck_id  = excluded.loser_deck_id,
    confirmed      = true
  where (matches.session_id, matches.league_id, matches.winner_id, matches.loser_id,
         matches.winner_seeker, matches.loser_seeker, matches.winner_terrain, matches.loser_terrain,
         matches.winner_deck_id, matches.loser_deck_id, matches.confirmed)
        is distinct from
        (excluded.session_id, excluded.league_id, excluded.winner_id, excluded.loser_id,
         excluded.winner_seeker, excluded.loser_seeker, excluded.winner_terrain, excluded.loser_terrain,
         excluded.winner_deck_id, excluded.loser_deck_id, excluded.confirmed);
  get diagnostics v_up = row_count;

  insert into attendance (session_id, user_id)
  select distinct v_s.id, p.id
  from jsonb_array_elements(case when jsonb_typeof(v_t.payload->'entrants') = 'array'
                                 then v_t.payload->'entrants' else '[]'::jsonb end) as e
  join profiles p on p.id::text = e->>'id'
  on conflict (session_id, user_id) do nothing;
  get diagnostics v_att = row_count;

  update sessions
  set is_tournament = true,
      t_linked = true,
      closed_at = case when v_fin then coalesce(closed_at, now()) end
  where id = v_s.id
    and (not is_tournament or not t_linked
         or (v_fin and closed_at is null) or (not v_fin and closed_at is not null));

  return jsonb_build_object(
    'games', coalesce(array_length(v_refs, 1), 0),
    'saved', v_up, 'removed', v_del, 'checked_in', v_att, 'closed', v_fin);
end $$;

revoke all on function sync_tournament(uuid) from public, anon;
grant execute on function sync_tournament(uuid) to authenticated;

-- ============================================================
--  SECURITY HARDENING (2026-11-06)
-- ============================================================
-- Same SQL as migration-2026-11-06.sql (whose header lists every change and
-- ends with read-only checks). It replaces several definitions made further
-- up: is_league_admin, guard_league_owner, stamp_membership_drop,
-- guard_membership_update, join_league, sync_tournament, app_events_stamp,
-- app_events_brake, feedback_brake, handle_new_user, and the policies on
-- memberships, attendance, matches, tournaments (insert/update) and
-- announcements (delete). The migration wraps it in begin/commit.


begin;

-- ============================================================
--  0. NEW COLUMNS AND SMALL HELPERS
-- ============================================================
alter table profiles add column if not exists deleted_at timestamptz;

-- The league owner (and nobody else) — used by the membership insert policy.
create or replace function is_league_owner(p_league uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from leagues l where l.id = p_league and l.owner_id = auth.uid());
$$;

-- Owner, or a co-organizer who has not been dropped. A retired co-organizer
-- keeps reading the league like any retired player and nothing more.
create or replace function is_league_admin(p_league uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from leagues l where l.id = p_league and l.owner_id = auth.uid()
  ) or exists (
    select 1 from memberships m
    where m.league_id = p_league and m.user_id = auth.uid()
      and m.is_admin and m.dropped_at is null
  );
$$;

-- Is p_user an active (not dropped) member of p_league, with an account that
-- was not deleted? Answers only about leagues whose member list the caller
-- may read anyway.
create or replace function league_player_active(p_league uuid, p_user uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from memberships m join profiles p on p.id = m.user_id
    where m.league_id = p_league and m.user_id = p_user and m.dropped_at is null
      and p.deleted_at is null
  ) and (league_is_public(p_league) or is_league_member(p_league) or is_league_owner(p_league));
$$;

-- An event that still takes results from players: not finished, league not archived.
create or replace function session_is_open(p_session uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from sessions s join leagues l on l.id = s.league_id
    where s.id = p_session and s.closed_at is null and l.archived_at is null
  );
$$;

-- A fresh join code in the app's own alphabet (no 0/O/1/I), from the strong
-- random source behind gen_random_uuid(). 256 is a multiple of 32, so no bias.
create or replace function gen_join_code()
returns text language plpgsql volatile security definer set search_path = public as $$
declare
  a constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  b bytea;
  c text;
  n int := 0;
begin
  loop
    b := uuid_send(gen_random_uuid());
    c := '';
    for i in 0..5 loop
      c := c || substr(a, (get_byte(b, i) % 32) + 1, 1);
    end loop;
    exit when not exists (select 1 from leagues where upper(join_code) = c);
    n := n + 1;
    if n > 50 then
      raise exception 'Could not find a free join code';
    end if;
  end loop;
  return c;
end $$;

-- The quota checks. Each raises when the caller is over the limit.
create or replace function check_league_quota()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    return;
  end if;
  if (select count(*) from leagues
      where owner_id = auth.uid() and created_at > now() - interval '1 day') >= 5 then
    raise exception 'You created 5 leagues in the last 24 hours. Try again tomorrow.'
      using errcode = 'P0001', hint = 'rate_limited';
  end if;
  if (select count(*) from leagues
      where owner_id = auth.uid() and archived_at is null) >= 20 then
    raise exception 'You already run 20 open leagues. Archive one before creating another.'
      using errcode = 'P0001', hint = 'rate_limited';
  end if;
end $$;

create or replace function check_match_quota()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    return;
  end if;
  if (select count(*) from matches
      where reported_by = auth.uid() and created_at > now() - interval '1 day') >= 200 then
    raise exception 'You logged 200 matches in the last 24 hours. Try again later.'
      using errcode = 'P0001', hint = 'rate_limited';
  end if;
end $$;

create or replace function check_notice_quota(p_league uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_league is null then
    return;
  end if;
  if (select count(*) from announcements
      where league_id = p_league and created_at > now() - interval '1 day') >= 10 then
    raise exception 'This league posted 10 notices in the last 24 hours. Try again tomorrow.'
      using errcode = 'P0001', hint = 'rate_limited';
  end if;
end $$;

revoke all on function is_league_owner(uuid)              from public, anon;
revoke all on function league_player_active(uuid, uuid)   from public, anon;
revoke all on function session_is_open(uuid)              from public, anon;
revoke all on function gen_join_code()                    from public, anon;
revoke all on function check_league_quota()               from public, anon;
revoke all on function check_match_quota()                from public, anon;
revoke all on function check_notice_quota(uuid)           from public, anon;
grant execute on function is_league_owner(uuid)            to authenticated;
grant execute on function league_player_active(uuid, uuid) to authenticated;
grant execute on function session_is_open(uuid)            to authenticated;
grant execute on function gen_join_code()                  to authenticated;
grant execute on function check_league_quota()             to authenticated;
grant execute on function check_match_quota()              to authenticated;
grant execute on function check_notice_quota(uuid)         to authenticated;

create index if not exists idx_matches_reporter_created on matches(reported_by, created_at);
create index if not exists idx_leagues_owner on leagues(owner_id);
create index if not exists idx_announcements_league_created on announcements(league_id, created_at);

-- ============================================================
--  1. JOIN CODES
-- ============================================================
-- Codes the app makes are 6 characters from A-Z/2-9. The check is a little
-- wider (A-Z, 0-9, 4 to 12) so older codes keep working. A lower-case code is
-- upper-cased (join_league compares upper-cased anyway); anything else that
-- does not fit gets a fresh code. On the live data this changes nothing.
update leagues set join_code = upper(join_code)
 where join_code ~ '^[A-Za-z0-9]{4,12}$' and join_code <> upper(join_code)
   and not exists (select 1 from leagues l2 where l2.join_code = upper(leagues.join_code));
update leagues set join_code = gen_join_code()
 where join_code is null or join_code !~ '^[A-Z0-9]{4,12}$';

do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'leagues_join_code_format' and conrelid = 'public.leagues'::regclass) then
    alter table leagues add constraint leagues_join_code_format
      check (join_code ~ '^[A-Z0-9]{4,12}$') not valid;
  end if;
end $$;
alter table leagues validate constraint leagues_join_code_format;

-- Updates to a league from the site:
--   * going from public to private rotates the join code (it was readable by
--     anyone while the league was public);
--   * a site admin who is not an organizer of the league may only archive or
--     reopen it.
-- Not security definer on purpose: current_user is then the caller's role.
create or replace function guard_league_update()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if not is_league_admin(old.id) then
    if (to_jsonb(new) - 'archived_at') is distinct from (to_jsonb(old) - 'archived_at') then
      raise exception 'A site admin can only archive or reopen a league' using errcode = '42501';
    end if;
    return new;
  end if;
  if old.is_public and not new.is_public and new.join_code is not distinct from old.join_code then
    new.join_code := gen_join_code();
  end if;
  return new;
end $$;
drop trigger if exists league_update_guard on leagues;
create trigger league_update_guard before update on leagues
  for each row execute function guard_league_update();

-- Handing a league over: still only the owner, and now only to an active
-- player of that league (the app already offers nobody else).
create or replace function guard_league_owner()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.owner_id is distinct from old.owner_id then
    if auth.uid() <> old.owner_id then
      raise exception 'Only the league owner can hand the league over';
    end if;
    if auth.uid() is not null and not exists (
      select 1 from memberships m
      where m.league_id = new.id and m.user_id = new.owner_id and m.dropped_at is null
    ) then
      raise exception 'The new owner must be an active player of this league';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists league_owner_guard on leagues;
create trigger league_owner_guard before update on leagues
  for each row execute function guard_league_owner();

-- A new league from the site: database time stamp and the creation quota.
create or replace function guard_league_insert()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  new.created_at := now();
  new.archived_at := null;  -- a league starts open, so it counts towards the 20
  perform check_league_quota();
  return new;
end $$;
drop trigger if exists league_insert_guard on leagues;
create trigger league_insert_guard before insert on leagues
  for each row execute function guard_league_insert();

-- ============================================================
--  2, 3, 7. MEMBERSHIPS
-- ============================================================
-- Every policy on memberships is dropped and the full set recreated, so a
-- policy added by hand cannot keep a hole open.
do $$
declare p record;
begin
  for p in select policyname from pg_policies where schemaname = 'public' and tablename = 'memberships' loop
    execute format('drop policy %I on public.memberships', p.policyname);
  end loop;
end $$;

create policy "memberships visible" on memberships
  for select using (
    user_id = auth.uid() or is_league_member(league_id) or league_is_public(league_id)
  );

-- The only direct insert left: the owner's own row, right after creating the
-- league. Everyone else joins through join_league().
create policy "owner adds own row" on memberships
  for insert with check (user_id = auth.uid() and is_league_owner(league_id));

create policy "members update own or organizers" on memberships
  for update using (user_id = auth.uid() or is_league_admin(league_id))
  with check (user_id = auth.uid() or is_league_admin(league_id));

-- Only an organizer removes a row. A player leaves by setting dropped_at (the
-- app never deletes): a deleted row would let a retired player come back as
-- a new member, or wipe their tournament games at the next sync.
create policy "admin removes" on memberships
  for delete using (is_league_admin(league_id));

-- Who dropped a row, and a dropped row is never an organizer. Runs before
-- membership_update_guard (triggers fire in name order).
create or replace function stamp_membership_drop()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.dropped_at is null then
    new.dropped_by := null;
  elsif old.dropped_at is null then
    new.dropped_by := auth.uid();
    new.is_admin := false;
  else
    new.dropped_by := old.dropped_by;
    new.is_admin := false;
  end if;
  return new;
end $$;
drop trigger if exists membership_drop_stamp on memberships;
create trigger membership_drop_stamp before update on memberships
  for each row execute function stamp_membership_drop();

-- Not security definer on purpose: current_user is then the caller's role.
-- A retired co-organizer is not is_league_admin() any more, so they take the
-- player path below and cannot clear their own dropped_at (the owner can).
-- Organizers can restore a player they retired ("Restore" in the app), but
-- not one who left by themselves: that is the player's decision, and the
-- player can rejoin with the code. Nobody brings back a deleted account.
create or replace function guard_membership_update()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if new.league_id is distinct from old.league_id or new.user_id is distinct from old.user_id then
    raise exception 'A membership cannot be moved';
  end if;
  if old.dropped_at is not null and new.dropped_at is null
     and exists (select 1 from profiles p where p.id = old.user_id and p.deleted_at is not null) then
    raise exception 'This account was deleted' using errcode = '42501';
  end if;
  if is_league_admin(old.league_id) then
    if old.dropped_at is not null and new.dropped_at is null
       and old.user_id is distinct from auth.uid()
       and old.dropped_by is not distinct from old.user_id then
      raise exception 'This player left the league themselves. They can rejoin with the join code.'
        using errcode = '42501';
    end if;
    return new;
  end if;
  if new.is_admin is distinct from old.is_admin or new.joined_at is distinct from old.joined_at then
    raise exception 'Only an organizer can change that';
  end if;
  if old.dropped_at is not null and new.dropped_at is null then
    raise exception 'Use the join code to come back';
  end if;
  return new;
end $$;
drop trigger if exists membership_update_guard on memberships;
create trigger membership_update_guard before update on memberships
  for each row execute function guard_membership_update();

-- One-time cleanup: a dropped row is never an organizer.
update memberships set is_admin = false where dropped_at is not null and is_admin;

-- join_league(): unchanged, except that a deleted account cannot join.
create or replace function join_league(p_code text default null, p_league uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  l   leagues%rowtype;
  m   memberships%rowtype;
begin
  if uid is null then
    raise exception 'Sign in first';
  end if;
  if exists (select 1 from profiles p where p.id = uid and p.deleted_at is not null) then
    raise exception 'This account was deleted' using errcode = '42501';
  end if;
  if coalesce(trim(p_code), '') <> '' then
    select * into l from leagues where upper(join_code) = upper(trim(p_code));
  elsif p_league is not null then
    select * into l from leagues where leagues.id = p_league and is_public;
  end if;
  if l.id is null then
    raise exception 'No league with that code';
  end if;
  if l.archived_at is not null then
    raise exception 'This league is archived';
  end if;
  select * into m from memberships where league_id = l.id and user_id = uid;
  if found and m.dropped_at is not null and m.dropped_by is distinct from uid then
    raise exception 'An organizer retired you from this league. Ask them to restore you.'
      using errcode = '42501';
  end if;
  insert into memberships (league_id, user_id) values (l.id, uid)
    on conflict (league_id, user_id) do update set dropped_at = null;
  return jsonb_build_object('id', l.id, 'name', l.name);
end $$;
revoke all on function join_league(text, uuid) from public, anon;
grant execute on function join_league(text, uuid) to authenticated;

-- ============================================================
--  2. ATTENDANCE
-- ============================================================
do $$
declare p record;
begin
  for p in select policyname from pg_policies where schemaname = 'public' and tablename = 'attendance' loop
    execute format('drop policy %I on public.attendance', p.policyname);
  end loop;
end $$;

create policy "attendance visible" on attendance
  for select using (
    user_id = auth.uid()
    or is_league_member(session_league(session_id))
    or league_is_public(session_league(session_id))
  );

-- An organizer checks in active players of their league; a player checks
-- themselves in through can_check_in().
create policy "self or admin attendance" on attendance
  for insert with check (
    (is_league_admin(session_league(session_id))
       and league_player_active(session_league(session_id), user_id))
    or (user_id = auth.uid() and can_check_in(session_id))
  );

create policy "self or admin remove attendance" on attendance
  for delete using (
    user_id = auth.uid() or is_league_admin(session_league(session_id))
  );

-- ============================================================
--  2, 6, 8. MATCHES
-- ============================================================
do $$
declare p record;
begin
  for p in select policyname from pg_policies where schemaname = 'public' and tablename = 'matches' loop
    execute format('drop policy %I on public.matches', p.policyname);
  end loop;
end $$;

create policy "matches visible" on matches
  for select using (
    is_league_member(league_id)
    or exists (select 1 from leagues l where l.id = league_id and l.is_public)
  );

-- So the site admin can find (and delete) a match in a private league too.
create policy "site admin reads matches" on matches
  for select using (is_site_admin());

-- Both players are active members of the league, whoever writes the match.
-- An organizer may write any such match; a player only their own unconfirmed
-- report, in an open event of a league that is not archived.
create policy "own match or admin" on matches
  for insert with check (
    session_league(session_id) = league_id
    and league_player_active(league_id, winner_id)
    and league_player_active(league_id, loser_id)
    and (
      is_league_admin(league_id)
      or (
        reported_by = auth.uid()
        and not confirmed
        and (winner_id = auth.uid() or loser_id = auth.uid())
        and is_active_member(league_id)
        and session_is_open(session_id)
      )
    )
  );

-- Changing the players of an existing match is checked by match_write_guard
-- (a policy cannot tell a changed player from an unchanged one).
create policy "edit own unconfirmed or admin" on matches
  for update using (
    is_league_admin(league_id)
    or (reported_by = auth.uid() and not confirmed)
  ) with check (
    session_league(session_id) = league_id
    and (
      is_league_admin(league_id)
      or (
        reported_by = auth.uid()
        and not confirmed
        and (winner_id = auth.uid() or loser_id = auth.uid())
        and is_active_member(league_id)
        and session_is_open(session_id)
      )
    )
  );

-- The reporter withdraws, or the named opponent rejects, an unconfirmed
-- report. Organizers and the site admin can delete any match.
create policy "delete own unconfirmed or admin" on matches
  for delete using (
    is_league_admin(league_id)
    or is_site_admin()
    or (not confirmed and tournament_id is null
        and auth.uid() in (reported_by, winner_id, loser_id))
  );

-- Requests from the site: database time stamp, the per-reporter quota, both
-- players active members when a match is written or its players change, and
-- an open event for anyone who is not an organizer. Gives readable messages
-- before the policies above refuse. sync_tournament() and confirm_match()
-- run as their owner and pass.
-- Not security definer on purpose: current_user is then the caller's role.
create or replace function guard_match_write()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.created_at := now();
    perform check_match_quota();
  else
    new.created_at := old.created_at;
  end if;
  if tg_op = 'INSERT'
     or new.winner_id is distinct from old.winner_id
     or new.loser_id  is distinct from old.loser_id
     or new.league_id is distinct from old.league_id then
    if not (league_player_active(new.league_id, new.winner_id)
            and league_player_active(new.league_id, new.loser_id)) then
      raise exception 'Both players must be active members of this league' using errcode = '42501';
    end if;
  end if;
  if not is_league_admin(new.league_id) and not session_is_open(new.session_id) then
    raise exception 'This event is finished or the league is archived. Ask an organizer to add the result.'
      using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists match_write_guard on matches;
create trigger match_write_guard before insert or update on matches
  for each row execute function guard_match_write();

-- ============================================================
--  2. TOURNAMENTS: LINKED ONLY TO AN EVENT OF THE SAME LEAGUE
-- ============================================================
drop policy if exists "admins write tournaments" on tournaments;
create policy "admins write tournaments" on tournaments
  for insert with check (
    is_league_admin(league_id)
    and (session_id is null or session_league(session_id) = league_id)
  );

drop policy if exists "admins update tournaments" on tournaments;
create policy "admins update tournaments" on tournaments
  for update using (is_league_admin(league_id))
  with check (
    is_league_admin(league_id)
    and (session_id is null or session_league(session_id) = league_id)
  );

-- sync_tournament(): as before, but a game becomes a match only when both
-- players are active members whose account was not deleted, or when the same
-- game (same place, same winner and loser) is already saved for this
-- tournament. So a game played before someone left, was retired or deleted
-- their account stays, and no new game can be made up against them. An
-- entrant becomes a check-in on the same active rule. tournament_games() is
-- unchanged.
create or replace function sync_tournament(p_tournament uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := auth.uid();
  v_t    tournaments%rowtype;
  v_s    sessions%rowtype;
  v_fin  boolean;
  v_refs text[];
  v_up   int := 0;
  v_del  int := 0;
  v_att  int := 0;
begin
  if v_uid is null then
    raise exception 'Sign in first' using errcode = '42501';
  end if;
  select * into v_t from tournaments where id = p_tournament for update;
  if not found then
    raise exception 'Tournament not found' using errcode = 'P0002';
  end if;
  if not is_league_admin(v_t.league_id) then
    raise exception 'Only an organizer of this league can do that' using errcode = '42501';
  end if;
  if exists (select 1 from leagues l where l.id = v_t.league_id and l.archived_at is not null) then
    raise exception 'This league is archived' using errcode = '42501';
  end if;
  if v_t.session_id is null then
    raise exception 'This tournament is not linked to an event' using errcode = 'P0001';
  end if;
  select * into v_s from sessions where id = v_t.session_id for update;
  if not found or v_s.league_id <> v_t.league_id then
    raise exception 'The tournament''s event is not in its league' using errcode = 'P0001';
  end if;
  if coalesce(v_t.payload->>'v', '') <> '2' then
    raise exception 'This tournament cannot be linked to an event' using errcode = 'P0001';
  end if;
  v_fin := coalesce(v_t.payload->>'finalized', 'false') = 'true';

  select coalesce(array_agg(g.ref), '{}') into v_refs
  from tournament_games(v_t.payload) g
  where exists (select 1 from matches mt
                where mt.tournament_id = v_t.id and mt.t_ref = g.ref
                  and mt.winner_id = g.winner_id and mt.loser_id = g.loser_id)
     or (league_player_active(v_t.league_id, g.winner_id)
         and league_player_active(v_t.league_id, g.loser_id));

  delete from matches mt
  where mt.tournament_id = v_t.id
    and not (mt.t_ref = any (v_refs));
  get diagnostics v_del = row_count;

  insert into matches (session_id, league_id, winner_id, loser_id,
                       winner_seeker, loser_seeker, winner_terrain, loser_terrain,
                       winner_deck_id, loser_deck_id, reported_by, confirmed,
                       tournament_id, t_ref)
  select v_s.id, v_t.league_id, g.winner_id, g.loser_id,
         g.winner_seeker, g.loser_seeker, g.winner_terrain, g.loser_terrain,
         g.winner_deck_id, g.loser_deck_id, v_uid, true,
         v_t.id, g.ref
  from tournament_games(v_t.payload) g
  where g.ref = any (v_refs)
  on conflict (tournament_id, t_ref) where tournament_id is not null do update set
    session_id     = excluded.session_id,
    league_id      = excluded.league_id,
    winner_id      = excluded.winner_id,
    loser_id       = excluded.loser_id,
    winner_seeker  = excluded.winner_seeker,
    loser_seeker   = excluded.loser_seeker,
    winner_terrain = excluded.winner_terrain,
    loser_terrain  = excluded.loser_terrain,
    winner_deck_id = excluded.winner_deck_id,
    loser_deck_id  = excluded.loser_deck_id,
    confirmed      = true
  where (matches.session_id, matches.league_id, matches.winner_id, matches.loser_id,
         matches.winner_seeker, matches.loser_seeker, matches.winner_terrain, matches.loser_terrain,
         matches.winner_deck_id, matches.loser_deck_id, matches.confirmed)
        is distinct from
        (excluded.session_id, excluded.league_id, excluded.winner_id, excluded.loser_id,
         excluded.winner_seeker, excluded.loser_seeker, excluded.winner_terrain, excluded.loser_terrain,
         excluded.winner_deck_id, excluded.loser_deck_id, excluded.confirmed);
  get diagnostics v_up = row_count;

  insert into attendance (session_id, user_id)
  select distinct v_s.id, m.user_id
  from jsonb_array_elements(case when jsonb_typeof(v_t.payload->'entrants') = 'array'
                                 then v_t.payload->'entrants' else '[]'::jsonb end) as e
  join memberships m on m.league_id = v_t.league_id and m.user_id::text = e->>'id'
                    and m.dropped_at is null
  join profiles p on p.id = m.user_id and p.deleted_at is null
  on conflict (session_id, user_id) do nothing;
  get diagnostics v_att = row_count;

  update sessions
  set is_tournament = true,
      t_linked = true,
      closed_at = case when v_fin then coalesce(closed_at, now()) end
  where id = v_s.id
    and (not is_tournament or not t_linked
         or (v_fin and closed_at is null) or (not v_fin and closed_at is not null));

  return jsonb_build_object(
    'games', coalesce(array_length(v_refs, 1), 0),
    'saved', v_up, 'removed', v_del, 'checked_in', v_att, 'closed', v_fin);
end $$;
revoke all on function sync_tournament(uuid) from public, anon;
grant execute on function sync_tournament(uuid) to authenticated;

-- ============================================================
--  4, 6. NOTICES, EVENTS AND LEAGUES: QUOTA AND SITE-ADMIN MODERATION
-- ============================================================
-- The database's own time stamp on every notice (a client-chosen created_at
-- could pin a notice to the top of the board for ever), and at most 10
-- notices per league a day. Global notices (site admin) are not counted.
-- On update the original time stamp is kept, so a notice cannot be re-dated.
create or replace function stamp_announcement()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := now();
    if current_user in ('authenticated', 'anon') and new.league_id is not null then
      perform check_notice_quota(new.league_id);
    end if;
  else
    new.created_at := old.created_at;
  end if;
  return new;
end $$;
drop trigger if exists announcement_stamp on announcements;
create trigger announcement_stamp before insert or update on announcements
  for each row execute function stamp_announcement();

drop policy if exists "announcements delete" on announcements;
create policy "announcements delete" on announcements
  for delete using (
    is_site_admin()
    or (league_id is not null and is_league_admin(league_id))
  );

drop policy if exists "site admin deletes sessions" on sessions;
create policy "site admin deletes sessions" on sessions
  for delete using (is_site_admin());

-- Archive or reopen only: league_update_guard refuses any other change.
drop policy if exists "site admin archives leagues" on leagues;
create policy "site admin archives leagues" on leagues
  for update using (is_site_admin()) with check (is_site_admin());

-- An update or delete only reaches rows the caller can read, so the site
-- admin also reads private leagues, their events and their notices (matches
-- are covered in the matches section). Same reach as the SQL editor.
drop policy if exists "site admin reads leagues" on leagues;
create policy "site admin reads leagues" on leagues
  for select using (is_site_admin());
drop policy if exists "site admin reads sessions" on sessions;
create policy "site admin reads sessions" on sessions
  for select using (is_site_admin());
drop policy if exists "site admin reads announcements" on announcements;
create policy "site admin reads announcements" on announcements
  for select using (is_site_admin());

-- ============================================================
--  4. FREE-TIER BRAKES: APP_EVENTS AND FEEDBACK
-- ============================================================
-- app_events, per row: the database's time stamp, and anything oversized in
-- bytes is cut down rather than refused (a refusal switches statistics off
-- for that tab). The site already keeps name <= 240 characters, path <= 200
-- and detail <= 800 bytes; multi-byte text could make those 4x bigger.
create or replace function app_events_stamp()
returns trigger language plpgsql set search_path = public as $$
begin
  new.created_at := now();
  if octet_length(new.name) > 300 then
    new.name := left(new.name, 75);
  end if;
  if new.path is not null and octet_length(new.path) > 200 then
    new.path := '#/other';
  end if;
  if new.detail is not null and octet_length(new.detail::text) > 800 then
    new.detail := null;
  end if;
  return new;
end $$;
drop trigger if exists app_events_stamp on app_events;
create trigger app_events_stamp before insert on app_events
  for each row execute function app_events_stamp();

-- The flood brake, per request:
--   * at most 50 rows (the site sends 50 at most);
--   * at most 400 rows a minute and 8000 a day from everyone together. A tab
--     sends at most 300 events in its whole life (AN_MAX) and a normal visit
--     10 to 30, so 8000 a day is several hundred real visits;
--   * at most 80000 rows are kept: past that the oldest rows go first, so new
--     statistics and error reports always land and the table stays bounded
--     (about 20 MB with normal rows, about 140 MB if every row were at its
--     byte limit). At 80000 rows the 90 days hold up to about 900 events a
--     day; with more traffic the history is simply shorter than 90 days;
--   * a last stop if the table still passes 160 MB (the row count above comes
--     from the statistics collector and can lag, for example after a
--     restart): then nothing while it holds more than 20000 rows. Deleting
--     rows reopens it at once; vacuum full gives the space back.
-- Past a refusal the insert fails (hint rate_limited); the site then stops
-- sending for that tab. The trigger also clears expired rows, as before.
create or replace function app_events_brake()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_live bigint;
begin
  if (select count(*) from new_rows) > 50 then
    raise exception 'Too many events in one request.'
      using errcode = 'P0001', hint = 'rate_limited';
  end if;
  if (select count(*) from app_events where created_at > now() - interval '1 minute') > 400
     or (select count(*) from app_events where created_at > now() - interval '1 day') > 8000 then
    raise exception 'Too many events right now.'
      using errcode = 'P0001', hint = 'rate_limited';
  end if;
  if pg_total_relation_size('public.app_events'::regclass) > 160 * 1024 * 1024
     and (select count(*) from (select 1 from app_events limit 20001) x) > 20000 then
    raise exception 'The statistics table is full.'
      using errcode = 'P0001', hint = 'rate_limited';
  end if;
  select coalesce(s.n_live_tup, 0) into v_live
  from pg_stat_user_tables s where s.relid = 'public.app_events'::regclass;
  if coalesce(v_live, 0) > 80000 then
    delete from app_events where id in (
      select id from app_events order by created_at
      limit least(v_live - 80000 + 100, 2000) for update skip locked);
  end if;
  delete from app_events where id in (
    select id from app_events where created_at < now() - interval '90 days'
    order by created_at limit 2000 for update skip locked);
  delete from feedback where id in (
    select id from feedback where created_at < now() - interval '12 months'
    order by created_at limit 200 for update skip locked);
  return null;
end $$;
drop trigger if exists app_events_brake on app_events;
create trigger app_events_brake after insert on app_events
  referencing new table as new_rows
  for each statement execute function app_events_brake();

-- The feedback brake. Security definer, because the counts have to see every
-- row. Sizes are counted in bytes: the message at most 16000 (the form and
-- the table allow 4000 characters, up to 4 bytes each, so Greek, Cyrillic or
-- Japanese text is not cut short), contact and page at most 800 bytes each
-- (200 characters). Then:
--   * nothing from signed-out visitors once the stored messages take more
--     than 10 MB, nothing at all past 25 MB. This counts the data in the rows
--     still there (not the file size), so deleting junk reopens the form at
--     once, without a vacuum full;
--   * a text identical to one from the last hour is refused (as before);
--   * an account: 10 in ten minutes, 20 a day;
--   * signed-out visitors together (the database sees no IP address): 30 in
--     ten minutes, 200 a day. While that bucket is full the form tells them
--     to sign in, since an account has its own bucket.
create or replace function feedback_brake()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_size bigint;
begin
  new.created_at := now();
  if octet_length(new.body) > 16000
     or (new.contact is not null and octet_length(new.contact) > 800)
     or (new.page is not null and octet_length(new.page) > 800) then
    raise exception 'This message is too long. Shorten it and send it again.'
      using errcode = '22001';
  end if;
  -- Stored size of what the rows hold (pg_column_size reads no long value),
  -- plus about 100 bytes a row for the row itself and its indexes.
  select coalesce(sum(100 + coalesce(pg_column_size(f.body), 0)
                      + coalesce(pg_column_size(f.contact), 0)
                      + coalesce(pg_column_size(f.page), 0)
                      + coalesce(pg_column_size(f.context), 0)
                      + coalesce(pg_column_size(f.admin_note), 0)), 0)
    into v_size
  from feedback f;
  if v_size > 25 * 1024 * 1024 or (new.user_id is null and v_size > 10 * 1024 * 1024) then
    raise exception 'Feedback cannot take more messages right now. Try again later.'
      using errcode = 'P0001', hint = 'rate_limited';
  end if;
  if exists (select 1 from feedback f
             where f.created_at > now() - interval '1 hour'
               and f.body = new.body) then
    raise exception 'This message already arrived.'
      using errcode = 'P0001', hint = 'duplicate';
  end if;
  if new.user_id is not null then
    if (select count(*) from feedback f
        where f.user_id = new.user_id
          and f.created_at > now() - interval '10 minutes') >= 10
       or (select count(*) from feedback f
           where f.user_id = new.user_id
             and f.created_at > now() - interval '1 day') >= 20 then
      raise exception 'Too many messages in a short time. Try again later.'
        using errcode = 'P0001', hint = 'rate_limited';
    end if;
  elsif (select count(*) from feedback f
         where f.user_id is null
           and f.created_at > now() - interval '10 minutes') >= 30
     or (select count(*) from feedback f
         where f.user_id is null
           and f.created_at > now() - interval '1 day') >= 200 then
    raise exception 'Too many messages in a short time. Try again later.'
      using errcode = 'P0001', hint = 'rate_limited';
  end if;
  return new;
end $$;
drop trigger if exists feedback_brake on feedback;
create trigger feedback_brake before insert on feedback
  for each row execute function feedback_brake();

-- ============================================================
--  9. DISPLAY NAMES
-- ============================================================
-- 1 to 40 characters, not blank (the app's name fields allow 40). Longer or
-- blank names are fixed first; on the live data (15 profiles, longest 18)
-- this changes nothing. Signup trims what Google or Discord send to 40.
update profiles
   set display_name = coalesce(nullif(btrim(left(btrim(display_name), 40)), ''), 'Player')
 where char_length(display_name) > 40 or btrim(display_name) = '';

do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'profiles_display_name_len' and conrelid = 'public.profiles'::regclass) then
    alter table profiles add constraint profiles_display_name_len
      check (char_length(display_name) between 1 and 40 and btrim(display_name) <> '') not valid;
  end if;
end $$;
alter table profiles validate constraint profiles_display_name_len;

create or replace function handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name, role)
  values (
    new.id,
    -- email signup uses display_name (typed by the player); Google sends
    -- full_name/name, Discord global_name/full_name/user_name. Of a provider's
    -- full name only the first word is used, so a legal full name is never
    -- public; the site then asks the player to choose a public name. The full
    -- name stays only in the login's own metadata. Email prefix is the last resort.
    coalesce(nullif(btrim(left(coalesce(
      nullif(trim(new.raw_user_meta_data->>'display_name'), ''),
      nullif(split_part(btrim(new.raw_user_meta_data->>'full_name'), ' ', 1), ''),
      nullif(split_part(btrim(new.raw_user_meta_data->>'name'), ' ', 1), ''),
      nullif(trim(new.raw_user_meta_data->>'global_name'), ''),
      nullif(trim(new.raw_user_meta_data->>'user_name'), ''),
      nullif(trim(new.raw_user_meta_data->>'preferred_username'), ''),
      split_part(new.email, '@', 1),
      ''), 40)), ''), 'Player'),
    case when new.raw_user_meta_data->>'role' = 'organizer' then 'organizer' else 'player' end
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

-- A deleted account's profile is a tombstone: nobody edits it from the site,
-- and nobody marks their own profile deleted except through delete_my_account().
-- Not security definer on purpose: current_user is then the caller's role.
create or replace function guard_profile_update()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if old.deleted_at is not null then
    raise exception 'This account was deleted' using errcode = '42501';
  end if;
  if new.deleted_at is distinct from old.deleted_at then
    raise exception 'Use Delete my account to delete an account' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists profile_update_guard on profiles;
create trigger profile_update_guard before update on profiles
  for each row execute function guard_profile_update();

-- ============================================================
--  5. DELETING AN ACCOUNT WITHOUT TAKING OTHER PLAYERS' DATA
-- ============================================================
-- Foreign keys. profiles.id used to cascade from auth.users, so deleting a
-- login deleted the profile and, through it, every match, check-in and
-- league of that player, other players' results included. Now:
--   * profiles has no foreign key to auth.users. The profile outlives the
--     login as a tombstone ("Deleted player", deleted_at set), so opponents
--     keep their results. A key that does not cascade cannot work here: SET
--     NULL is impossible on a primary key, and NO ACTION / RESTRICT would block
--     deleting the login while the tombstone exists. Ids come from
--     gen_random_uuid() in auth, so a new account never reuses one;
--   * leagues.owner_id, matches.winner_id / loser_id and attendance.user_id
--     are ON DELETE RESTRICT: deleting a profile by hand that owns a league or
--     has results fails with an error instead of wiping them.
do $$
declare c record;
begin
  for c in select conname from pg_constraint
           where conrelid = 'public.profiles'::regclass and contype = 'f'
             and confrelid = 'auth.users'::regclass loop
    execute format('alter table public.profiles drop constraint %I', c.conname);
  end loop;
end $$;

do $$
declare
  r record;
  c record;
begin
  for r in select * from (values
      ('leagues', 'owner_id'),
      ('matches', 'winner_id'),
      ('matches', 'loser_id'),
      ('attendance', 'user_id')) as v(tbl, col)
  loop
    for c in
      select con.conname, con.confdeltype
      from pg_constraint con
      join pg_attribute a on a.attrelid = con.conrelid and a.attnum = con.conkey[1]
      where con.contype = 'f'
        and con.conrelid = format('public.%I', r.tbl)::regclass
        and con.confrelid = 'public.profiles'::regclass
        and array_length(con.conkey, 1) = 1
        and a.attname = r.col
    loop
      if c.confdeltype <> 'r' then
        execute format('alter table public.%I drop constraint %I', r.tbl, c.conname);
      end if;
    end loop;
    if not exists (
      select 1
      from pg_constraint con
      join pg_attribute a on a.attrelid = con.conrelid and a.attnum = con.conkey[1]
      where con.contype = 'f'
        and con.conrelid = format('public.%I', r.tbl)::regclass
        and con.confrelid = 'public.profiles'::regclass
        and array_length(con.conkey, 1) = 1
        and a.attname = r.col
    ) then
      execute format(
        'alter table public.%I add constraint %I foreign key (%I) references public.profiles(id) on delete restrict',
        r.tbl, r.tbl || '_' || r.col || '_fkey', r.col);
    end if;
  end loop;
end $$;

-- What erasing a player does. Idempotent. Not callable over the API.
--   * Leagues they own: one where nobody else ever played (no other member,
--     match or check-in) is deleted. One that still has other active players
--     and is not archived stops the whole deletion with a message: hand it
--     over or archive it first. Any other (archived, or only retired players
--     left) is archived and kept, owned by the tombstone.
--   * Their collection, free battles, private decks, feedback and site-admin
--     row are deleted. Public decks stay, so results that name them still do.
--   * Their memberships are marked dropped (and not organizer).
--   * The profile becomes "Deleted player" with every optional field cleared.
--     Their matches and check-ins stay, so nobody's standings move.
create or replace function erase_user_data(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  l record;
begin
  if p_user is null then
    return;
  end if;
  for l in select id, name, archived_at from leagues where owner_id = p_user for update loop
    if not exists (select 1 from memberships m where m.league_id = l.id and m.user_id <> p_user)
       and not exists (select 1 from matches mt where mt.league_id = l.id)
       and not exists (select 1 from attendance a join sessions s on s.id = a.session_id
                       where s.league_id = l.id and a.user_id <> p_user) then
      delete from leagues where id = l.id;
    elsif l.archived_at is null and exists (
      select 1 from memberships m
      where m.league_id = l.id and m.user_id <> p_user and m.dropped_at is null
    ) then
      raise exception 'This account owns the league "%", which still has players. Hand it over to one of them or archive it first (Manage).', l.name
        using errcode = 'P0001', hint = 'sl_owns_league';
    else
      update leagues set archived_at = coalesce(archived_at, now()) where id = l.id;
    end if;
  end loop;

  delete from collection   where user_id = p_user;
  delete from free_battles where user_id = p_user;
  delete from decks        where user_id = p_user and not is_public;
  delete from feedback     where user_id = p_user;
  delete from site_admins  where user_id = p_user;

  update memberships
     set dropped_at = coalesce(dropped_at, now()), is_admin = false
   where user_id = p_user and (dropped_at is null or is_admin);

  update profiles
     set display_name = 'Deleted player',
         role = 'player',
         herald_rank = null,
         discord = null,
         malediction_url = null,
         lat = null,
         lon = null,
         place = null,
         deleted_at = coalesce(deleted_at, now())
   where id = p_user;
end $$;
revoke all on function erase_user_data(uuid) from public, anon, authenticated;

-- The signed-in player deletes their own account. On success the login is
-- gone; the site should sign out locally afterwards.
create or replace function delete_my_account()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'Sign in first' using errcode = '42501';
  end if;
  perform erase_user_data(uid);
  delete from auth.users where id = uid;
  return jsonb_build_object('deleted', true);
end $$;
revoke all on function delete_my_account() from public, anon;
grant execute on function delete_my_account() to authenticated;

-- The site admin, for a deletion request that arrived some other way (check
-- who is asking first: a signed-out message must not get someone else erased).
create or replace function admin_delete_user(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not is_site_admin() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_user is null then
    raise exception 'No user given' using errcode = '22004';
  end if;
  perform erase_user_data(p_user);
  delete from auth.users where id = p_user;
  return jsonb_build_object('deleted', true, 'user', p_user);
end $$;
revoke all on function admin_delete_user(uuid) from public, anon;
grant execute on function admin_delete_user(uuid) to authenticated;

-- Deleting a login anywhere else (Dashboard > Authentication > Delete user)
-- erases the same way first, and fails with the same message if the player
-- still owns a league with players. If the project does not allow a trigger
-- on auth.users this step is skipped with a notice; use the functions above.
create or replace function handle_user_deleted()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.erase_user_data(old.id);
  return old;
end $$;

do $$
begin
  begin
    drop trigger if exists on_auth_user_deleted on auth.users;
    create trigger on_auth_user_deleted
      before delete on auth.users
      for each row execute function public.handle_user_deleted();
  exception when others then
    raise notice 'Could not add the delete trigger on auth.users (%). Delete accounts with delete_my_account() / admin_delete_user() only.', sqlerrm;
  end;
end $$;


-- ============================================================
--  ONLINE LEAGUES AND WINDOW EVENTS (2026-11-01)
-- ============================================================
-- Same SQL as migration-2026-11-01-online.sql (whose header lists every
-- change and which ends with a read-only check). It comes after SECURITY
-- HARDENING (2026-11-06) and replaces these definitions made further up:
-- public_leagues (three columns appended), session_is_open, can_check_in,
-- guard_match_write, confirm_match, sync_tournament, erase_user_data, and the
-- attendance insert policy "self or admin attendance". New: columns
-- leagues.is_online/region/timezone/discord_url, sessions.end_date/rounds,
-- attendance.auto; table member_discord; functions guard_league_fields,
-- guard_session_window, window_state, window_confirmable,
-- window_attendance_for, match_window_attendance, session_window_attendance,
-- shares_league_with, touch_member_discord; triggers league_fields_guard,
-- session_window_guard, match_window_attendance, session_window_attendance,
-- member_discord_touch. The migration wraps it in begin/commit.


-- ============================================================
--  1. NEW COLUMNS
-- ============================================================
alter table leagues    add column if not exists is_online   boolean not null default false;
alter table leagues    add column if not exists region      text;
alter table leagues    add column if not exists timezone    text;
alter table leagues    add column if not exists discord_url text;

alter table sessions   add column if not exists end_date date;
alter table sessions   add column if not exists rounds   jsonb;

alter table attendance add column if not exists auto boolean not null default false;

-- shares_league_with() looks memberships up by player.
create index if not exists idx_memberships_user on memberships(user_id);

-- ============================================================
--  2. CONSTRAINTS
-- ============================================================
do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'leagues_region_check' and conrelid = 'public.leagues'::regclass) then
    alter table leagues add constraint leagues_region_check check (region is null or region in
      ('world', 'europe', 'north_america', 'latin_america', 'asia_pacific', 'africa_middle_east'));
  end if;
  if not exists (select 1 from pg_constraint
                 where conname = 'leagues_timezone_len' and conrelid = 'public.leagues'::regclass) then
    alter table leagues add constraint leagues_timezone_len
      check (timezone is null or char_length(timezone) between 1 and 64);
  end if;
  if not exists (select 1 from pg_constraint
                 where conname = 'leagues_discord_url_format' and conrelid = 'public.leagues'::regclass) then
    alter table leagues add constraint leagues_discord_url_format check (discord_url is null or
      discord_url ~ '^https://(discord\.gg|discord\.com/invite)/[A-Za-z0-9-]{2,32}$');
  end if;
  if not exists (select 1 from pg_constraint
                 where conname = 'leagues_online_fields' and conrelid = 'public.leagues'::regclass) then
    alter table leagues add constraint leagues_online_fields
      check (not is_online or (region is not null and timezone is not null));
  end if;
  if not exists (select 1 from pg_constraint
                 where conname = 'leagues_online_no_pin' and conrelid = 'public.leagues'::regclass) then
    alter table leagues add constraint leagues_online_no_pin
      check (not is_online or (lat is null and lon is null));
  end if;

  if not exists (select 1 from pg_constraint
                 where conname = 'sessions_end_after_start' and conrelid = 'public.sessions'::regclass) then
    alter table sessions add constraint sessions_end_after_start
      check (end_date is null or end_date > date);
  end if;
  if not exists (select 1 from pg_constraint
                 where conname = 'sessions_window_not_tournament' and conrelid = 'public.sessions'::regclass) then
    alter table sessions add constraint sessions_window_not_tournament
      check (end_date is null or not is_tournament);
  end if;
  if not exists (select 1 from pg_constraint
                 where conname = 'sessions_rounds_window' and conrelid = 'public.sessions'::regclass) then
    alter table sessions add constraint sessions_rounds_window
      check (rounds is null or end_date is not null);
  end if;
  -- CASE, so jsonb_array_length never sees a non-array (AND has no fixed order).
  if not exists (select 1 from pg_constraint
                 where conname = 'sessions_rounds_shape' and conrelid = 'public.sessions'::regclass) then
    alter table sessions add constraint sessions_rounds_shape check (rounds is null or
      case when jsonb_typeof(rounds) = 'array'
           then jsonb_array_length(rounds) <= 12 and octet_length(rounds::text) <= 32768
           else false end);
  end if;
end $$;

-- ============================================================
--  3. LEAGUES: ONLINE FIELDS (league_fields_guard)
-- ============================================================
-- Runs first among the leagues triggers (name order): league_fields_guard,
-- league_insert_guard, league_owner_guard, league_update_guard. The site-admin
-- "archive only" check in guard_league_update still holds: on an online league
-- lat/lon are already null and location is already filled, so nothing changes.
-- Security definer, so the events check sees every event of the league. A
-- request from the site is told apart by auth.uid() (as in guard_league_owner):
-- inside a security definer function current_user is the owner, not the caller.
create or replace function guard_league_fields()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.region      := nullif(btrim(new.region), '');
  new.timezone    := nullif(btrim(new.timezone), '');
  new.discord_url := nullif(btrim(new.discord_url), '');
  if new.is_online then
    -- No map pin for an online league. Cleared rather than refused, so an old
    -- cached client that sends a pin does not fail.
    new.lat := null;
    new.lon := null;
    if new.location is null or btrim(new.location) = '' then
      new.location := 'Online';
    end if;
  end if;
  if new.timezone is not null then
    if tg_op = 'INSERT' or new.timezone is distinct from old.timezone then
      if not exists (select 1 from pg_timezone_names where name = new.timezone) then
        raise exception 'Unknown time zone: %', new.timezone using errcode = '22023';
      end if;
    end if;
  end if;
  if tg_op = 'UPDATE' then
    -- Events with an end date run in the league's time zone, so it stays set.
    if new.timezone is null and old.timezone is not null
       and exists (select 1 from sessions s where s.league_id = old.id and s.end_date is not null) then
      raise exception 'This league has events with an end date, so it needs a time zone'
        using errcode = '23514', hint = 'sl_tz_needed';
    end if;
    if new.is_online is distinct from old.is_online
       and auth.uid() is not null
       and exists (select 1 from sessions s where s.league_id = old.id) then
      raise exception 'A league that has events cannot switch between online and in person'
        using errcode = '42501', hint = 'sl_kind_locked';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists league_fields_guard on leagues;
create trigger league_fields_guard before insert or update on leagues
  for each row execute function guard_league_fields();

-- ============================================================
--  4. SESSIONS: WINDOW EVENTS (session_window_guard)
-- ============================================================
-- date_trunc('week', ...) starts the week on Monday (ISO), so "same week" is
-- Monday to Sunday. "At most 28 days" counts both ends: end_date - date <= 27.
-- An event with an end date needs the league's time zone, so the window opens
-- and closes at one midnight for everyone and two windows never overlap.
-- A round is {n: number, due: 'YYYY-MM-DD', pairs: [...], ...}; the database
-- checks only that shape and that due falls inside the event's dates. A due
-- that is not a real date is refused with the same message, not a cast error.
create or replace function guard_session_window()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_online boolean;
  v_tz     text;
  v_r      jsonb;
  v_ok     boolean;
  v_due    date;
begin
  if new.end_date is not null then
    if new.end_date <= new.date then
      raise exception 'The end date must be after the start date' using errcode = '23514';
    end if;
    if new.is_tournament then
      raise exception 'A Tournament event is a single day. Remove the end date, or make it a League event.'
        using errcode = '23514', hint = 'sl_window_tournament';
    end if;
    select l.is_online, l.timezone into v_online, v_tz from leagues l where l.id = new.league_id;
    if v_tz is null then
      raise exception 'An event with an end date needs the league''s time zone. Set it in Manage first.'
        using errcode = '23514', hint = 'sl_window_tz';
    end if;
    if coalesce(v_online, false) then
      if new.end_date - new.date > 27 then
        raise exception 'An online event can last at most 28 days' using errcode = '23514', hint = 'sl_window_long';
      end if;
    elsif date_trunc('week', new.date::timestamp) <> date_trunc('week', new.end_date::timestamp) then
      raise exception 'An in-person event with an end date stays within one week, Monday to Sunday'
        using errcode = '23514', hint = 'sl_window_week';
    end if;
  end if;
  if new.rounds is not null then
    if new.end_date is null then
      raise exception 'Rounds need an event with an end date' using errcode = '23514';
    end if;
    if jsonb_typeof(new.rounds) is distinct from 'array' then
      raise exception 'Each round needs its pairings and a deadline inside the event''s dates'
        using errcode = '23514', hint = 'sl_round_bad';
    end if;
    if jsonb_array_length(new.rounds) > 12 then
      raise exception 'An event can have at most 12 rounds' using errcode = '23514', hint = 'sl_round_bad';
    end if;
    for v_r in select e from jsonb_array_elements(new.rounds) as t(e) loop
      v_due := null;
      v_ok := coalesce(jsonb_typeof(v_r) = 'object'
                       and jsonb_typeof(v_r->'n') = 'number'
                       and jsonb_typeof(v_r->'pairs') = 'array'
                       and coalesce(v_r->>'due', '') ~ '^\d{4}-\d\d-\d\d$', false);
      if v_ok then
        begin
          v_due := (v_r->>'due')::date;
        exception when others then
          v_ok := false;
        end;
      end if;
      if not v_ok or v_due is null or v_due < new.date or v_due > new.end_date then
        raise exception 'Each round needs its pairings and a deadline inside the event''s dates'
          using errcode = '23514', hint = 'sl_round_bad';
      end if;
    end loop;
  end if;
  return new;
end $$;
drop trigger if exists session_window_guard on sessions;
create trigger session_window_guard before insert or update on sessions
  for each row execute function guard_session_window();

-- ============================================================
--  5. TIME HELPERS
-- ============================================================
-- 'single' for a single-day event, otherwise 'before' / 'open' / 'after' the
-- window, in the league's time zone. session_window_guard makes sure a window
-- event's league has one; if it were ever missing, UTC, the same zone at both
-- ends, so back-to-back windows never overlap (no anywhere-on-Earth margin here).
create or replace function window_state(p_start date, p_end date, p_tz text)
returns text language sql stable set search_path = public as $$
  select case
    when p_end is null then 'single'
    when p_start > (now() at time zone coalesce(p_tz, 'UTC'))::date then 'before'
    when p_end   < (now() at time zone coalesce(p_tz, 'UTC'))::date then 'after'
    else 'open' end;
$$;

-- The opponent may still confirm a pending match of a window event up to 3
-- days after its last day (league time). After that only an organizer can.
create or replace function window_confirmable(p_end date, p_tz text)
returns boolean language sql stable set search_path = public as $$
  select p_end is null or p_end + 3 >= (now() at time zone coalesce(p_tz, 'UTC'))::date;
$$;

-- guard_match_write is not security definer and calls window_state as the
-- caller, so authenticated needs execute on it.
revoke all on function window_state(date, date, text) from public, anon;
revoke all on function window_confirmable(date, text) from public, anon;
grant execute on function window_state(date, date, text) to authenticated;
grant execute on function window_confirmable(date, text) to authenticated;

-- ============================================================
--  6. session_is_open AND can_check_in (replaced)
-- ============================================================
-- An event that still takes results from players: not finished, league not
-- archived, and for a window event, while the window is open.
create or replace function session_is_open(p_session uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from sessions s join leagues l on l.id = s.league_id
    where s.id = p_session and s.closed_at is null and l.archived_at is null
      and window_state(s.date, s.end_date, l.timezone) in ('single', 'open')
  );
$$;
revoke all on function session_is_open(uuid) from public, anon;
grant execute on function session_is_open(uuid) to authenticated;

-- As before, plus: no self check-in at a window event (a confirmed game counts
-- the player in instead). Grants are unchanged.
create or replace function can_check_in(p_session uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1
    from sessions s
    join leagues l on l.id = s.league_id
    join memberships m on m.league_id = s.league_id
                      and m.user_id = auth.uid()
                      and m.dropped_at is null
    where s.id = p_session
      and s.end_date is null
      and s.closed_at is null
      and l.archived_at is null
      and s.date <= (now() at time zone 'Etc/GMT-14')::date
  );
$$;

-- ============================================================
--  7. guard_match_write (replaced)
-- ============================================================
-- Same as 2026-11-06 except the last check, which now says why a window event
-- refuses a player's result. Organizers are not limited by the window.
-- Not security definer on purpose: current_user is then the caller's role.
create or replace function guard_match_write()
returns trigger language plpgsql set search_path = public as $$
declare
  v_st text;
  v_d  date;
  v_e  date;
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.created_at := now();
    perform check_match_quota();
  else
    new.created_at := old.created_at;
  end if;
  if tg_op = 'INSERT'
     or new.winner_id is distinct from old.winner_id
     or new.loser_id  is distinct from old.loser_id
     or new.league_id is distinct from old.league_id then
    if not (league_player_active(new.league_id, new.winner_id)
            and league_player_active(new.league_id, new.loser_id)) then
      raise exception 'Both players must be active members of this league' using errcode = '42501';
    end if;
  end if;
  if not is_league_admin(new.league_id) and not session_is_open(new.session_id) then
    select window_state(s.date, s.end_date, l.timezone), s.date, s.end_date
      into v_st, v_d, v_e
    from sessions s join leagues l on l.id = s.league_id
    where s.id = new.session_id and s.closed_at is null and l.archived_at is null;
    if v_st = 'before' then
      raise exception 'This event opens on %. Log the result from then on.', to_char(v_d, 'Dy FMDD Mon')
        using errcode = '42501', hint = 'sl_window_before';
    elsif v_st = 'after' then
      raise exception 'This event ended on %. Ask an organizer to add the result.', to_char(v_e, 'Dy FMDD Mon')
        using errcode = '42501', hint = 'sl_window_after';
    end if;
    raise exception 'This event is finished or the league is archived. Ask an organizer to add the result.'
      using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists match_write_guard on matches;
create trigger match_write_guard before insert or update on matches
  for each row execute function guard_match_write();

-- ============================================================
--  8. confirm_match (replaced: same signature and body, plus two checks)
-- ============================================================
-- The added checks come after "already confirmed: nothing to do", so
-- "Confirm all" can still be repeated safely at any time. A player cannot
-- confirm a game against someone who has since left the league, been retired
-- or deleted their account (guard_match_write already refuses new games with
-- them); an organizer still can.
create or replace function confirm_match(
  p_match uuid,
  p_winner uuid, p_loser uuid,
  p_winner_seeker text, p_loser_seeker text,
  p_winner_terrain text, p_loser_terrain text)
returns void language plpgsql security definer set search_path = public as $$
declare m matches%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Sign in to confirm a match' using errcode = '42501';
  end if;
  select * into m from matches where id = p_match for update;
  if not found then
    raise exception 'Match not found' using errcode = 'P0002';
  end if;
  if not (
    is_league_admin(m.league_id)
    or (
      auth.uid() in (m.winner_id, m.loser_id)
      and m.reported_by is distinct from auth.uid()
      and is_active_member(m.league_id)
    )
  ) then
    raise exception 'Only your opponent or an organizer can confirm this match' using errcode = '42501';
  end if;
  if exists (select 1 from leagues l where l.id = m.league_id and l.archived_at is not null) then
    raise exception 'This league is archived' using errcode = '42501';
  end if;
  if m.confirmed then
    return;
  end if;
  if not is_league_admin(m.league_id)
     and not (league_player_active(m.league_id, m.winner_id)
              and league_player_active(m.league_id, m.loser_id)) then
    raise exception 'Your opponent is no longer in this league, so only an organizer can confirm this match.'
      using errcode = '42501', hint = 'sl_player_gone';
  end if;
  if not is_league_admin(m.league_id) and exists (
    select 1 from sessions s join leagues l on l.id = s.league_id
    where s.id = m.session_id and s.end_date is not null
      and not window_confirmable(s.end_date, l.timezone)
  ) then
    raise exception 'The time to confirm this match is over. Ask an organizer to confirm it.'
      using errcode = '42501', hint = 'sl_confirm_closed';
  end if;
  if m.winner_id is distinct from p_winner
     or m.loser_id is distinct from p_loser
     or m.winner_seeker is distinct from p_winner_seeker
     or m.loser_seeker is distinct from p_loser_seeker
     or m.winner_terrain is distinct from p_winner_terrain
     or m.loser_terrain is distinct from p_loser_terrain then
    raise exception 'This match was changed since you opened it. Check it again before confirming.'
      using errcode = 'P0001', hint = 'sl_match_changed';
  end if;
  update matches set confirmed = true where id = p_match;
end $$;
revoke all on function confirm_match(uuid, uuid, uuid, text, text, text, text) from public, anon;
grant execute on function confirm_match(uuid, uuid, uuid, text, text, text, text) to authenticated;

-- ============================================================
--  9. PARTICIPATION IN WINDOW EVENTS: AUTOMATIC ATTENDANCE ROWS
-- ============================================================
-- The participation point comes from ordinary attendance rows, so the
-- standings and old clients keep working unchanged. Rows made here are marked
-- auto = true; an organizer's hand mark (auto = false) is never removed.
-- All three functions are security definer and owned by the tables' owner,
-- so RLS does not apply to their writes (as with sync_tournament's check-ins).

-- Internal. Makes p_user's automatic attendance at a window event match
-- whether they have at least one confirmed match there (confirmed covers
-- organizer entries and opponent confirmations; a window event is never a
-- Tournament event). Not callable over the API.
create or replace function window_attendance_for(p_session uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_session is null or p_user is null then
    return;
  end if;
  if not exists (select 1 from sessions s where s.id = p_session and s.end_date is not null) then
    return;
  end if;
  -- One player and event at a time: a second change waits here, and its next
  -- statement then sees the first one's commit (READ COMMITTED), so two
  -- concurrent changes cannot leave a confirmed game without its row.
  perform pg_advisory_xact_lock(hashtextextended(p_session::text || ':' || p_user::text, 0));
  if exists (select 1 from matches m
             where m.session_id = p_session and m.confirmed
               and (m.winner_id = p_user or m.loser_id = p_user)) then
    insert into attendance (session_id, user_id, auto) values (p_session, p_user, true)
      on conflict (session_id, user_id) do nothing;
  else
    delete from attendance a
     where a.session_id = p_session and a.user_id = p_user and a.auto;
  end if;
end $$;
revoke all on function window_attendance_for(uuid, uuid) from public, anon, authenticated;

create or replace function match_window_attendance()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE'
     and new.session_id is not distinct from old.session_id
     and new.winner_id  is not distinct from old.winner_id
     and new.loser_id   is not distinct from old.loser_id
     and new.confirmed  is not distinct from old.confirmed then
    return null;
  end if;
  if tg_op in ('UPDATE', 'DELETE') then
    perform window_attendance_for(old.session_id, old.winner_id);
    perform window_attendance_for(old.session_id, old.loser_id);
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    perform window_attendance_for(new.session_id, new.winner_id);
    perform window_attendance_for(new.session_id, new.loser_id);
  end if;
  return null;
end $$;
drop trigger if exists match_window_attendance on matches;
create trigger match_window_attendance after insert or update or delete on matches
  for each row execute function match_window_attendance();

-- An event that gains or loses its end date. Gaining one: a player with a
-- confirmed game there keeps their row, now automatic; the other rows were
-- check-ins or hand marks of a one-day event, which no longer count here, so
-- they go (the site asks the organizer first; the organizer can mark someone
-- by hand again afterwards).
create or replace function session_window_attendance()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.end_date is null and new.end_date is not null then
    update attendance a set auto = true
     where a.session_id = new.id and not a.auto
       and exists (select 1 from matches m
                   where m.session_id = new.id and m.confirmed
                     and a.user_id in (m.winner_id, m.loser_id));
    delete from attendance a where a.session_id = new.id and not a.auto;
    insert into attendance (session_id, user_id, auto)
    select distinct new.id, u.uid
    from matches m cross join lateral (values (m.winner_id), (m.loser_id)) as u(uid)
    where m.session_id = new.id and m.confirmed
    on conflict (session_id, user_id) do nothing;
  elsif old.end_date is not null and new.end_date is null then
    -- Back to a single-day event: automatic rows become ordinary check-ins.
    update attendance set auto = false where session_id = new.id and auto;
  end if;
  return null;
end $$;
drop trigger if exists session_window_attendance on sessions;
create trigger session_window_attendance after update of end_date on sessions
  for each row execute function session_window_attendance();

-- The attendance insert policy, replaced: as 2026-11-06, plus "not auto", so
-- the site can never write an automatic row. The select and delete policies
-- are unchanged, and there is still no update policy, so auto cannot be
-- flipped from the site.
drop policy if exists "self or admin attendance" on attendance;
create policy "self or admin attendance" on attendance
  for insert with check (
    not auto
    and (
      (is_league_admin(session_league(session_id))
         and league_player_active(session_league(session_id), user_id))
      or (user_id = auth.uid() and can_check_in(session_id))
    )
  );

-- ============================================================
--  10. sync_tournament (replaced: one more check)
-- ============================================================
-- Same as 2026-11-06, plus: a tournament needs a single-day event.
create or replace function sync_tournament(p_tournament uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := auth.uid();
  v_t    tournaments%rowtype;
  v_s    sessions%rowtype;
  v_fin  boolean;
  v_refs text[];
  v_up   int := 0;
  v_del  int := 0;
  v_att  int := 0;
begin
  if v_uid is null then
    raise exception 'Sign in first' using errcode = '42501';
  end if;
  select * into v_t from tournaments where id = p_tournament for update;
  if not found then
    raise exception 'Tournament not found' using errcode = 'P0002';
  end if;
  if not is_league_admin(v_t.league_id) then
    raise exception 'Only an organizer of this league can do that' using errcode = '42501';
  end if;
  if exists (select 1 from leagues l where l.id = v_t.league_id and l.archived_at is not null) then
    raise exception 'This league is archived' using errcode = '42501';
  end if;
  if v_t.session_id is null then
    raise exception 'This tournament is not linked to an event' using errcode = 'P0001';
  end if;
  select * into v_s from sessions where id = v_t.session_id for update;
  if not found or v_s.league_id <> v_t.league_id then
    raise exception 'The tournament''s event is not in its league' using errcode = 'P0001';
  end if;
  if v_s.end_date is not null then
    raise exception 'A tournament needs a single-day event. Remove the event''s end date first.'
      using errcode = 'P0001', hint = 'sl_window_tournament';
  end if;
  if coalesce(v_t.payload->>'v', '') <> '2' then
    raise exception 'This tournament cannot be linked to an event' using errcode = 'P0001';
  end if;
  v_fin := coalesce(v_t.payload->>'finalized', 'false') = 'true';

  select coalesce(array_agg(g.ref), '{}') into v_refs
  from tournament_games(v_t.payload) g
  where exists (select 1 from matches mt
                where mt.tournament_id = v_t.id and mt.t_ref = g.ref
                  and mt.winner_id = g.winner_id and mt.loser_id = g.loser_id)
     or (league_player_active(v_t.league_id, g.winner_id)
         and league_player_active(v_t.league_id, g.loser_id));

  delete from matches mt
  where mt.tournament_id = v_t.id
    and not (mt.t_ref = any (v_refs));
  get diagnostics v_del = row_count;

  insert into matches (session_id, league_id, winner_id, loser_id,
                       winner_seeker, loser_seeker, winner_terrain, loser_terrain,
                       winner_deck_id, loser_deck_id, reported_by, confirmed,
                       tournament_id, t_ref)
  select v_s.id, v_t.league_id, g.winner_id, g.loser_id,
         g.winner_seeker, g.loser_seeker, g.winner_terrain, g.loser_terrain,
         g.winner_deck_id, g.loser_deck_id, v_uid, true,
         v_t.id, g.ref
  from tournament_games(v_t.payload) g
  where g.ref = any (v_refs)
  on conflict (tournament_id, t_ref) where tournament_id is not null do update set
    session_id     = excluded.session_id,
    league_id      = excluded.league_id,
    winner_id      = excluded.winner_id,
    loser_id       = excluded.loser_id,
    winner_seeker  = excluded.winner_seeker,
    loser_seeker   = excluded.loser_seeker,
    winner_terrain = excluded.winner_terrain,
    loser_terrain  = excluded.loser_terrain,
    winner_deck_id = excluded.winner_deck_id,
    loser_deck_id  = excluded.loser_deck_id,
    confirmed      = true
  where (matches.session_id, matches.league_id, matches.winner_id, matches.loser_id,
         matches.winner_seeker, matches.loser_seeker, matches.winner_terrain, matches.loser_terrain,
         matches.winner_deck_id, matches.loser_deck_id, matches.confirmed)
        is distinct from
        (excluded.session_id, excluded.league_id, excluded.winner_id, excluded.loser_id,
         excluded.winner_seeker, excluded.loser_seeker, excluded.winner_terrain, excluded.loser_terrain,
         excluded.winner_deck_id, excluded.loser_deck_id, excluded.confirmed);
  get diagnostics v_up = row_count;

  insert into attendance (session_id, user_id)
  select distinct v_s.id, m.user_id
  from jsonb_array_elements(case when jsonb_typeof(v_t.payload->'entrants') = 'array'
                                 then v_t.payload->'entrants' else '[]'::jsonb end) as e
  join memberships m on m.league_id = v_t.league_id and m.user_id::text = e->>'id'
                    and m.dropped_at is null
  join profiles p on p.id = m.user_id and p.deleted_at is null
  on conflict (session_id, user_id) do nothing;
  get diagnostics v_att = row_count;

  update sessions
  set is_tournament = true,
      t_linked = true,
      closed_at = case when v_fin then coalesce(closed_at, now()) end
  where id = v_s.id
    and (not is_tournament or not t_linked
         or (v_fin and closed_at is null) or (not v_fin and closed_at is not null));

  return jsonb_build_object(
    'games', coalesce(array_length(v_refs, 1), 0),
    'saved', v_up, 'removed', v_del, 'checked_in', v_att, 'closed', v_fin);
end $$;
revoke all on function sync_tournament(uuid) from public, anon;
grant execute on function sync_tournament(uuid) to authenticated;

-- ============================================================
--  11. DISCORD NAMES SHARED WITH YOUR LEAGUES ONLY (member_discord)
-- ============================================================
-- profiles.discord stays exactly as it is: the public Discord name (player
-- page, Heralds map). member_discord holds a Discord name that only the player
-- and the players who share an active league with them can read. The site
-- keeps only one of the two filled in.
create table if not exists member_discord (
  user_id    uuid primary key references profiles(id) on delete cascade,
  handle     text not null,
  updated_at timestamptz not null default now(),
  constraint member_discord_handle_check
    check (char_length(btrim(handle)) between 2 and 40 and handle !~ '[[:cntrl:]]')
);
alter table member_discord enable row level security;

-- True when the caller and p_user are both active (not dropped) in at least
-- one same league that is not archived. Anyone signed in can join a public
-- league, so in a public league the name reaches whoever joins it (the
-- privacy notice says so).
create or replace function shares_league_with(p_user uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select auth.uid() is not null and exists (
    select 1 from memberships a
    join memberships b on b.league_id = a.league_id
    join leagues l on l.id = a.league_id and l.archived_at is null
    where a.user_id = auth.uid() and a.dropped_at is null
      and b.user_id = p_user and b.dropped_at is null
  );
$$;
revoke all on function shares_league_with(uuid) from public, anon;
grant execute on function shares_league_with(uuid) to authenticated;

drop policy if exists "member discord read" on member_discord;
create policy "member discord read" on member_discord
  for select using (user_id = auth.uid() or shares_league_with(user_id));
drop policy if exists "member discord insert own" on member_discord;
create policy "member discord insert own" on member_discord
  for insert with check (user_id = auth.uid());
drop policy if exists "member discord update own" on member_discord;
create policy "member discord update own" on member_discord
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "member discord delete own" on member_discord;
create policy "member discord delete own" on member_discord
  for delete using (user_id = auth.uid());

revoke all on member_discord from public, anon, authenticated;
grant select, insert, update, delete on member_discord to authenticated;

-- The database's own time stamp, and the handle trimmed.
create or replace function touch_member_discord()
returns trigger language plpgsql set search_path = public as $$
begin
  new.handle := btrim(new.handle);
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists member_discord_touch on member_discord;
create trigger member_discord_touch before insert or update on member_discord
  for each row execute function touch_member_discord();

-- erase_user_data(): same as 2026-11-06, plus the member Discord name.
create or replace function erase_user_data(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  l record;
begin
  if p_user is null then
    return;
  end if;
  for l in select id, name, archived_at from leagues where owner_id = p_user for update loop
    if not exists (select 1 from memberships m where m.league_id = l.id and m.user_id <> p_user)
       and not exists (select 1 from matches mt where mt.league_id = l.id)
       and not exists (select 1 from attendance a join sessions s on s.id = a.session_id
                       where s.league_id = l.id and a.user_id <> p_user) then
      delete from leagues where id = l.id;
    elsif l.archived_at is null and exists (
      select 1 from memberships m
      where m.league_id = l.id and m.user_id <> p_user and m.dropped_at is null
    ) then
      raise exception 'This account owns the league "%", which still has players. Hand it over to one of them or archive it first (Manage).', l.name
        using errcode = 'P0001', hint = 'sl_owns_league';
    else
      update leagues set archived_at = coalesce(archived_at, now()) where id = l.id;
    end if;
  end loop;

  delete from collection     where user_id = p_user;
  delete from free_battles   where user_id = p_user;
  delete from decks          where user_id = p_user and not is_public;
  delete from feedback       where user_id = p_user;
  delete from site_admins    where user_id = p_user;
  delete from member_discord where user_id = p_user;

  update memberships
     set dropped_at = coalesce(dropped_at, now()), is_admin = false
   where user_id = p_user and (dropped_at is null or is_admin);

  update profiles
     set display_name = 'Deleted player',
         role = 'player',
         herald_rank = null,
         discord = null,
         malediction_url = null,
         lat = null,
         lon = null,
         place = null,
         deleted_at = coalesce(deleted_at, now())
   where id = p_user;
end $$;
revoke all on function erase_user_data(uuid) from public, anon, authenticated;

-- ============================================================
--  12. public_leagues (three columns appended)
-- ============================================================
-- "create or replace view" may only append columns, which is all this does,
-- so the view is not dropped and keeps its grants. Still security_invoker.
-- discord_url is not here: the league page reads it from leagues.
create or replace view public_leagues
with (security_invoker = on) as
select
  l.id, l.name, l.location, l.city, l.country, l.description, l.created_at,
  (select count(*) from memberships m where m.league_id = l.id) as member_count,
  (select count(*) from sessions s where s.league_id = l.id)    as session_count,
  (select max(s.date) from sessions s where s.league_id = l.id) as last_session,
  l.lat, l.lon,
  l.is_online, l.region, l.timezone
from leagues l
where l.is_public;



-- ============================================================
--  PINNED NOTICES (2026-11-07)
-- ============================================================
-- A notice can be pinned to the top of the board. Pinning goes through
-- set_notice_pinned() only: there is still no update policy on announcements.
alter table public.announcements add column if not exists pinned boolean not null default false;

create or replace function public.set_notice_pinned(p_id uuid, p_pinned boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_league uuid;
begin
  select league_id into v_league from announcements where id = p_id;
  if not found then
    raise exception 'notice not found';
  end if;
  if not (case when v_league is null then is_site_admin() else (is_site_admin() or is_league_admin(v_league)) end) then
    raise exception 'not allowed';
  end if;
  update announcements set pinned = coalesce(p_pinned, false) where id = p_id;
end $$;

revoke all on function public.set_notice_pinned(uuid, boolean) from public, anon;
grant execute on function public.set_notice_pinned(uuid, boolean) to authenticated;
