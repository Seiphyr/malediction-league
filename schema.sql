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

-- ============================================================
--  COMMUNITIES AND PLAY NETWORK EVENTS (2026-11-08)
-- ============================================================
-- Replaces the "COMMUNITY PERMISSIONS (2026-11-07)" section (all of it is
-- here). Run as migration-2026-11-08-communities.sql.
-- What changes:
--   * Deleting a community: only the site admin, through admin_delete_league()
--     (the "Approve and delete" button on a deletion request in Admin), and
--     only when the request was sent by the community's current creator.
--     Anyone can send feedback, so a request from someone else is refused.
--     The creator asks from Manage; the old "owner deletes league" policy goes.
--     erase_user_data() keeps deleting empty communities of a deleted account
--     (it runs as the database owner, so the policy never applied to it).
--   * Archive and reopen: only the creator (and the site admin, as before).
--   * Organizers: only the creator promotes or demotes, and drops or removes
--     a co-organizer. A co-organizer can still leave by themselves. Nobody
--     but the creator touches the creator's row, and the creator cannot leave
--     their own community (hand it over first).
--   * If the creator deleted their account (the community was kept, owned by
--     the "Deleted player"), the organizers take over archive, reopen and the
--     organizer changes, as before. Deleting such a community is done by the
--     site admin in the SQL editor.
--   * Unchanged: co-organizers still edit rules, notices and players.
--   * pn_events: a community lists official Play Network events, filled in by
--     the edge function play-network-event (fetch_ok = true) or typed in by
--     an organizer when that fails (fetch_ok = false, the only editable ones).
--   * pn_fetch_log / pn_fetch_allow(): the brake the edge function applies
--     before each look-up of the official site.
--   * Nothing is dropped or deleted: old league events, check-ins, matches
--     and points stay in the database untouched; the site stops showing them.
--     Organizers can no longer delete old events, check-ins or matches (the
--     previous page still could), nor a tournament that has matches; only
--     the site admin can.
--   * public_leagues counts active players only and gains last_event.

-- The creator of a community, for the guards and policies below. Security
-- definer, but it answers only about a community the caller can see anyway
-- (public, or one they belong to), so it reveals nothing new.
create or replace function public.league_owner_id(p_league uuid)
returns uuid language sql security definer stable set search_path = public as $$
  select l.owner_id from leagues l
  where l.id = p_league
    and (l.is_public or l.owner_id = auth.uid() or is_league_member(l.id) or is_site_admin());
$$;
revoke all on function public.league_owner_id(uuid) from public, anon;
grant execute on function public.league_owner_id(uuid) to authenticated;

-- The creator's account was deleted. Same visibility rule as above.
create or replace function public.league_creator_gone(p_league uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from leagues l join profiles p on p.id = l.owner_id
    where l.id = p_league and p.deleted_at is not null
      and (l.is_public or is_league_member(l.id) or is_site_admin())
  );
$$;
revoke all on function public.league_creator_gone(uuid) from public, anon;
grant execute on function public.league_creator_gone(uuid) to authenticated;

-- 1. Deleting a community ------------------------------------------------
drop policy if exists "owner deletes league" on public.leagues;

-- p_request is the feedback row with the request. The community is deleted
-- only if that row asks for it and was sent by its current creator.
drop function if exists public.admin_delete_league(uuid);
create or replace function public.admin_delete_league(p_request uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  f feedback%rowtype;
  v_league uuid;
  v_owner uuid;
begin
  if not is_site_admin() then
    raise exception 'Only the site admin can delete a community' using errcode = '42501';
  end if;
  select * into f from feedback where id = p_request;
  if not found or f.context->>'request' is distinct from 'delete_community' then
    raise exception 'This is not a request to delete a community';
  end if;
  begin
    v_league := (f.context->>'league_id')::uuid;
  exception when others then
    raise exception 'This is not a request to delete a community';
  end;
  if v_league is null then
    raise exception 'This is not a request to delete a community';
  end if;
  select owner_id into v_owner from leagues where id = v_league for update;
  if not found then
    raise exception 'Community not found';
  end if;
  if f.user_id is null or f.user_id is distinct from v_owner then
    raise exception 'This request was not sent by the creator of the community' using errcode = '42501';
  end if;
  -- Events, check-ins, matches, members, tournaments and notices go with it
  -- (on delete cascade).
  delete from leagues where id = v_league;
end $$;
revoke all on function public.admin_delete_league(uuid) from public, anon;
grant execute on function public.admin_delete_league(uuid) to authenticated;

-- 2. Archive and reopen: the creator only --------------------------------
-- Not security definer on purpose: current_user is then the caller's role.
create or replace function public.guard_league_update()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if not is_league_admin(old.id) then
    if (to_jsonb(new) - 'archived_at') is distinct from (to_jsonb(old) - 'archived_at') then
      raise exception 'A site admin can only archive or reopen a community' using errcode = '42501';
    end if;
    return new;
  end if;
  if new.archived_at is distinct from old.archived_at
     and auth.uid() is distinct from old.owner_id and not is_site_admin()
     and not league_creator_gone(old.id) then
    raise exception 'Only the creator can archive or reopen this community' using errcode = '42501';
  end if;
  if old.is_public and not new.is_public and new.join_code is not distinct from old.join_code then
    new.join_code := gen_join_code();
  end if;
  return new;
end $$;

-- 3. Organizers and the creator's row ------------------------------------
-- Not security definer on purpose: current_user is then the caller's role.
-- membership_drop_stamp runs first, so a row being dropped already has
-- is_admin = false here: that is leaving or being dropped, not a demotion.
create or replace function public.guard_membership_update()
returns trigger language plpgsql set search_path = public as $$
declare
  v_owner uuid;
  v_dropping boolean;
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
    v_owner := league_owner_id(old.league_id);
    v_dropping := old.dropped_at is null and new.dropped_at is not null;
    if v_dropping and old.user_id = v_owner then
      raise exception 'The creator cannot leave their own community. Hand it over in Manage first.'
        using errcode = '42501';
    end if;
    if auth.uid() is distinct from v_owner and not league_creator_gone(old.league_id) then
      if old.user_id = v_owner then
        raise exception 'Only the creator can change their own membership' using errcode = '42501';
      end if;
      if (new.is_admin and not old.is_admin)
         or (old.is_admin and not new.is_admin and new.dropped_at is null) then
        raise exception 'Only the creator can promote or demote organizers' using errcode = '42501';
      end if;
      if v_dropping and old.is_admin and old.user_id is distinct from auth.uid() then
        raise exception 'Only the creator can drop an organizer' using errcode = '42501';
      end if;
    end if;
    if old.dropped_at is not null and new.dropped_at is null
       and old.user_id is distinct from auth.uid()
       and old.dropped_by is not distinct from old.user_id then
      raise exception 'This player left the community themselves. They can rejoin with the join code.'
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

-- Handing a community over: as before (only the creator, only to an active
-- member), and the new creator's row is now marked organizer here, so that
-- if they hand it over in turn they stay a co-organizer, as the old creator
-- does. The app used to do it with a second request, which the guard above
-- now refuses (it touches the creator's row).
create or replace function public.guard_league_owner()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.owner_id is distinct from old.owner_id then
    if auth.uid() <> old.owner_id then
      raise exception 'Only the creator can hand the community over';
    end if;
    if auth.uid() is not null and not exists (
      select 1 from memberships m
      where m.league_id = new.id and m.user_id = new.owner_id and m.dropped_at is null
    ) then
      raise exception 'The new creator must be an active member of this community';
    end if;
    update memberships set is_admin = true
     where league_id = new.id and user_id = new.owner_id and not is_admin;
  end if;
  return new;
end;
$$;

-- Removing a row (the app never does, players are dropped instead): never
-- the creator's row, and a co-organizer's row only by the creator.
drop policy if exists "admin removes" on public.memberships;
create policy "admin removes" on public.memberships
  for delete using (
    is_league_admin(league_id)
    and user_id is distinct from league_owner_id(league_id)
    and (is_league_owner(league_id) or not is_admin)
  );

-- 4. Play Network event listings -----------------------------------------
-- A community's events are now listings of official Play Network events
-- (https://malediction.gg/play-network/events/single/<id>/<slug>/).
-- The edge function play-network-event reads the official page and writes
-- the listing with fetch_ok = true, as the service role. When that fails, an
-- organizer types the details by hand: those rows have fetch_ok = false, and
-- only they can be edited from the site. A listing keeps how many players
-- registered, never who.
-- Old league events (sessions, check-ins, matches) stay in the database,
-- untouched. The site no longer shows them.

-- The canonical form of an event link, or null when it is not one. Accepts
-- www., a missing trailing slash and a query or fragment (dropped). The slug
-- is required: without it the official site answers with a broken redirect.
create or replace function public.pn_canonical_url(p_url text)
returns text language sql immutable set search_path = public as $$
  select case when length(p_url) <= 500 then
    'https://malediction.gg/play-network/events/single/' || m[1] || '/' || lower(m[2]) || '/'
  end
  from regexp_match(btrim(coalesce(p_url, '')),
    '^https://(?:www\.)?malediction\.gg/play-network/events/single/([1-9][0-9]{0,8})/((?:[a-z0-9-]|%[0-9a-f]{2}){1,200})/?(?:[?#].*)?$',
    'i') as m;
$$;

create table if not exists public.pn_events (
  id                 uuid primary key default gen_random_uuid(),
  league_id          uuid not null references public.leagues(id) on delete cascade,
  pn_id              integer not null,
  url                text not null,           -- canonical, see pn_canonical_url
  title              text not null,
  starts_at          timestamptz,
  ends_at            timestamptz,
  venue              text,                    -- store name, or the online platform
  city               text,
  country            text,
  location_type      text,                    -- 'Local' or 'Online'
  type_name          text,                    -- Tournament, Casual Play, ...
  format             text,                    -- Swiss, ...
  max_players        integer,
  participants_count integer,                 -- how many registered, never who
  fetch_ok           boolean not null default false, -- true: written by the edge function
  fetched_at         timestamptz,
  created_by         uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at         timestamptz default now(),
  updated_at         timestamptz,
  constraint pn_events_one_per_community unique (league_id, pn_id),
  constraint pn_events_url_format check (url ~ '^https://malediction\.gg/play-network/events/single/[1-9][0-9]{0,8}/([a-z0-9-]|%[0-9a-f]{2}){1,200}/$'),
  constraint pn_events_url_id check (pn_id = (substring(url from '/single/([0-9]+)/'))::integer),
  constraint pn_events_title_len check (char_length(title) between 1 and 200),
  constraint pn_events_venue_len check (venue is null or char_length(venue) between 1 and 200),
  constraint pn_events_city_len check (city is null or char_length(city) between 1 and 100),
  constraint pn_events_country_len check (country is null or char_length(country) between 1 and 100),
  constraint pn_events_location_type check (location_type is null or location_type in ('Local', 'Online')),
  constraint pn_events_type_len check (type_name is null or char_length(type_name) between 1 and 60),
  constraint pn_events_format_len check (format is null or char_length(format) between 1 and 60),
  constraint pn_events_counts check ((max_players is null or max_players between 0 and 100000)
                                 and (participants_count is null or participants_count between 0 and 100000)),
  constraint pn_events_dates check (ends_at is null or (starts_at is not null and ends_at >= starts_at)),
  constraint pn_events_fetched check (not fetch_ok or fetched_at is not null)
);
create index if not exists idx_pn_events_league_start on public.pn_events(league_id, starts_at);
create index if not exists idx_pn_events_created_by on public.pn_events(created_by);

alter table public.pn_events enable row level security;
drop policy if exists "pn events visible" on public.pn_events;
drop policy if exists "organizers add pn events" on public.pn_events;
drop policy if exists "organizers edit pn events" on public.pn_events;
drop policy if exists "organizers remove pn events" on public.pn_events;
-- Same reach as the notice board: public communities for everyone (signed
-- out too), private ones for their members, and the site admin.
create policy "pn events visible" on public.pn_events
  for select using (league_is_public(league_id) or is_league_member(league_id) or is_site_admin());
-- Hand-typed listings only (the guard below forces fetch_ok = false).
create policy "organizers add pn events" on public.pn_events
  for insert to authenticated with check (is_league_admin(league_id) and not fetch_ok);
-- The guard refuses edits of a listing filled in from Play Network.
create policy "organizers edit pn events" on public.pn_events
  for update to authenticated using (is_league_admin(league_id)) with check (is_league_admin(league_id));
create policy "organizers remove pn events" on public.pn_events
  for delete to authenticated using (is_league_admin(league_id));

revoke all on public.pn_events from anon, authenticated;
grant select on public.pn_events to anon, authenticated;
grant insert (league_id, pn_id, url, title, starts_at, ends_at, venue, city, country, location_type,
              type_name, format, max_players, participants_count, fetch_ok)
  on public.pn_events to authenticated;
grant update (title, starts_at, ends_at, venue, city, country, location_type,
              type_name, format, max_players, participants_count)
  on public.pn_events to authenticated;
grant delete on public.pn_events to authenticated;
grant select, insert, update, delete on public.pn_events to service_role;

-- Requests from the site. Not security definer on purpose: current_user is
-- then the caller's role. The edge function (service_role) and functions
-- owned by the database owner pass straight through.
create or replace function public.guard_pn_event()
returns trigger language plpgsql set search_path = public as $$
declare
  v_league uuid;
  v_url text;
begin
  if tg_op = 'UPDATE' then
    new.updated_at := now();
  end if;
  if current_user not in ('authenticated', 'anon') then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;
  if tg_op = 'DELETE' then
    v_league := old.league_id;
  else
    v_league := new.league_id;
  end if;
  if tg_op = 'UPDATE' and new.league_id is distinct from old.league_id then
    raise exception 'A listing cannot be moved to another community' using errcode = '42501';
  end if;
  if exists (select 1 from leagues l where l.id = v_league and l.archived_at is not null) then
    raise exception 'This community is archived' using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  if tg_op = 'INSERT' then
    v_url := pn_canonical_url(new.url);
    if v_url is null then
      raise exception 'This is not a Play Network event link' using errcode = '22023';
    end if;
    -- Counts the listings there now, not every write: removing some makes room
    -- again. It only affects the organizer's own community.
    if (select count(*) from pn_events e
        where e.league_id = new.league_id and e.created_at > now() - interval '1 day') >= 30 then
      raise exception 'This community added 30 events in the last 24 hours. Try again tomorrow.'
        using errcode = '42501';
    end if;
    new.url        := v_url;
    new.pn_id      := (substring(v_url from '/single/([0-9]+)/'))::integer;
    new.fetch_ok   := false;
    new.fetched_at := null;
    new.created_by := auth.uid();
    new.created_at := now();
    new.updated_at := null;
  else
    if old.fetch_ok then
      raise exception 'This event is filled in from Play Network. Refresh it instead of editing it.'
        using errcode = '42501';
    end if;
    if new.id is distinct from old.id
       or new.pn_id is distinct from old.pn_id
       or new.url is distinct from old.url
       or new.fetch_ok is distinct from old.fetch_ok
       or new.fetched_at is distinct from old.fetched_at
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at then
      raise exception 'Only the event details can be edited' using errcode = '42501';
    end if;
  end if;
  new.title         := nullif(btrim(new.title), '');
  new.venue         := nullif(btrim(new.venue), '');
  new.city          := nullif(btrim(new.city), '');
  new.country       := nullif(btrim(new.country), '');
  new.location_type := nullif(btrim(new.location_type), '');
  new.type_name     := nullif(btrim(new.type_name), '');
  new.format        := nullif(btrim(new.format), '');
  if new.title is null then
    raise exception 'An event needs a title' using errcode = '23514';
  end if;
  return new;
end $$;
drop trigger if exists pn_event_guard on public.pn_events;
create trigger pn_event_guard before insert or update or delete on public.pn_events
  for each row execute function public.guard_pn_event();

-- Every look-up of the official site is logged here first, so the edge
-- function cannot be used to flood Play Network. Only an account id, a
-- community and a time, purged after two days.
create table if not exists public.pn_fetch_log (
  id         bigint generated always as identity primary key,
  user_id    uuid not null,
  league_id  uuid,
  created_at timestamptz not null default now()
);
create index if not exists idx_pn_fetch_log_user on public.pn_fetch_log(user_id, created_at);
create index if not exists idx_pn_fetch_log_created on public.pn_fetch_log(created_at);
alter table public.pn_fetch_log enable row level security;
revoke all on public.pn_fetch_log from anon, authenticated;

-- Called by the edge function AS THE CALLER before it fetches anything.
-- True (and the look-up is logged) only for an organizer of a community that
-- is not archived, under 20 look-ups by that account and 300 on the whole
-- site in the last hour. Refused attempts are not logged, so nobody can
-- use up the site's quota without fetching.
create or replace function public.pn_fetch_allow(p_league uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null or p_league is null then
    return false;
  end if;
  if not is_league_admin(p_league) then
    return false;
  end if;
  if exists (select 1 from leagues l where l.id = p_league and l.archived_at is not null) then
    return false;
  end if;
  perform pg_advisory_xact_lock(hashtext('pn_fetch_allow'));
  delete from pn_fetch_log where created_at < now() - interval '2 days';
  if (select count(*) from pn_fetch_log
      where user_id = v_uid and created_at > now() - interval '1 hour') >= 20 then
    return false;
  end if;
  if (select count(*) from pn_fetch_log where created_at > now() - interval '1 hour') >= 300 then
    return false;
  end if;
  insert into pn_fetch_log (user_id, league_id) values (v_uid, p_league);
  return true;
end $$;
revoke all on function public.pn_fetch_allow(uuid) from public, anon;
grant execute on function public.pn_fetch_allow(uuid) to authenticated;

-- 5. Old league data stays: no deletes by organizers ----------------------
-- Old league events, check-ins and matches are hidden, never deleted. The
-- previous page (or a direct API call) could still delete them as an
-- organizer, and deleting an event also deleted its check-ins and matches
-- (on delete cascade). Now only the site admin can, as in the SQL editor.
drop policy if exists "admins delete sessions" on public.sessions;
drop policy if exists "delete own unconfirmed or admin" on public.matches;
drop policy if exists "site admin deletes matches" on public.matches;
create policy "site admin deletes matches" on public.matches
  for delete using (is_site_admin());
drop policy if exists "self or admin remove attendance" on public.attendance;
drop policy if exists "site admin removes attendance" on public.attendance;
create policy "site admin removes attendance" on public.attendance
  for delete using (is_site_admin());
-- A tournament from the time they were linked to events also stored its
-- results as that event's matches (matches.tournament_id, on delete
-- cascade), so only a tournament without such matches can be discarded.
-- The site already refuses it ("it stays").
drop policy if exists "admins delete tournaments" on public.tournaments;
create policy "admins delete tournaments" on public.tournaments
  for delete using (
    is_league_admin(league_id)
    and session_id is null
    and not exists (select 1 from matches m where m.tournament_id = tournaments.id)
  );

-- 6. public_leagues: active players only, and the latest listed event -----
-- member_count leaves out players who left or were dropped, as the community
-- page does. last_event (appended, so the view keeps its grants) is the
-- latest Play Network listing; the list sorts by it, since old league events
-- (last_session) are no longer added. Still security_invoker.
create or replace view public_leagues
with (security_invoker = on) as
select
  l.id, l.name, l.location, l.city, l.country, l.description, l.created_at,
  (select count(*) from memberships m where m.league_id = l.id and m.dropped_at is null) as member_count,
  (select count(*) from sessions s where s.league_id = l.id)    as session_count,
  (select max(s.date) from sessions s where s.league_id = l.id) as last_session,
  l.lat, l.lon,
  l.is_online, l.region, l.timezone,
  (select max(e.starts_at) from pn_events e where e.league_id = l.id) as last_event
from leagues l
where l.is_public;

-- ============================================================
--  MATCH TRACKER (2026-11-09)
-- ============================================================
-- Run as migration-2026-11-09-tracker.sql.
-- What changes:
--   * New table duels: one row per synced match between two signed-in
--     players (Clash to 40 or Demo to 25). The host opens it and gets a
--     4-digit PIN, valid 15 minutes and only while waiting; the guest joins
--     with it. Only the two players can read the row, and nobody writes it
--     directly: everything goes through the duel_* functions.
--   * Functions duel_open, duel_join, duel_checkpoint, duel_claim,
--     duel_answer, duel_cancel and duel_get (signed-in players only). A
--     result is final when the opponent confirms it, or at once when a
--     player concedes (names the opponent as the winner).
--   * PIN guessing brakes: wrong PINs per account 5 a minute, 20 an hour,
--     60 a day; 600 wrong PINs on the whole site in 10 minutes pause joining.
--     At most 30 new matches an hour per account, 2000 waiting on the site.
--     Wrong PINs are kept in duel_join_attempts (an account id and a time,
--     deleted after 2 days).
--   * duel_sweep(): expires waiting matches, cancels live matches idle for
--     12 hours and saves results left unanswered for 48 hours as claimed. Matches that never
--     started are deleted after 7 days, cancelled ones after 30 days;
--     finished matches stay. Runs every 10 minutes through pg_cron
--     (sl-duel-sweep) when the project has it, and on every open and join.
--   * Realtime: private channels 'duel:<id>' that only the two players can
--     join, send on and read (policies on realtime.messages), and a trigger
--     that broadcasts 'duel_status' on the channel when the status, the
--     claim or the guest changes.
--   * profiles.matches_visibility ('public', 'players' or 'private', default
--     'public'): who sees a player's Matches list. player_matches() reads
--     that list; meta_duels() gives the Meta every finished match without
--     player ids.
--   * Free battles: no new rows (the "fb own write" policy goes). Old rows
--     stay, readable and deletable by their owner only.
--   * erase_user_data(): also cancels the account's open matches and deletes
--     its wrong-PIN rows. Finished matches stay for the opponent, against
--     "Deleted player".

-- 1. Who sees a player's matches --------------------------------------------
-- 'public' anyone (signed out too), 'players' signed-in players, 'private'
-- only the player. Both players of a match always see it in their own list.
-- Players change it on their own profile row ("own profile update" policy;
-- guard_profile_update only blocks deleted accounts and deleted_at).
alter table public.profiles add column if not exists matches_visibility text not null default 'public';
do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'profiles_matches_visibility_check' and conrelid = 'public.profiles'::regclass) then
    alter table public.profiles add constraint profiles_matches_visibility_check
      check (matches_visibility in ('public','players','private'));
  end if;
end $$;

-- 2. The duels table: one row per synced match --------------------------------
-- The host opens it (status waiting, with a 4-digit PIN valid 15 minutes),
-- the guest joins with the PIN (live, the PIN is cleared), one player claims
-- the result (ending) and the other confirms it (done), or the claim names
-- the opponent, which is a concession and final at once. Either player can
-- cancel before the end. Live tracker taps travel over Realtime broadcast on
-- the private topic 'duel:<id>'; state is only the last checkpoint, for
-- reconnecting. tournament_id and t_ref are for tournament games (later).
create table if not exists public.duels (
  id             uuid primary key default gen_random_uuid(),
  pin            text,
  pin_expires_at timestamptz,
  status         text not null default 'waiting'
                 check (status in ('waiting','live','ending','done','cancelled','expired')),
  mode           text not null check (mode in ('clash','demo')),
  target         int  not null,
  host_id        uuid not null references public.profiles(id),
  guest_id       uuid references public.profiles(id),
  host_seeker    text not null,
  host_terrain   text not null,
  host_deck_id   uuid references public.decks(id) on delete set null,
  guest_seeker   text,
  guest_terrain  text,
  guest_deck_id  uuid references public.decks(id) on delete set null,
  state          jsonb,
  state_at       timestamptz,            -- time of the last checkpoint (the 5 s brake)
  claim_by       uuid references public.profiles(id),
  claim_winner   uuid references public.profiles(id),
  claimed_at     timestamptz,            -- when the result was sent; saved as claimed after 48 h
  winner_id      uuid references public.profiles(id),
  loser_id       uuid references public.profiles(id),
  winner_score   int,
  loser_score    int,
  rounds         int,
  tournament_id  uuid references public.tournaments(id) on delete set null,
  t_ref          text,
  created_at     timestamptz not null default now(),
  started_at     timestamptz,
  ended_at       timestamptz,
  updated_at     timestamptz not null default now(),
  constraint duels_pin_only_waiting check ((status = 'waiting') = (pin is not null)),
  constraint duels_pin_format check (pin is null or pin ~ '^[0-9]{4}$'),
  constraint duels_guest_when_joined check (status not in ('live','ending','done') or guest_id is not null),
  constraint duels_guest_not_host check (guest_id is null or guest_id <> host_id),
  constraint duels_done_has_result check (status <> 'done' or (winner_id is not null and loser_id is not null))
);
create unique index if not exists duels_pin_waiting on public.duels(pin) where status = 'waiting';
create index if not exists idx_duels_host on public.duels(host_id, created_at);
create index if not exists idx_duels_guest on public.duels(guest_id);
create index if not exists idx_duels_open on public.duels(status, updated_at)
  where status in ('waiting','live','ending');
create index if not exists idx_duels_done on public.duels(ended_at) where status = 'done';
create index if not exists idx_duels_host_deck on public.duels(host_deck_id);
create index if not exists idx_duels_guest_deck on public.duels(guest_deck_id);
create index if not exists idx_duels_tournament on public.duels(tournament_id);

-- Only the two players read the row; a waiting row (with its PIN) has no
-- guest yet, so only its host sees it. Nothing is written directly: every
-- change goes through the functions below.
alter table public.duels enable row level security;
revoke all on public.duels from anon, authenticated;
grant select on public.duels to authenticated;
drop policy if exists "duel players read" on public.duels;
create policy "duel players read" on public.duels
  for select to authenticated using (auth.uid() = host_id or auth.uid() = guest_id);

-- Wrong PINs, for the guessing brakes. Only an account id and a time,
-- purged after two days by duel_sweep().
create table if not exists public.duel_join_attempts (
  id         bigint generated always as identity primary key,
  user_id    uuid not null,
  created_at timestamptz not null default now()
);
create index if not exists idx_duel_join_attempts_user on public.duel_join_attempts(user_id, created_at);
create index if not exists idx_duel_join_attempts_created on public.duel_join_attempts(created_at);
alter table public.duel_join_attempts enable row level security;
revoke all on public.duel_join_attempts from anon, authenticated;

-- 3. Small helpers (not callable over the API) ----------------------------------
-- The signed-in caller: a real (not anonymous) login with a profile that was
-- not deleted. Raises otherwise.
create or replace function public.duel_caller()
returns uuid language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null or coalesce((auth.jwt()->>'is_anonymous')::boolean, false) then
    raise exception 'Sign in first' using errcode = '42501';
  end if;
  if not exists (select 1 from profiles p where p.id = v_uid and p.deleted_at is null) then
    raise exception 'This account was deleted' using errcode = '42501';
  end if;
  return v_uid;
end $$;

-- A Seeker or terrain name: control characters stripped, trimmed, at most
-- 80 characters, null when empty.
create or replace function public.duel_clean(p text)
returns text language sql immutable set search_path = public as $$
  select nullif(left(btrim(regexp_replace(coalesce(p, ''), '[[:cntrl:]]', '', 'g')), 80), '');
$$;

-- A free PIN among the waiting matches, 0000 to 9999, from the strong random
-- source behind gen_random_uuid(). Two bytes give 0..65535; values from
-- 60000 up are dropped so every PIN is equally likely. Bytes 6 to 9 carry
-- the uuid version and variant bits, so they are skipped.
create or replace function public.gen_duel_pin()
returns text language plpgsql volatile security definer set search_path = public as $$
declare
  b bytea;
  o int;
  v int;
  c text;
  n int := 0;
begin
  loop
    b := uuid_send(gen_random_uuid());
    foreach o in array array[0, 2, 4, 10, 12, 14] loop
      v := get_byte(b, o) * 256 + get_byte(b, o + 1);
      if v < 60000 then
        c := lpad((v % 10000)::text, 4, '0');
        if not exists (select 1 from duels d where d.status = 'waiting' and d.pin = c) then
          return c;
        end if;
      end if;
    end loop;
    n := n + 1;
    if n > 50 then
      raise exception 'Could not find a free PIN. Try again in a few minutes.'
        using errcode = 'P0001', hint = 'busy';
    end if;
  end loop;
end $$;

-- Housekeeping: a waiting match expires with its PIN, a live match idle for
-- 12 hours is cancelled, and a claimed result nobody answers for 48 hours
-- is saved as claimed.
-- Matches that never started go after 7 days, cancelled ones after 30 days,
-- wrong-PIN rows after 2 days. Finished matches stay. Called by duel_open()
-- and duel_join(), and by pg_cron where the project has it (below). Only one
-- sweep runs at a time; a call that finds one running skips.
create or replace function public.duel_sweep()
returns integer language plpgsql security definer set search_path = public as $$
declare
  n int := 0;
  m int;
begin
  if not pg_try_advisory_xact_lock(hashtext('duel_sweep')) then
    return 0;
  end if;
  update duels set status = 'expired', pin = null, ended_at = now(), updated_at = now()
   where status = 'waiting' and pin_expires_at <= now();
  get diagnostics m = row_count; n := n + m;
  update duels set status = 'cancelled', ended_at = now(), updated_at = now()
   where status = 'live' and updated_at < now() - interval '12 hours';
  get diagnostics m = row_count; n := n + m;
  update duels set status = 'done', winner_id = claim_winner,
         loser_id = case when claim_winner = host_id then guest_id else host_id end,
         ended_at = now(), updated_at = now()
   where status = 'ending' and claim_winner is not null
     and coalesce(claimed_at, updated_at) < now() - interval '48 hours';
  get diagnostics m = row_count; n := n + m;
  delete from duels where status = 'expired' and created_at < now() - interval '7 days';
  delete from duels where status = 'cancelled' and created_at < now() - interval '30 days';
  delete from duel_join_attempts where created_at < now() - interval '2 days';
  return n;
end $$;

revoke all on function public.duel_caller()   from public, anon, authenticated;
revoke all on function public.duel_clean(text) from public, anon, authenticated;
revoke all on function public.gen_duel_pin()  from public, anon, authenticated;
revoke all on function public.duel_sweep()    from public, anon, authenticated;

-- 4. Opening and joining -----------------------------------------------------
-- duel_open: the host picks the mode (clash 40, demo 25), their Seeker,
-- terrain and optionally one of their own decks, and gets a PIN. Their
-- previous waiting match is cancelled (every new match or reset has a new
-- PIN). At most 30 opens per hour per account and 2000 waiting matches on
-- the whole site (a fifth of the PINs). Refusals raise, with hint
-- 'rate_limited' or 'busy'.
create or replace function public.duel_open(p_mode text, p_seeker text, p_terrain text, p_deck_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid     uuid := duel_caller();
  v_seeker  text := duel_clean(p_seeker);
  v_terrain text := duel_clean(p_terrain);
  v_target  int;
  v_pin     text;
  v_id      uuid;
  v_exp     timestamptz := now() + interval '15 minutes';
  i         int;
begin
  if p_mode = 'clash' then
    v_target := 40;
  elsif p_mode = 'demo' then
    v_target := 25;
  else
    raise exception 'A synced match is Clash or Demo' using errcode = '22023';
  end if;
  if v_seeker is null or v_terrain is null then
    raise exception 'Pick your Seeker and terrain first' using errcode = '22023';
  end if;
  if p_deck_id is not null
     and not exists (select 1 from decks k where k.id = p_deck_id and k.user_id = v_uid) then
    raise exception 'Pick one of your own decks' using errcode = '42501';
  end if;

  perform duel_sweep();
  perform pg_advisory_xact_lock(hashtext('duel_open:' || v_uid::text));
  if (select count(*) from duels d
      where d.host_id = v_uid and d.created_at > now() - interval '1 hour') >= 30 then
    raise exception 'You started 30 matches in the last hour. Try again later.'
      using errcode = 'P0001', hint = 'rate_limited';
  end if;
  update duels set status = 'cancelled', pin = null, ended_at = now(), updated_at = now()
   where host_id = v_uid and status = 'waiting';
  if (select count(*) from duels d where d.status = 'waiting') >= 2000 then
    raise exception 'Too many matches are waiting for an opponent right now. Try again in a few minutes.'
      using errcode = 'P0001', hint = 'busy';
  end if;

  i := 0;
  loop
    i := i + 1;
    v_pin := gen_duel_pin();
    begin
      insert into duels (pin, pin_expires_at, status, mode, target, host_id,
                         host_seeker, host_terrain, host_deck_id)
      values (v_pin, v_exp, 'waiting', p_mode, v_target, v_uid,
              v_seeker, v_terrain, p_deck_id)
      returning id into v_id;
      exit;
    exception when unique_violation then
      if i >= 5 then
        raise exception 'Could not find a free PIN. Try again in a few minutes.'
          using errcode = 'P0001', hint = 'busy';
      end if;
    end;
  end loop;

  return jsonb_build_object('id', v_id, 'pin', v_pin, 'pin_expires_at', v_exp, 'server_now', now());
end $$;

-- duel_join: the guest types the PIN with their own Seeker, terrain and
-- optional deck. It answers instead of raising when the PIN is refused, so
-- the wrong-PIN row is kept. Wrong PINs per account: 5 a minute, 20 an hour,
-- 60 a day ('rate_limited'); 600 wrong PINs on the whole site in 10 minutes
-- pause joining for everyone ('busy'). A malformed PIN, and the caller's own
-- PIN ('own_match'), are not counted. Joining cancels the guest's own
-- waiting match, if any.
create or replace function public.duel_join(p_pin text, p_seeker text, p_terrain text, p_deck_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid     uuid := duel_caller();
  v_seeker  text := duel_clean(p_seeker);
  v_terrain text := duel_clean(p_terrain);
  v_pin     text := btrim(coalesce(p_pin, ''));
  d         duels%rowtype;
begin
  if v_seeker is null or v_terrain is null then
    raise exception 'Pick your Seeker and terrain first' using errcode = '22023';
  end if;
  if p_deck_id is not null
     and not exists (select 1 from decks k where k.id = p_deck_id and k.user_id = v_uid) then
    raise exception 'Pick one of your own decks' using errcode = '42501';
  end if;
  if v_pin !~ '^[0-9]{4}$' then
    return jsonb_build_object('ok', false, 'reason', 'bad_pin');
  end if;

  perform duel_sweep();
  perform pg_advisory_xact_lock(hashtext('duel_join:' || v_uid::text));
  if (select count(*) from duel_join_attempts a
      where a.user_id = v_uid and a.created_at > now() - interval '1 minute') >= 5
     or (select count(*) from duel_join_attempts a
         where a.user_id = v_uid and a.created_at > now() - interval '1 hour') >= 20
     or (select count(*) from duel_join_attempts a
         where a.user_id = v_uid and a.created_at > now() - interval '1 day') >= 60 then
    return jsonb_build_object('ok', false, 'reason', 'rate_limited');
  end if;
  if (select count(*) from duel_join_attempts a
      where a.created_at > now() - interval '10 minutes') >= 600 then
    return jsonb_build_object('ok', false, 'reason', 'busy');
  end if;

  select * into d from duels x where x.pin = v_pin and x.status = 'waiting' for update;
  if not found or d.pin_expires_at <= now() then
    insert into duel_join_attempts (user_id) values (v_uid);
    return jsonb_build_object('ok', false, 'reason', 'bad_pin');
  end if;
  if d.host_id = v_uid then
    return jsonb_build_object('ok', false, 'reason', 'own_match');
  end if;

  update duels set status = 'cancelled', pin = null, ended_at = now(), updated_at = now()
   where host_id = v_uid and status = 'waiting';
  update duels
     set status = 'live', pin = null, guest_id = v_uid,
         guest_seeker = v_seeker, guest_terrain = v_terrain, guest_deck_id = p_deck_id,
         started_at = now(), updated_at = now()
   where id = d.id;

  return jsonb_build_object(
    'ok', true, 'id', d.id, 'host_id', d.host_id,
    'host_name', (select p.display_name from profiles p where p.id = d.host_id),
    'mode', d.mode, 'target', d.target,
    'host_seeker', d.host_seeker, 'host_terrain', d.host_terrain,
    'server_now', now());
end $$;

-- 5. Playing and ending ------------------------------------------------------
-- duel_checkpoint: the last tracker state, so a phone that reconnects can
-- re-sync. A JSON object of at most 8 KB, one write per 5 seconds per match
-- (extra calls answer ok with skipped). Every answer carries the match's
-- status, so a phone that missed a change (a claim, a cancel) re-reads the
-- row. A match that is no longer live or ending answers ok false.
create or replace function public.duel_checkpoint(p_id uuid, p_state jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  d     duels%rowtype;
begin
  if p_state is null or jsonb_typeof(p_state) <> 'object' then
    raise exception 'The match state must be a JSON object' using errcode = '22023';
  end if;
  if octet_length(p_state::text) > 8192 then
    raise exception 'The match state is too large' using errcode = '22023', hint = 'too_large';
  end if;
  select * into d from duels x where x.id = p_id for update;
  if not found or (v_uid is distinct from d.host_id and v_uid is distinct from d.guest_id) then
    raise exception 'This is not one of your matches' using errcode = '42501';
  end if;
  if d.status not in ('live','ending') then
    return jsonb_build_object('ok', false, 'status', d.status);
  end if;
  if d.state_at is not null and d.state_at > now() - interval '5 seconds' then
    return jsonb_build_object('ok', true, 'skipped', true, 'status', d.status);
  end if;
  update duels set state = p_state, state_at = now(), updated_at = now() where id = d.id;
  return jsonb_build_object('ok', true, 'status', d.status);
end $$;

-- duel_claim: a player names the winner of a live match, with the scores,
-- the number of rounds and optionally the final state. Naming the opponent
-- is a concession: the match is done at once. Naming yourself waits for the
-- opponent (status ending). Scores and rounds: 0 to 999, or null.
create or replace function public.duel_claim(p_id uuid, p_winner uuid, p_winner_score int, p_loser_score int,
                                             p_rounds int, p_state jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  d     duels%rowtype;
begin
  if (p_winner_score is not null and p_winner_score not between 0 and 999)
     or (p_loser_score is not null and p_loser_score not between 0 and 999)
     or (p_rounds is not null and p_rounds not between 0 and 999) then
    raise exception 'Scores and rounds must be between 0 and 999' using errcode = '22023';
  end if;
  if p_state is not null and (jsonb_typeof(p_state) <> 'object' or octet_length(p_state::text) > 8192) then
    raise exception 'The match state must be a JSON object of at most 8 KB' using errcode = '22023', hint = 'too_large';
  end if;
  select * into d from duels x where x.id = p_id for update;
  if not found or (v_uid is distinct from d.host_id and v_uid is distinct from d.guest_id) then
    raise exception 'This is not one of your matches' using errcode = '42501';
  end if;
  if d.status <> 'live' then
    return jsonb_build_object('ok', false, 'status', d.status);
  end if;
  if p_winner is null or (p_winner is distinct from d.host_id and p_winner is distinct from d.guest_id) then
    raise exception 'The winner must be one of the two players' using errcode = '22023';
  end if;

  if p_winner <> v_uid then
    update duels
       set status = 'done', claim_by = v_uid, claim_winner = p_winner,
           winner_id = p_winner, loser_id = v_uid,
           winner_score = p_winner_score, loser_score = p_loser_score, rounds = p_rounds,
           state = coalesce(p_state, state), state_at = case when p_state is null then state_at else now() end,
           ended_at = now(), updated_at = now()
     where id = d.id;
    return jsonb_build_object('ok', true, 'status', 'done');
  end if;

  update duels
     set status = 'ending', claim_by = v_uid, claim_winner = v_uid, claimed_at = now(),
         winner_score = p_winner_score, loser_score = p_loser_score, rounds = p_rounds,
         state = coalesce(p_state, state), state_at = case when p_state is null then state_at else now() end,
         updated_at = now()
   where id = d.id;
  return jsonb_build_object('ok', true, 'status', 'ending');
end $$;

-- duel_answer: the player who did not claim accepts (done, as claimed) or
-- rejects ("Not right": back to live, claim cleared).
create or replace function public.duel_answer(p_id uuid, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  d     duels%rowtype;
begin
  select * into d from duels x where x.id = p_id for update;
  if not found or (v_uid is distinct from d.host_id and v_uid is distinct from d.guest_id) then
    raise exception 'This is not one of your matches' using errcode = '42501';
  end if;
  if d.status <> 'ending' then
    return jsonb_build_object('ok', false, 'status', d.status);
  end if;
  if v_uid = d.claim_by then
    raise exception 'Your opponent confirms this result' using errcode = '42501';
  end if;
  if coalesce(p_accept, false) then
    update duels
       set status = 'done', winner_id = d.claim_winner,
           loser_id = case when d.claim_winner = d.host_id then d.guest_id else d.host_id end,
           ended_at = now(), updated_at = now()
     where id = d.id;
    return jsonb_build_object('ok', true, 'status', 'done');
  end if;
  update duels
     set status = 'live', claim_by = null, claim_winner = null, claimed_at = null,
         winner_score = null, loser_score = null, rounds = null, updated_at = now()
   where id = d.id;
  return jsonb_build_object('ok', true, 'status', 'live');
end $$;

-- duel_cancel: either player, while waiting, live or ending. A match that is
-- already over answers ok false with its status.
create or replace function public.duel_cancel(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  d     duels%rowtype;
begin
  select * into d from duels x where x.id = p_id for update;
  if not found or (v_uid is distinct from d.host_id and v_uid is distinct from d.guest_id) then
    raise exception 'This is not one of your matches' using errcode = '42501';
  end if;
  if d.status not in ('waiting','live','ending') then
    return jsonb_build_object('ok', false, 'status', d.status);
  end if;
  update duels set status = 'cancelled', pin = null, ended_at = now(), updated_at = now()
   where id = d.id;
  return jsonb_build_object('ok', true, 'status', 'cancelled');
end $$;

-- duel_get: the row with both names and the server time, for (re)loading a
-- match. Null when the match does not exist or the caller did not play it.
create or replace function public.duel_get(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  d     duels%rowtype;
begin
  select * into d from duels x where x.id = p_id;
  if not found or (v_uid is distinct from d.host_id and v_uid is distinct from d.guest_id) then
    return null;
  end if;
  return to_jsonb(d) || jsonb_build_object(
    'host_name',  (select p.display_name from profiles p where p.id = d.host_id),
    'guest_name', (select p.display_name from profiles p where p.id = d.guest_id),
    'server_now', now());
end $$;

revoke all on function public.duel_open(text, text, text, uuid)                   from public, anon;
revoke all on function public.duel_join(text, text, text, uuid)                   from public, anon;
revoke all on function public.duel_checkpoint(uuid, jsonb)                        from public, anon;
revoke all on function public.duel_claim(uuid, uuid, int, int, int, jsonb)        from public, anon;
revoke all on function public.duel_answer(uuid, boolean)                          from public, anon;
revoke all on function public.duel_cancel(uuid)                                   from public, anon;
revoke all on function public.duel_get(uuid)                                      from public, anon;
grant execute on function public.duel_open(text, text, text, uuid)                to authenticated;
grant execute on function public.duel_join(text, text, text, uuid)                to authenticated;
grant execute on function public.duel_checkpoint(uuid, jsonb)                     to authenticated;
grant execute on function public.duel_claim(uuid, uuid, int, int, int, jsonb)     to authenticated;
grant execute on function public.duel_answer(uuid, boolean)                       to authenticated;
grant execute on function public.duel_cancel(uuid)                                to authenticated;
grant execute on function public.duel_get(uuid)                                   to authenticated;

-- 6. Reading finished matches ------------------------------------------------
-- player_matches: the finished matches of one player, newest first, for the
-- Matches list on their profile, as p_user sees them (my_* is p_user).
-- Shown as p_user's matches_visibility allows; a viewer always sees the
-- matches they played themselves. The opponent's own setting is kept too:
-- when it does not let this viewer see the opponent's matches, the row
-- stays but the opponent is hidden (no id, no Seeker or terrain, the name
-- 'Private player', or 'Deleted player' for a deleted account), so a
-- private history cannot be rebuilt from the opponents' public lists. A
-- tournament is named only when its community is public or the viewer
-- belongs to it.
create or replace function public.player_matches(p_user uuid)
returns table (id uuid, played_at timestamptz, opponent_id uuid, opponent_name text,
               my_seeker text, my_terrain text, opp_seeker text, opp_terrain text,
               won boolean, my_score int, opp_score int,
               tournament_id uuid, tournament_name text)
language sql stable security definer set search_path = public as $$
  with v as (
    select auth.uid() as viewer,
           auth.uid() is not null
             and not coalesce((auth.jwt()->>'is_anonymous')::boolean, false)
             and exists (select 1 from profiles vp where vp.id = auth.uid() and vp.deleted_at is null) as signed_in,
           (select p.matches_visibility from profiles p where p.id = p_user) as vis
  )
  select d.id,
         d.ended_at,
         case when s.shown then op.id end,
         case when s.shown then op.display_name
              when op.deleted_at is not null then 'Deleted player'
              else 'Private player' end,
         case when d.host_id = p_user then d.host_seeker  else d.guest_seeker  end,
         case when d.host_id = p_user then d.host_terrain else d.guest_terrain end,
         case when s.shown then case when d.host_id = p_user then d.guest_seeker  else d.host_seeker  end end,
         case when s.shown then case when d.host_id = p_user then d.guest_terrain else d.host_terrain end end,
         d.winner_id = p_user,
         case when d.winner_id = p_user then d.winner_score else d.loser_score end,
         case when d.winner_id = p_user then d.loser_score else d.winner_score end,
         case when l.is_public or is_league_member(l.id) then t.id end,
         case when l.is_public or is_league_member(l.id)
              then coalesce(nullif(btrim(t.payload->>'name'), ''), l.name || ' ' || t.month) end
    from duels d
    cross join v
    join profiles op on op.id = case when d.host_id = p_user then d.guest_id else d.host_id end
    cross join lateral (
      select coalesce(v.viewer in (d.host_id, d.guest_id), false)
             or op.matches_visibility = 'public'
             or (op.matches_visibility = 'players' and v.signed_in) as shown
    ) s
    left join tournaments t on t.id = d.tournament_id
    left join leagues l on l.id = t.league_id
   where d.status = 'done'
     and p_user in (d.host_id, d.guest_id)
     and (v.viewer = p_user
          or v.viewer = d.host_id or v.viewer = d.guest_id
          or v.vis = 'public'
          or (v.vis = 'players' and v.signed_in))
   order by d.ended_at desc;
$$;
revoke all on function public.player_matches(uuid) from public;
grant execute on function public.player_matches(uuid) to anon, authenticated;

-- meta_duels: every finished match, for the Meta, with no player ids. The
-- date is rounded down to the day. A deck id is given only for a public deck
-- of a player whose matches are public, so a private history cannot be
-- traced through a deck.
create or replace function public.meta_duels(p_since timestamptz default null)
returns table (id uuid, played_at timestamptz,
               winner_seeker text, loser_seeker text,
               winner_terrain text, loser_terrain text,
               winner_deck_id uuid, loser_deck_id uuid)
language sql stable security definer set search_path = public as $$
  select d.id,
         date_trunc('day', d.ended_at),
         case when d.winner_id = d.host_id then d.host_seeker  else d.guest_seeker  end,
         case when d.winner_id = d.host_id then d.guest_seeker  else d.host_seeker  end,
         case when d.winner_id = d.host_id then d.host_terrain else d.guest_terrain end,
         case when d.winner_id = d.host_id then d.guest_terrain else d.host_terrain end,
         case when wk.is_public and wp.matches_visibility = 'public' then wk.id end,
         case when lk.is_public and lp.matches_visibility = 'public' then lk.id end
    from duels d
    join profiles wp on wp.id = d.winner_id
    join profiles lp on lp.id = d.loser_id
    left join decks wk on wk.id = case when d.winner_id = d.host_id then d.host_deck_id else d.guest_deck_id end
    left join decks lk on lk.id = case when d.winner_id = d.host_id then d.guest_deck_id else d.host_deck_id end
   where d.status = 'done'
     and (p_since is null or d.ended_at >= p_since)
   order by d.ended_at desc;
$$;
revoke all on function public.meta_duels(timestamptz) from public;
grant execute on function public.meta_duels(timestamptz) to anon, authenticated;

-- 7. Realtime: private channels 'duel:<id>' -------------------------------------
-- Only the two players of a match may join its channel, send on it (tracker
-- taps, presence) and receive from it. Skipped with a warning where the
-- project has no realtime.messages table; the check query then shows it.
do $outer$
begin
  if to_regclass('realtime.messages') is null then
    raise warning 'realtime.messages does not exist: the duel channel policies were not created.';
    return;
  end if;
  begin
    execute 'drop policy if exists "duel players receive" on realtime.messages';
    execute $p$
      create policy "duel players receive" on realtime.messages
        for select to authenticated
        using (
          realtime.topic() like 'duel:%'
          and exists (select 1 from public.duels d
                      where d.id::text = split_part(realtime.topic(), ':', 2)
                        and auth.uid() in (d.host_id, d.guest_id))
        )$p$;
    execute 'drop policy if exists "duel players send" on realtime.messages';
    execute $p$
      create policy "duel players send" on realtime.messages
        for insert to authenticated
        with check (
          realtime.topic() like 'duel:%'
          and exists (select 1 from public.duels d
                      where d.id::text = split_part(realtime.topic(), ':', 2)
                        and auth.uid() in (d.host_id, d.guest_id))
        )$p$;
  exception when others then
    raise warning 'The duel channel policies were not created (%).', sqlerrm;
  end;
end $outer$;

-- Each change of status, claim or guest is pushed to the match channel as a
-- 'duel_status' broadcast, so the other phone hears it at once. A Realtime
-- failure never blocks the write.
create or replace function public.duel_notify()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status
     or new.claim_by is distinct from old.claim_by
     or new.claim_winner is distinct from old.claim_winner
     or new.guest_id is distinct from old.guest_id then
    begin
      perform realtime.send(
        jsonb_build_object('status', new.status, 'claim_by', new.claim_by,
                           'claim_winner', new.claim_winner, 'guest_id', new.guest_id),
        'duel_status', 'duel:' || new.id::text, true);
    exception when others then
      null;
    end;
  end if;
  return null;
end $$;
revoke all on function public.duel_notify() from public, anon, authenticated;
drop trigger if exists duel_notify on public.duels;
create trigger duel_notify after update on public.duels
  for each row execute function public.duel_notify();

-- 8. The sweep every 10 minutes through pg_cron, like sl-purge-old-rows.
-- Without pg_cron duel_open() and duel_join() still sweep. Re-running
-- replaces the job.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      perform cron.unschedule(j.jobid) from cron.job j where j.jobname = 'sl-duel-sweep';
      perform cron.schedule('sl-duel-sweep', '*/10 * * * *', 'select public.duel_sweep()');
    exception when others then
      raise notice 'Could not schedule sl-duel-sweep (%).', sqlerrm;
    end;
  end if;
end $$;

-- 9. Free battles: no new rows ------------------------------------------------
-- The page is gone. Old rows stay, readable and deletable by their owner
-- only ("fb own read", "fb own delete"), shown as "logged by hand".
drop policy if exists "fb own write" on public.free_battles;

-- 10. erase_user_data(): same as 2026-11-01, plus the matches ---------------
-- The account's open matches are cancelled and its wrong-PIN rows deleted.
-- Finished matches stay: the opponent keeps them, against "Deleted player".
-- The deleted account's own list becomes private.
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
  delete from duel_join_attempts where user_id = p_user;

  update duels
     set status = 'cancelled', pin = null, ended_at = coalesce(ended_at, now()), updated_at = now()
   where status in ('waiting','live','ending') and (host_id = p_user or guest_id = p_user);

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
         matches_visibility = 'private',
         deleted_at = coalesce(deleted_at, now())
   where id = p_user;
end $$;
revoke all on function erase_user_data(uuid) from public, anon, authenticated;

-- ============================================================
--  PLAY NETWORK TOURNAMENTS (2026-11-11)
-- ============================================================
-- Run as migration-2026-11-11-tournaments.sql.
-- What changes:
--   * A community organizer runs a Play Network event listing as a
--     tournament (groups, then a finals bracket). The tournaments row gains
--     pn_event_id (one tournament per listing), organizer_id (who linked the
--     listing), status ('draft', 'running', 'closed'; null for the old
--     community tournaments), mode (clash or demo) and rev. Its payload is
--     version 3: the v2 shape plus entrants that may have no account
--     ('pn:<public id>' or 'h:<8 characters>' keys), drops and results with
--     a source (org, duel, drop, bye).
--   * Nobody writes these rows from the site (trigger guard_tournament):
--     t_create, t_entrant, t_start, t_unstart, t_result, t_fill, t_close,
--     t_reopen, t_discard and t_take_over lock the row, check rev and bump
--     it. t_live_duels and t_mine read. New tournaments come only from
--     t_create (the insert policy goes); old tournaments are still finished
--     and discarded as before.
--   * The edge function play-network-event imports the registered players
--     (nickname and malediction.gg profile id only): t_fetch_allow, as the
--     caller, applies the pn_fetch_log brakes; t_import (service role only)
--     merges them, in draft only. A name removed on request is never
--     copied again (tournament_marks, not readable from the site).
--   * profiles.mg_public_id: the id read from the malediction.gg profile
--     link, unique among live accounts. It links an account to its
--     registrations, also when the link is saved, changed or removed later
--     (trigger t_profile_link, draft and running tournaments only; after
--     the start a new link waits for the organizer to confirm it).
--   * Tracked matches: duel_join tags the match with the two players'
--     tournament game (same mode, no other tracked match live for it), and
--     a trigger records the result when the match is done by any path
--     (concession, confirmation, 48-hour auto-save), only while the game has
--     no result: an organizer's result is never overwritten. duel_get labels
--     the game. meta_duels gains in_tournament; player_matches names the
--     tournament after its event and shows it to the two players.
--   * Who sees a tournament: as before, plus its organizer (while still an
--     organizer of the community) and its players.
--   * erase_user_data(): the account stops organizing its tournaments and
--     is unlinked from every tournament it plays in, closed ones included.
--   * sync_tournament() is no longer callable from the site.

-- 1. tournaments: the columns of a Play Network tournament --------------------
-- status null is an old (v1/v2) community tournament, written from the page
-- as before. 'draft', 'running' and 'closed' are Play Network tournaments
-- (payload v 3): nobody writes them directly, every change goes through the
-- t_* functions below, which lock the row, check rev and bump it.
-- organizer_id is who linked the listing (pn_events.created_by); it becomes
-- null when that account is deleted, and the community's creator or an
-- organizer can then take over (t_take_over).
alter table public.tournaments
  add column if not exists pn_event_id  uuid references public.pn_events(id) on delete set null,
  add column if not exists organizer_id uuid references public.profiles(id) on delete set null,
  add column if not exists status       text,
  add column if not exists mode         text,
  add column if not exists rev          integer not null default 0;
do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'tournaments_status_check' and conrelid = 'public.tournaments'::regclass) then
    alter table public.tournaments add constraint tournaments_status_check
      check (status is null or status in ('draft','running','closed'));
  end if;
  if not exists (select 1 from pg_constraint
                 where conname = 'tournaments_mode_check' and conrelid = 'public.tournaments'::regclass) then
    alter table public.tournaments add constraint tournaments_mode_check
      check (mode is null or mode in ('clash','demo'));
  end if;
  if not exists (select 1 from pg_constraint
                 where conname = 'tournaments_v3_shape' and conrelid = 'public.tournaments'::regclass) then
    alter table public.tournaments add constraint tournaments_v3_shape
      check (status is null or (payload->>'v' = '3' and mode is not null
                                and octet_length(payload::text) <= 262144));
  end if;
end $$;
-- One tournament per listing.
create unique index if not exists tournaments_pn_event_one on public.tournaments(pn_event_id)
  where pn_event_id is not null;
create index if not exists idx_tournaments_organizer on public.tournaments(organizer_id)
  where organizer_id is not null;
-- "Which tournaments is this account in": entrants @> [{"id": "<uuid>"}].
create index if not exists idx_tournaments_entrants on public.tournaments
  using gin ((payload->'entrants') jsonb_path_ops) where status is not null;

-- Marks on Play Network profile ids that must outlive an entrant, kept out of
-- the payload (which anyone who sees the tournament can read): 'forget' (the
-- organizer removed the player's name on request: a refresh never adds them
-- again) and 'lock' (the organizer unlinked a wrong account and the player
-- then left the official list: if they register again, they come back
-- locked). Only a one-way hash of the tournament id and the profile id is
-- kept (t_pid_hash). No policy and no grant: only the t_* functions read and
-- write it. Deleted with the tournament.
create table if not exists public.tournament_marks (
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  pid_hash      text not null,
  kind          text not null check (kind in ('forget','lock')),
  created_at    timestamptz not null default now(),
  primary key (tournament_id, pid_hash, kind)
);
alter table public.tournament_marks enable row level security;
revoke all on public.tournament_marks from public, anon, authenticated;

-- 2. profiles.mg_public_id: the id in the malediction.gg profile link ----------
-- https://malediction.gg/app/profile/<id>/ (www., http, a missing slash and a
-- query or fragment are accepted). Public ids are case-sensitive, so case is
-- never folded. One account per id (first come); the organizer can unlink a
-- wrong match, and the real owner writes to us from Feedback.
-- Callable by everyone on purpose: the generated column runs it on every
-- profile save, as the caller.
create or replace function public.mg_public_id(p_url text)
returns text language sql immutable set search_path = public as $$
  select (regexp_match(btrim(coalesce(p_url, '')),
    '^https?://(?:www\.)?malediction\.gg/app/profile/([A-Za-z0-9]{6,32})/?(?:[?#].*)?$', 'i'))[1];
$$;
grant execute on function public.mg_public_id(text) to anon, authenticated;

alter table public.profiles add column if not exists mg_public_id text
  generated always as (public.mg_public_id(malediction_url)) stored;

-- Two live accounts with the same link would stop the unique index below.
do $$
declare
  v_dup text;
begin
  if to_regclass('public.profiles_mg_public_id_one') is null then
    select string_agg(x.mg_public_id || ' (' || x.n || ' accounts)', ', ') into v_dup
      from (select p.mg_public_id, count(*) as n from public.profiles p
             where p.mg_public_id is not null and p.deleted_at is null
             group by p.mg_public_id having count(*) > 1) x;
    if v_dup is not null then
      raise exception 'These malediction.gg profile links are on more than one account: %. Clear the extra links (profiles.malediction_url), then run this again.', v_dup;
    end if;
  end if;
end $$;
create unique index if not exists profiles_mg_public_id_one on public.profiles(mg_public_id)
  where mg_public_id is not null and deleted_at is null;

-- 3. Helpers (not callable over the API) ----------------------------------------
-- An entrant key: a profile uuid (an account is linked), 'pn:<public id>' (a
-- Play Network registrant with no account linked) or 'h:<8 characters>' (a
-- player the organizer added by hand, with no profile link).
create or replace function public.t_key_ok(p text)
returns boolean language sql immutable security definer set search_path = public as $$
  select coalesce(p ~ '^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|pn:[A-Za-z0-9]{6,32}|h:[A-Za-z0-9]{8})$', false);
$$;

-- The key is an account (a profile uuid).
create or replace function public.t_acct(p text)
returns boolean language sql immutable security definer set search_path = public as $$
  select coalesce(p ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', false);
$$;

-- A refusal: {ok:false, reason, message}.
create or replace function public.t_no(p_reason text, p_message text)
returns jsonb language sql immutable security definer set search_path = public as $$
  select jsonb_build_object('ok', false, 'reason', p_reason, 'message', p_message);
$$;

-- A player name: control characters stripped, trimmed, at most 40
-- characters, null when empty.
create or replace function public.t_clean_name(p text)
returns text language sql immutable security definer set search_path = public as $$
  select nullif(btrim(left(btrim(regexp_replace(coalesce(p, ''), '[[:cntrl:]]', '', 'g')), 40)), '');
$$;

-- The one-way hash kept in tournament_marks for a profile id.
create or replace function public.t_pid_hash(p_tid uuid, p_pid text)
returns text language sql stable security definer set search_path = public as $$
  select encode(sha256(convert_to(p_tid::text || ':' || coalesce(p_pid, ''), 'UTF8')), 'hex');
$$;

-- p_user is the creator of p_league, or one of its organizers who has not
-- been dropped (is_league_admin() for any account, not only the caller).
create or replace function public.t_user_admin(p_league uuid, p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select p_user is not null and (
    exists (select 1 from leagues l where l.id = p_league and l.owner_id = p_user)
    or exists (select 1 from memberships m
                where m.league_id = p_league and m.user_id = p_user
                  and m.is_admin and m.dropped_at is null));
$$;

-- A new 'h:' key that is not in the payload yet.
create or replace function public.t_rand_key(p jsonb)
returns text language plpgsql volatile security definer set search_path = public as $$
declare
  v_key text;
begin
  loop
    v_key := 'h:' || substr(md5(gen_random_uuid()::text), 1, 8);
    exit when not coalesce(p->'entrants' @> jsonb_build_array(jsonb_build_object('id', v_key)), false);
  end loop;
  return v_key;
end $$;

-- The name of finals round p_r of p_len rounds, as tvRoundName() on the page.
create or replace function public.t_round_name(p_len int, p_r int)
returns text language sql immutable security definer set search_path = public as $$
  select case p_len - 1 - p_r
           when 0 then 'Final' when 1 then 'Semifinals' when 2 then 'Top 8'
           when 3 then 'Round of 16' when 4 then 'Round of 32'
           else 'Round ' || (p_r + 1) end;
$$;

-- "Round 2 · Table 3", "Group stage", "Semifinals · Table 1" for a game ref:
-- 'g:<index in gm>' or 'b:<round>:<match>'. Null when the ref is not there.
create or replace function public.t_game_label(p jsonb, p_ref text)
returns text language plpgsql immutable security definer set search_path = public as $$
declare
  v_tb int := case when p->>'tables' ~ '^[0-9]{1,3}$' then (p->>'tables')::int else 0 end;
  v_m  jsonb;
  v_mm text[];
  v_l  int;
begin
  if p_ref ~ '^g:[0-9]{1,4}$' then
    v_m := p->'gm'->(substr(p_ref, 3)::int);
    if v_m is null then
      return null;
    end if;
    return case when v_m->>'r' ~ '^[0-9]{1,3}$' then 'Round ' || (v_m->>'r') else 'Group stage' end
        || case when v_tb > 0 and v_m->>'tb' ~ '^[0-9]{1,3}$' then ' · Table ' || (v_m->>'tb') else '' end;
  end if;
  v_mm := regexp_match(coalesce(p_ref, ''), '^b:([0-9]{1,2}):([0-9]{1,4})$');
  if v_mm is null or jsonb_typeof(p->'bracket') is distinct from 'array' then
    return null;
  end if;
  v_l := jsonb_array_length(p->'bracket');
  if v_mm[1]::int >= v_l or p->'bracket'->(v_mm[1]::int)->(v_mm[2]::int) is null then
    return null;
  end if;
  return t_round_name(v_l, v_mm[1]::int)
      || case when v_tb > 0 then ' · Table ' || ((v_mm[2]::int) % v_tb + 1) else '' end;
end $$;

-- Every place a key sits in the payload, and only those: entrants[].id,
-- groups[][], gm[].a/b/w, bracket[][].a.id/b.id and champion.
create or replace function public.t_rekey(p jsonb, p_old text, p_new text)
returns jsonb language sql immutable security definer set search_path = public as $$
  select case when p is null or p_old is null or p_new is null or p_old = p_new then p else
    p
    || jsonb_build_object('entrants', coalesce((
         select jsonb_agg(case when q.x->>'id' = p_old then q.x || jsonb_build_object('id', p_new) else q.x end
                          order by q.o)
           from jsonb_array_elements(coalesce(p->'entrants', '[]'::jsonb)) with ordinality q(x, o)), '[]'::jsonb))
    || jsonb_build_object('groups', coalesce((
         select jsonb_agg(coalesce((
                  select jsonb_agg(case when y.k #>> '{}' = p_old then to_jsonb(p_new) else y.k end order by y.o)
                    from jsonb_array_elements(q.x) with ordinality y(k, o)), '[]'::jsonb) order by q.o)
           from jsonb_array_elements(coalesce(p->'groups', '[]'::jsonb)) with ordinality q(x, o)), '[]'::jsonb))
    || jsonb_build_object('gm', coalesce((
         select jsonb_agg(q.x || jsonb_strip_nulls(jsonb_build_object(
                  'a', case when q.x->>'a' = p_old then p_new end,
                  'b', case when q.x->>'b' = p_old then p_new end,
                  'w', case when q.x->>'w' = p_old then p_new end)) order by q.o)
           from jsonb_array_elements(coalesce(p->'gm', '[]'::jsonb)) with ordinality q(x, o)), '[]'::jsonb))
    || jsonb_build_object('bracket', coalesce((
         select jsonb_agg(coalesce((
                  select jsonb_agg(y.m || jsonb_strip_nulls(jsonb_build_object(
                           'a', case when y.m #>> '{a,id}' = p_old then jsonb_build_object('id', p_new) end,
                           'b', case when y.m #>> '{b,id}' = p_old then jsonb_build_object('id', p_new) end))
                           order by y.o)
                    from jsonb_array_elements(q.x) with ordinality y(m, o)), '[]'::jsonb) order by q.o)
           from jsonb_array_elements(coalesce(p->'bracket', '[]'::jsonb)) with ordinality q(x, o)), '[]'::jsonb))
    || case when p->>'champion' = p_old then jsonb_build_object('champion', p_new) else '{}'::jsonb end
  end;
$$;

-- A finals match with no result (winner null, no source, no tracked match).
create or replace function public.t_clear_win(m jsonb)
returns jsonb language sql immutable security definer set search_path = public as $$
  select (m - 'src' - 'du' - 'dx' - 'at' - 'auto') || '{"winner":null}'::jsonb;
$$;

-- Winners move on, as propagate() on the page, in one pass from round 0 to
-- the final. Then, for a match with no winner:
--   * both players there and exactly one of them dropped: the other wins
--     (src 'drop', a forfeit);
--   * one player there and the other seat can never be filled (round 0, or
--     the feeding match of a later round has nobody in its half): the player
--     there goes through (src 'bye').
-- A match nobody can come out of (both players dropped, or the only player
-- who can be there is dropped) leaves its seat in the next round empty, so
-- the other player there goes through.
-- A match whose players changed loses its result.
create or replace function public.t_propagate(p jsonb)
returns jsonb language plpgsql immutable security definer set search_path = public as $$
declare
  v_b     jsonb := coalesce(p->'bracket', '[]'::jsonb);
  v_n     int;
  v_drops text[];
  v_r     int;
  v_k     int;
  v_m     jsonb;
  v_f1    jsonb;
  v_f2    jsonb;
  v_sa    jsonb;
  v_sb    jsonb;
  v_ia    text;
  v_ib    text;
  v_da    boolean;
  v_db    boolean;
  v_dead  boolean;
  v_prev  boolean[] := '{}';
  v_cur   boolean[];
begin
  if jsonb_typeof(v_b) is distinct from 'array' then
    return p;
  end if;
  v_n := jsonb_array_length(v_b);
  if v_n = 0 then
    return p;
  end if;
  select coalesce(array_agg(q.x->>'id'), '{}') into v_drops
    from jsonb_array_elements(coalesce(p->'entrants', '[]'::jsonb)) q(x)
   where q.x->>'st' = 'drop';
  for v_r in 0 .. v_n - 1 loop
    v_cur := '{}';
    for v_k in 0 .. jsonb_array_length(v_b->v_r) - 1 loop
      v_m := v_b->v_r->v_k;
      if v_r > 0 then
        v_f1 := v_b->(v_r - 1)->(2 * v_k);
        v_f2 := v_b->(v_r - 1)->(2 * v_k + 1);
        v_sa := case v_f1->>'winner' when 'a' then v_f1->'a' when 'b' then v_f1->'b' end;
        v_sb := case v_f2->>'winner' when 'a' then v_f2->'a' when 'b' then v_f2->'b' end;
        if v_sa is null or jsonb_typeof(v_sa) <> 'object' then
          v_sa := 'null'::jsonb;
        end if;
        if v_sb is null or jsonb_typeof(v_sb) <> 'object' then
          v_sb := 'null'::jsonb;
        end if;
        if (v_m #>> '{a,id}') is distinct from (v_sa->>'id')
           or (v_m #>> '{b,id}') is distinct from (v_sb->>'id') then
          v_m := t_clear_win(v_m);
        end if;
        v_m := v_m || jsonb_build_object('a', v_sa, 'b', v_sb);
      end if;
      v_ia := v_m #>> '{a,id}';
      v_ib := v_m #>> '{b,id}';
      if v_m->>'winner' is not null
         and not ((v_m->>'winner' = 'a' and v_ia is not null) or (v_m->>'winner' = 'b' and v_ib is not null)) then
        v_m := t_clear_win(v_m);
      end if;
      if v_r = 0 then
        v_dead := v_ia is null and v_ib is null;
      else
        v_dead := coalesce(v_prev[2 * v_k + 1], false) and coalesce(v_prev[2 * v_k + 2], false);
      end if;
      if v_m->>'winner' is null then
        if v_ia is not null and v_ib is not null then
          v_da := v_ia = any(v_drops);
          v_db := v_ib = any(v_drops);
          if v_da and not v_db then
            v_m := v_m || '{"winner":"b","src":"drop"}'::jsonb;
          elsif v_db and not v_da then
            v_m := v_m || '{"winner":"a","src":"drop"}'::jsonb;
          elsif v_da and v_db then
            -- both dropped: nobody comes out of this match
            v_dead := true;
          end if;
        elsif v_ia is not null or v_ib is not null then
          if v_r = 0
             or (v_ia is null and coalesce(v_prev[2 * v_k + 1], false))
             or (v_ib is null and coalesce(v_prev[2 * v_k + 2], false)) then
            if coalesce(v_ia, v_ib) = any(v_drops) then
              -- the only player who can be here is dropped: nobody goes through
              v_dead := true;
            else
              v_m := v_m || jsonb_build_object('winner', case when v_ia is not null then 'a' else 'b' end, 'src', 'bye');
            end if;
          end if;
        end if;
      end if;
      v_cur := v_cur || v_dead;
      v_b := jsonb_set(v_b, array[v_r::text, v_k::text], v_m);
    end loop;
    v_prev := v_cur;
  end loop;
  return jsonb_set(p, '{bracket}', v_b);
end $$;

-- Group games of dropped players: an undecided game with exactly one dropped
-- player is won by the other (src 'drop'); a forfeit whose loser is no
-- longer dropped (brought back) is undecided again. A forfeit stays when its
-- winner drops too, and a game between two dropped players with no result
-- stays without one (t_gm_done counts it as decided; it never counts in the
-- standings or the Meta). Results entered by the organizer or recorded from
-- a tracked match are never touched.
create or replace function public.t_forfeits(p jsonb)
returns jsonb language plpgsql immutable security definer set search_path = public as $$
declare
  v_drops text[];
  v_gm    jsonb := '[]'::jsonb;
  v_m     jsonb;
  v_da    boolean;
  v_db    boolean;
  v_win   text;
  v_lose  text;
begin
  select coalesce(array_agg(q.x->>'id'), '{}') into v_drops
    from jsonb_array_elements(coalesce(p->'entrants', '[]'::jsonb)) q(x)
   where q.x->>'st' = 'drop';
  for v_m in select q.x from jsonb_array_elements(coalesce(p->'gm', '[]'::jsonb)) with ordinality q(x, o) order by q.o loop
    v_da := coalesce(v_m->>'a' = any(v_drops), false);
    v_db := coalesce(v_m->>'b' = any(v_drops), false);
    v_win := case when v_da and not v_db then v_m->>'b' when v_db and not v_da then v_m->>'a' end;
    if v_m->>'src' = 'drop' then
      v_lose := case when v_m->>'w' = v_m->>'a' then v_m->>'b' when v_m->>'w' = v_m->>'b' then v_m->>'a' end;
      if v_lose is null or not (v_lose = any(v_drops)) then
        v_m := (v_m - 'src' - 'at' - 'auto' - 'dx') || '{"w":null}'::jsonb;
      end if;
    end if;
    if v_m->>'w' is null and v_win is not null then
      v_m := v_m || jsonb_build_object('w', v_win, 'src', 'drop');
    end if;
    v_gm := v_gm || jsonb_build_array(v_m);
  end loop;
  return jsonb_set(p, '{gm}', v_gm);
end $$;

-- Every group game has a result, or is between two dropped players (it will
-- never be played).
create or replace function public.t_gm_done(p jsonb)
returns boolean language sql immutable security definer set search_path = public as $$
  select coalesce(jsonb_array_length(p->'gm') > 0, false)
     and not exists (
       select 1 from jsonb_array_elements(p->'gm') q(x)
        where q.x->>'w' is null
          and not (p->'entrants' @> jsonb_build_array(jsonb_build_object('id', q.x->>'a', 'st', 'drop'))
                   and p->'entrants' @> jsonb_build_array(jsonb_build_object('id', q.x->>'b', 'st', 'drop'))));
$$;

-- Nobody is placed in the finals yet.
create or replace function public.t_r0_empty(p jsonb)
returns boolean language sql immutable security definer set search_path = public as $$
  select not exists (select 1 from jsonb_array_elements(coalesce(p #> '{bracket,0}', '[]'::jsonb)) q(x)
                      where q.x #>> '{a,id}' is not null or q.x #>> '{b,id}' is not null);
$$;

-- A result entered by the organizer or recorded from a tracked match.
create or replace function public.t_has_results(p jsonb)
returns boolean language sql immutable security definer set search_path = public as $$
  select exists (select 1 from jsonb_array_elements(coalesce(p->'gm', '[]'::jsonb)) q(x)
                  where q.x->>'src' in ('org','duel'))
      or exists (select 1 from jsonb_array_elements(coalesce(p->'bracket', '[]'::jsonb)) q(x),
                               jsonb_array_elements(q.x) y(m)
                  where y.m->>'src' in ('org','duel'));
$$;

-- The bracket with its shape kept and nobody in it.
create or replace function public.t_clear_bracket(p jsonb)
returns jsonb language sql immutable security definer set search_path = public as $$
  select jsonb_set(p, '{bracket}', coalesce((
    select jsonb_agg(coalesce((
             select jsonb_agg(jsonb_build_object('a', null, 'b', null, 'winner', null) order by y.o)
               from jsonb_array_elements(q.x) with ordinality y(m, o)), '[]'::jsonb) order by q.o)
      from jsonb_array_elements(coalesce(p->'bracket', '[]'::jsonb)) with ordinality q(x, o)), '[]'::jsonb));
$$;

-- The keys in the groups.
create or replace function public.t_grouped(p jsonb)
returns text[] language sql immutable security definer set search_path = public as $$
  select coalesce(array_agg(y.k #>> '{}'), '{}')
    from jsonb_array_elements(coalesce(p->'groups', '[]'::jsonb)) q(x),
         jsonb_array_elements(q.x) y(k);
$$;

-- Active entrants: not dropped, and in the groups.
create or replace function public.t_active(p jsonb)
returns text[] language sql immutable security definer set search_path = public as $$
  select coalesce(array_agg(q.x->>'id'), '{}')
    from jsonb_array_elements(coalesce(p->'entrants', '[]'::jsonb)) q(x)
   where q.x->>'st' = 'in' and (q.x->>'id') = any(t_grouped(p));
$$;

-- p_round0, the finals draw made on the organizer's page (tvQualifiers):
-- one [keyA|null, keyB|null] per round-0 match; the keys are active entrants,
-- each at most once.
create or replace function public.t_round0_ok(p jsonb, p_round0 jsonb)
returns boolean language plpgsql immutable security definer set search_path = public as $$
declare
  v_keys text[];
begin
  if p_round0 is null or jsonb_typeof(p_round0) is distinct from 'array' then
    return false;
  end if;
  if jsonb_array_length(p_round0) = 0
     or jsonb_array_length(p_round0) <> jsonb_array_length(coalesce(p #> '{bracket,0}', '[]'::jsonb)) then
    return false;
  end if;
  if exists (select 1 from jsonb_array_elements(p_round0) q(x) where jsonb_typeof(q.x) <> 'array') then
    return false;
  end if;
  if exists (select 1 from jsonb_array_elements(p_round0) q(x) where jsonb_array_length(q.x) <> 2) then
    return false;
  end if;
  if exists (select 1 from jsonb_array_elements(p_round0) q(x), jsonb_array_elements(q.x) y(k)
              where jsonb_typeof(y.k) not in ('string','null')) then
    return false;
  end if;
  select array_agg(y.k #>> '{}') into v_keys
    from jsonb_array_elements(p_round0) q(x), jsonb_array_elements(q.x) y(k)
   where jsonb_typeof(y.k) = 'string';
  if v_keys is null or cardinality(v_keys) <> (select count(distinct z) from unnest(v_keys) z) then
    return false;
  end if;
  return v_keys <@ t_active(p);
end $$;

-- The finals drawn: round 0 placed from p_round0. A match that holds the
-- same two players as before keeps its result and its tracked match; the
-- others start with none. Then t_propagate: a later match keeps its result
-- while the same two players still meet there, and byes and forfeits are
-- given. p_round0 must have passed t_round0_ok.
create or replace function public.t_place_round0(p jsonb, p_round0 jsonb)
returns jsonb language sql immutable security definer set search_path = public as $$
  select t_propagate(jsonb_set(p, '{bracket,0}', (
    select jsonb_agg(case when jsonb_typeof(n.old) = 'object'
                               and (n.old #>> '{a,id}') is not distinct from n.a
                               and (n.old #>> '{b,id}') is not distinct from n.b
                          then n.old
                          else jsonb_build_object('a', case when n.a is not null then jsonb_build_object('id', n.a) end,
                                                  'b', case when n.b is not null then jsonb_build_object('id', n.b) end,
                                                  'winner', null) end
                     order by n.o)
      from (select q.o,
                   case when jsonb_typeof(q.x->0) = 'string' then q.x->>0 end as a,
                   case when jsonb_typeof(q.x->1) = 'string' then q.x->>1 end as b,
                   p #> array['bracket', '0', (q.o - 1)::text] as old
              from jsonb_array_elements(p_round0) with ordinality q(x, o)) n)));
$$;

-- Tracked matches attached again: a game with no tracked match (du) whose
-- two players are those of a finished match tagged with this tournament and
-- this game (t_ref), neither dropped, gets it back, as t_record_duel() would
-- have done: an undecided game takes the match's winner (src 'duel'), a
-- decided one keeps its result and gets du (and dx when the winners
-- differ). This covers a draw made again, a bracket emptied and filled, and
-- a match that ended while the game was out of reach (the tournament
-- closed, a player keyed differently). Finals winners move on, so the next
-- round is looked at again (at most 12 passes).
create or replace function public.t_reattach(p jsonb, p_tid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_d     record;
  v_m     jsonb;
  v_i     int;
  v_mm    text[];
  v_r     int;
  v_k     int;
  v_a     text;
  v_b     text;
  v_dec   text;
  v_drops text[];
  v_more  boolean := true;
  v_pass  int := 0;
begin
  if p is null or p_tid is null then
    return p;
  end if;
  select coalesce(array_agg(q.x->>'id'), '{}') into v_drops
    from jsonb_array_elements(coalesce(p->'entrants', '[]'::jsonb)) q(x)
   where q.x->>'st' = 'drop';
  while v_more and v_pass < 12 loop
    v_more := false;
    v_pass := v_pass + 1;
    for v_d in
      select d.id, d.t_ref, d.host_id::text as h, d.guest_id::text as g, d.winner_id::text as w, d.ended_at
        from duels d
       where d.tournament_id = p_tid and d.status = 'done' and d.t_ref is not null
         and d.guest_id is not null and d.winner_id is not null
       order by d.ended_at desc, d.id
    loop
      if v_d.h = any(v_drops) or v_d.g = any(v_drops) then
        continue;
      end if;
      if v_d.t_ref ~ '^g:[0-9]{1,4}$' then
        v_i := substr(v_d.t_ref, 3)::int;
        v_m := p->'gm'->v_i;
        if v_m is null or v_m->>'du' is not null then
          continue;
        end if;
        if not coalesce((v_m->>'a' = v_d.h and v_m->>'b' = v_d.g) or (v_m->>'a' = v_d.g and v_m->>'b' = v_d.h), false) then
          continue;
        end if;
        if v_m->>'w' is null then
          v_m := (v_m - 'dx') || jsonb_build_object('w', v_d.w, 'src', 'duel', 'du', v_d.id, 'at', v_d.ended_at);
        else
          v_m := v_m || jsonb_build_object('du', v_d.id)
                     || case when v_m->>'w' <> v_d.w then '{"dx":true}'::jsonb else '{}'::jsonb end;
        end if;
        p := jsonb_set(p, array['gm', v_i::text], v_m);
      elsif v_d.t_ref ~ '^b:[0-9]{1,2}:[0-9]{1,4}$' then
        v_mm := regexp_match(v_d.t_ref, '^b:([0-9]{1,2}):([0-9]{1,4})$');
        v_r := v_mm[1]::int;
        v_k := v_mm[2]::int;
        v_m := p->'bracket'->v_r->v_k;
        if v_m is null or jsonb_typeof(v_m) <> 'object' or v_m->>'du' is not null then
          continue;
        end if;
        v_a := v_m #>> '{a,id}';
        v_b := v_m #>> '{b,id}';
        if not coalesce((v_a = v_d.h and v_b = v_d.g) or (v_a = v_d.g and v_b = v_d.h), false) then
          continue;
        end if;
        if v_m->>'winner' is null then
          v_m := (v_m - 'dx')
                 || jsonb_build_object('winner', case when v_a = v_d.w then 'a' else 'b' end,
                                       'src', 'duel', 'du', v_d.id, 'at', v_d.ended_at);
          p := t_propagate(jsonb_set(p, array['bracket', v_r::text, v_k::text], v_m));
          v_more := true;
        else
          v_dec := case v_m->>'winner' when 'a' then v_a when 'b' then v_b end;
          v_m := v_m || jsonb_build_object('du', v_d.id)
                     || case when v_dec is distinct from v_d.w then '{"dx":true}'::jsonb else '{}'::jsonb end;
          p := jsonb_set(p, array['bracket', v_r::text, v_k::text], v_m);
        end if;
      end if;
    end loop;
  end loop;
  return p;
end $$;

-- Accounts and registrants matched again: an entrant keyed by an account
-- whose profile link no longer gives its pid (changed, removed, or the
-- account deleted) goes back to 'pn:<pid>'. Then an entrant with a pid, no
-- lock and no account is matched to the account whose mg_public_id is that
-- pid, if that account is not in the list yet:
--   p_new '*'    any such entrant is linked (before the start);
--   p_new <key>  only that entrant is linked (the organizer's "Link the
--                account" after the start); the others are only marked;
--   p_new null   nobody is linked (after the start, from a profile save).
-- An entrant that could be linked but is not gets wait:true, so the
-- organizer sees that an account claims that registration: once the
-- tournament has started a new link is never made by itself, so nobody can
-- take an unlinked player's seat (and record its results) by pasting their
-- profile link. linked = entrants with an account.
create or replace function public.t_link_all(p jsonb, p_new text default '*', out r jsonb, out linked int)
language plpgsql volatile security definer set search_path = public as $$
declare
  v_e  jsonb;
  v_o  int;
  v_id uuid;
begin
  r := p;
  for v_e in select q.x from jsonb_array_elements(coalesce(p->'entrants', '[]'::jsonb)) q(x) loop
    if t_acct(v_e->>'id') and not exists (
         select 1 from profiles pr
          where pr.id = (v_e->>'id')::uuid and pr.deleted_at is null
            and v_e->>'pid' is not null and pr.mg_public_id = v_e->>'pid') then
      r := t_rekey(r, v_e->>'id',
                   case when coalesce(v_e->>'pid', '') ~ '^[A-Za-z0-9]{6,32}$' then 'pn:' || (v_e->>'pid')
                        else t_rand_key(r) end);
    end if;
  end loop;
  for v_e, v_o in select q.x, q.o - 1 from jsonb_array_elements(coalesce(r->'entrants', '[]'::jsonb)) with ordinality q(x, o) loop
    if t_acct(v_e->>'id') then
      continue;
    end if;
    v_id := null;
    if v_e->>'pid' is not null and (v_e->>'lock') is distinct from 'true' then
      select pr.id into v_id from profiles pr
       where pr.mg_public_id = v_e->>'pid' and pr.deleted_at is null
       limit 1;
      if v_id is not null and r->'entrants' @> jsonb_build_array(jsonb_build_object('id', v_id::text)) then
        v_id := null;
      end if;
    end if;
    if v_id is not null and (p_new = '*' or p_new = v_e->>'id') then
      r := jsonb_set(r, array['entrants', v_o::text], (r->'entrants'->v_o) - 'wait');
      r := t_rekey(r, v_e->>'id', v_id::text);
    elsif v_id is not null then
      if (v_e->>'wait') is distinct from 'true' then
        r := jsonb_set(r, array['entrants', v_o::text, 'wait'], 'true'::jsonb);
      end if;
    elsif v_e ? 'wait' then
      r := jsonb_set(r, array['entrants', v_o::text], (r->'entrants'->v_o) - 'wait');
    end if;
  end loop;
  select count(*) into linked
    from jsonb_array_elements(coalesce(r->'entrants', '[]'::jsonb)) q(x)
   where t_acct(q.x->>'id');
end $$;

-- The caller organizes this tournament and is still the creator or an
-- organizer of its community (a demoted or removed organizer loses it, and
-- the community can take it over: t_take_over), or is the site admin.
create or replace function public.t_is_org(t public.tournaments)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(auth.uid() is not null and auth.uid() = t.organizer_id
                  and t_user_admin(t.league_id, auth.uid()), false)
      or coalesce(is_site_admin(), false);
$$;

-- Locks the tournament row for the rest of the transaction and checks it:
-- a Play Network tournament, the caller organizes it, the community is not
-- archived (unless p_any_archived) and p_rev is its current rev. Null when
-- all is well (the caller then reads the locked row), otherwise the refusal.
create or replace function public.t_lock(p_tid uuid, p_rev int, p_any_archived boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_t tournaments%rowtype;
begin
  select * into v_t from tournaments x where x.id = p_tid for update;
  if not found or v_t.status is null then
    return t_no('not_allowed', 'This tournament was not found.');
  end if;
  if not t_is_org(v_t) then
    return t_no('not_allowed', 'Only the organizer of this tournament can change it.');
  end if;
  if not coalesce(p_any_archived, false)
     and exists (select 1 from leagues l where l.id = v_t.league_id and l.archived_at is not null) then
    return t_no('archived', 'This community is archived.');
  end if;
  if p_rev is distinct from v_t.rev then
    return t_no('stale', 'The tournament changed on another device. It has been reloaded; check it and try again.')
           || jsonb_build_object('rev', v_t.rev);
  end if;
  return null;
end $$;

revoke all on function public.t_key_ok(text)                   from public, anon, authenticated;
revoke all on function public.t_pid_hash(uuid, text)           from public, anon, authenticated;
revoke all on function public.t_user_admin(uuid, uuid)         from public, anon, authenticated;
revoke all on function public.t_acct(text)                     from public, anon, authenticated;
revoke all on function public.t_no(text, text)                 from public, anon, authenticated;
revoke all on function public.t_clean_name(text)               from public, anon, authenticated;
revoke all on function public.t_rand_key(jsonb)                from public, anon, authenticated;
revoke all on function public.t_round_name(int, int)           from public, anon, authenticated;
revoke all on function public.t_game_label(jsonb, text)        from public, anon, authenticated;
revoke all on function public.t_rekey(jsonb, text, text)       from public, anon, authenticated;
revoke all on function public.t_clear_win(jsonb)               from public, anon, authenticated;
revoke all on function public.t_propagate(jsonb)               from public, anon, authenticated;
revoke all on function public.t_forfeits(jsonb)                from public, anon, authenticated;
revoke all on function public.t_gm_done(jsonb)                 from public, anon, authenticated;
revoke all on function public.t_r0_empty(jsonb)                from public, anon, authenticated;
revoke all on function public.t_has_results(jsonb)             from public, anon, authenticated;
revoke all on function public.t_clear_bracket(jsonb)           from public, anon, authenticated;
revoke all on function public.t_grouped(jsonb)                 from public, anon, authenticated;
revoke all on function public.t_active(jsonb)                  from public, anon, authenticated;
revoke all on function public.t_round0_ok(jsonb, jsonb)        from public, anon, authenticated;
revoke all on function public.t_place_round0(jsonb, jsonb)     from public, anon, authenticated;
revoke all on function public.t_reattach(jsonb, uuid)          from public, anon, authenticated;
revoke all on function public.t_link_all(jsonb, text)          from public, anon, authenticated;
revoke all on function public.t_is_org(public.tournaments)     from public, anon, authenticated;
revoke all on function public.t_lock(uuid, int, boolean)       from public, anon, authenticated;

-- 4. Nobody writes a Play Network tournament from the site -------------------
-- Same pattern as guard_match_tournament: not security definer on purpose,
-- so current_user is the caller's role. Requests from the site cannot add a
-- tournament (they come from t_create), delete one of these, or touch one of
-- these or their columns; old community tournaments stay editable by their
-- organizers ("admins update tournaments"), so running ones can be finished.
create or replace function public.guard_tournament()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return coalesce(new, old);
  end if;
  if tg_op = 'INSERT' then
    raise exception 'New tournaments are made from a Play Network event' using errcode = '42501';
  elsif tg_op = 'DELETE' then
    if old.status is not null then
      raise exception 'Discard this tournament from its page' using errcode = '42501';
    end if;
    return old;
  end if;
  if old.status is not null or new.status is not null
     or new.pn_event_id is distinct from old.pn_event_id
     or new.organizer_id is distinct from old.organizer_id
     or new.mode is distinct from old.mode
     or new.rev is distinct from old.rev
     or new.payload->>'v' = '3' then
    raise exception 'This tournament is changed from its page' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists guard_tournament on public.tournaments;
create trigger guard_tournament before insert or update or delete on public.tournaments
  for each row execute function public.guard_tournament();

-- Who sees a tournament: as before (members, public communities), plus the
-- site admin, and the organizer (while still the creator or an organizer of
-- the community) and the players of a Play Network tournament (a registrant
-- need not belong to the community).
drop policy if exists "tournaments visible" on public.tournaments;
create policy "tournaments visible" on public.tournaments
  for select using (
    is_league_member(league_id)
    or league_is_public(league_id)
    or is_site_admin()
    or (status is not null
        and ((organizer_id = auth.uid() and is_league_admin(league_id))
             or payload->'entrants' @> jsonb_build_array(jsonb_build_object('id', auth.uid()::text))))
  );
-- New tournaments come only from t_create.
drop policy if exists "admins write tournaments" on public.tournaments;
-- "admins update tournaments" stays: old tournaments can still be finished.
-- Discarding: old tournaments as before; Play Network ones through t_discard.
drop policy if exists "admins delete tournaments" on public.tournaments;
create policy "admins delete tournaments" on public.tournaments
  for delete using (
    is_league_admin(league_id)
    and session_id is null
    and not exists (select 1 from matches m where m.tournament_id = tournaments.id)
    and status is null
  );

-- The old event sync is no longer used by the site.
revoke execute on function sync_tournament(uuid) from authenticated;

-- 5. The organizer's functions ------------------------------------------------
-- Signed-in callers only (duel_caller). Refusals answer
-- {ok:false, reason, message}: stale (with rev), not_allowed, archived,
-- status, bad_input, finals_drawn, has_results, duplicate, round0_needed.
-- Success answers {ok:true, rev}.

-- t_create: the listing's creator (or the site admin) runs a listing read
-- from the Play Network as a tournament, in draft, with no players yet (the
-- edge function imports them next). One tournament per listing.
create or replace function public.t_create(p_pn_event uuid, p_mode text default 'clash')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  v_e   pn_events%rowtype;
  v_id  uuid;
begin
  if p_mode is null or p_mode not in ('clash','demo') then
    return t_no('bad_input', 'A tournament plays Clash or Demo.');
  end if;
  select * into v_e from pn_events x where x.id = p_pn_event;
  if not found
     or ((v_e.created_by is distinct from v_uid or not coalesce(is_league_admin(v_e.league_id), false))
         and not coalesce(is_site_admin(), false)) then
    return t_no('not_allowed', 'Only the organizer who linked this event can run it as a tournament.');
  end if;
  if not v_e.fetch_ok then
    return t_no('bad_input', 'Refresh this event from the Play Network first.');
  end if;
  if exists (select 1 from leagues l where l.id = v_e.league_id and l.archived_at is not null) then
    return t_no('archived', 'This community is archived.');
  end if;
  select x.id into v_id from tournaments x where x.pn_event_id = v_e.id;
  if v_id is not null then
    return t_no('duplicate', 'This event already has a tournament.') || jsonb_build_object('id', v_id);
  end if;
  begin
    insert into tournaments (league_id, month, payload, created_by, pn_event_id, organizer_id, status, mode, rev)
    values (v_e.league_id,
            to_char(coalesce(v_e.starts_at, now()) at time zone 'UTC', 'YYYY-MM'),
            jsonb_build_object('v', 3,
                               'pn', jsonb_build_object('id', v_e.pn_id, 'url', v_e.url, 'title', v_e.title),
                               'entrants', '[]'::jsonb, 'groups', '[]'::jsonb, 'gm', '[]'::jsonb,
                               'tables', 0, 'bracket', '[]'::jsonb, 'finalized', false),
            v_uid, v_e.id, v_uid, 'draft', p_mode, 0)
    returning id into v_id;
  exception when unique_violation then
    select x.id into v_id from tournaments x where x.pn_event_id = v_e.id;
    return t_no('duplicate', 'This event already has a tournament.') || jsonb_build_object('id', v_id);
  end;
  return jsonb_build_object('ok', true, 'id', v_id, 'rev', 0);
end $$;

-- t_entrant: the organizer's changes to the list of players.
--   drop      any time before the close; after the start the player's
--             undecided group games, and a finals match against them, go to
--             the opponent (src 'drop')
--   undrop    until the finals are drawn; the forfeits are undone
--   add       draft only: a name of 1-40 characters and optionally a
--             malediction.gg profile link
--   remove    draft only, players added by hand only
--   unlink    the account goes, the key is 'pn:<pid>' again, and the player
--             is never matched to an account automatically (lock)
--   relink    the lock goes, and the player is matched again: before the
--             start like any registrant; after it this is how the organizer
--             links an account that added the profile link (wait)
--   forget    removal on request: the name becomes "Player <n>", the pid
--             goes, the key becomes 'h:...', lock, and the player moves to
--             the end of the list. A one-way hash of the pid is kept in
--             tournament_marks (not readable from the site) so a refresh
--             does not bring the name back. Allowed in any status, also in
--             an archived community.
create or replace function public.t_entrant(p_tid uuid, p_rev int, p_op text, p_key text default null,
                                            p_name text default null, p_link text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := duel_caller();
  v_no   jsonb;
  v_t    tournaments%rowtype;
  v_p    jsonb;
  v_e    jsonb;
  v_i    int;
  v_raw  text;
  v_pid  text;
  v_key  text;
  v_n    int;
  v_rev  int;
begin
  if p_op is null or p_op not in ('drop','undrop','add','remove','unlink','relink','forget') then
    return t_no('bad_input', 'This change is not known.');
  end if;
  v_no := t_lock(p_tid, p_rev, p_op = 'forget');
  if v_no is not null then
    return v_no;
  end if;
  select * into v_t from tournaments x where x.id = p_tid;
  v_p := v_t.payload;

  if p_op <> 'add' then
    select q.o - 1, q.x into v_i, v_e
      from jsonb_array_elements(coalesce(v_p->'entrants', '[]'::jsonb)) with ordinality q(x, o)
     where q.x->>'id' = p_key
     limit 1;
    if v_e is null then
      return t_no('bad_input', 'This player is not in the list.');
    end if;
  end if;
  if p_op in ('drop','undrop','unlink','relink') and v_t.status = 'closed' then
    return t_no('status', 'The tournament is closed. Reopen it first.');
  end if;
  if p_op in ('add','remove') and v_t.status <> 'draft' then
    return t_no('status', 'The tournament has started, so its list of players is fixed.');
  end if;

  if p_op = 'drop' then
    if v_e->>'st' = 'drop' then
      return jsonb_build_object('ok', true, 'rev', v_t.rev);
    end if;
    v_p := jsonb_set(v_p, array['entrants', v_i::text, 'st'], '"drop"'::jsonb);
    if v_t.status = 'running' then
      v_p := t_forfeits(v_p);
      if not t_r0_empty(v_p) then
        v_p := t_propagate(v_p);
      end if;
    end if;

  elsif p_op = 'undrop' then
    if v_e->>'st' is distinct from 'drop' then
      return jsonb_build_object('ok', true, 'rev', v_t.rev);
    end if;
    if v_t.status = 'running' then
      if not t_r0_empty(v_p) then
        return t_no('finals_drawn', 'The finals are drawn; this player stays dropped.');
      end if;
      if not (p_key = any(t_grouped(v_p))) then
        return t_no('status', 'This player was dropped before the start, so they are not in the draw.');
      end if;
    end if;
    v_p := jsonb_set(v_p, array['entrants', v_i::text, 'st'], '"in"'::jsonb);
    if v_t.status = 'running' then
      v_p := t_forfeits(v_p);
    end if;

  elsif p_op = 'add' then
    v_raw := btrim(regexp_replace(coalesce(p_name, ''), '[[:cntrl:]]', '', 'g'));
    if char_length(v_raw) not between 1 and 40 then
      return t_no('bad_input', 'A name has 1 to 40 characters.');
    end if;
    if jsonb_array_length(coalesce(v_p->'entrants', '[]'::jsonb)) >= 256 then
      return t_no('bad_input', 'A tournament has at most 256 players.');
    end if;
    if nullif(btrim(coalesce(p_link, '')), '') is not null then
      v_pid := mg_public_id(p_link);
      if v_pid is null then
        return t_no('bad_input', 'Paste the address of a malediction.gg profile, like https://malediction.gg/app/profile/AbC123xYz0/');
      end if;
      if coalesce(v_p->'entrants' @> jsonb_build_array(jsonb_build_object('pid', v_pid)), false)
         or coalesce(v_p->'entrants' @> jsonb_build_array(jsonb_build_object('id', 'pn:' || v_pid)), false) then
        return t_no('duplicate', 'This player is already in the list.');
      end if;
      v_key := 'pn:' || v_pid;
    else
      v_key := t_rand_key(v_p);
    end if;
    v_p := jsonb_set(v_p, '{entrants}', coalesce(v_p->'entrants', '[]'::jsonb) || jsonb_build_array(
             jsonb_build_object('id', v_key, 'name', v_raw, 'pid', v_pid, 'src', 'hand', 'st', 'in',
                                'seeker', '', 'terrain', '', 'deck', '', 'deckId', '')));
    if v_pid is not null then
      select q.r into v_p from t_link_all(v_p) q;
    end if;

  elsif p_op = 'remove' then
    if v_e->>'src' is distinct from 'hand' then
      return t_no('bad_input', 'Only players you added can be removed. Drop a registered player instead.');
    end if;
    v_p := jsonb_set(v_p, '{entrants}', (v_p->'entrants') - v_i);

  elsif p_op = 'unlink' then
    v_p := jsonb_set(v_p, array['entrants', v_i::text, 'lock'], 'true'::jsonb);
    if t_acct(v_e->>'id') then
      v_key := case when coalesce(v_e->>'pid', '') ~ '^[A-Za-z0-9]{6,32}$' then 'pn:' || (v_e->>'pid')
                    else t_rand_key(v_p) end;
      v_p := t_rekey(v_p, v_e->>'id', v_key);
    end if;

  elsif p_op = 'relink' then
    v_p := jsonb_set(v_p, array['entrants', v_i::text], (v_p->'entrants'->v_i) - 'lock');
    if v_e->>'pid' is not null then
      delete from tournament_marks
       where tournament_id = p_tid and kind = 'lock' and pid_hash = t_pid_hash(p_tid, v_e->>'pid');
    end if;
    select q.r into v_p from t_link_all(v_p, case when v_t.status = 'draft' then '*' else p_key end) q;

  elsif p_op = 'forget' then
    -- The entrant moves to the end of the list, so its place no longer
    -- matches the official page, and is named after a counter (fx).
    v_pid := v_e->>'pid';
    v_n := coalesce(case when v_p->>'fx' ~ '^[0-9]{1,4}$' then (v_p->>'fx')::int end, 0) + 1;
    v_e := (v_e - 'wait') || jsonb_build_object('name', 'Player ' || v_n, 'pid', null, 'lock', true);
    v_p := jsonb_set(v_p - 'nx', '{entrants}', ((v_p->'entrants') - v_i) || jsonb_build_array(v_e))
           || jsonb_build_object('fx', v_n);
    if v_pid is not null then
      insert into tournament_marks (tournament_id, pid_hash, kind)
      values (p_tid, t_pid_hash(p_tid, v_pid), 'forget')
      on conflict do nothing;
    end if;
    if p_key !~ '^h:' then
      v_p := t_rekey(v_p, p_key, t_rand_key(v_p));
    end if;
  end if;

  update tournaments set payload = v_p, rev = rev + 1 where id = p_tid returning rev into v_rev;
  return jsonb_build_object('ok', true, 'rev', v_rev);
end $$;

-- t_start: draft only. The page draws the groups and the schedule with the
-- usual functions (tvSplit, tvPairs, tvSchedule, buildBracket) and sends
-- them; they are checked here and stored as sent (gm and bracket rebuilt in
-- their plain shape):
--   * the groups hold every active player (st 'in') once, 3 to 256 of them,
--     at least 2 in each group;
--   * per group, the games are exactly every pair once, no winner, round and
--     table 1-999 or null;
--   * tables 0-64;
--   * the bracket has the empty shape tvGenerate makes: q = least(n, 4 with
--     one group, else 2 per group) qualifiers, the next power of 2 seats.
create or replace function public.t_start(p_tid uuid, p_rev int, p_mode text, p_engine jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := duel_caller();
  v_no     jsonb;
  v_bad    jsonb := t_no('bad_input', 'The draw is not valid. Reload the tournament and try again.');
  v_t      tournaments%rowtype;
  v_p      jsonb;
  v_act    text[];
  v_n      int;
  v_groups jsonb;
  v_ng     int;
  v_flat   text[];
  v_gm     jsonb := '[]'::jsonb;
  v_m      jsonb;
  v_g      int;
  v_rv     jsonb;
  v_tv     jsonb;
  v_cnt    int;
  v_dst    int;
  v_need   int;
  v_tables int;
  v_q      int;
  v_k      int;
  v_l      int;
  v_r      int;
  v_rd     jsonb;
  v_br     jsonb := '[]'::jsonb;
  v_rev    int;
begin
  v_no := t_lock(p_tid, p_rev);
  if v_no is not null then
    return v_no;
  end if;
  select * into v_t from tournaments x where x.id = p_tid;
  if v_t.status <> 'draft' then
    return t_no('status', 'The tournament has already started.');
  end if;
  if p_mode is null or p_mode not in ('clash','demo') then
    return t_no('bad_input', 'A tournament plays Clash or Demo.');
  end if;
  if p_engine is null or jsonb_typeof(p_engine) is distinct from 'object' then
    return v_bad;
  end if;
  v_p := v_t.payload;
  select coalesce(array_agg(q.x->>'id' order by q.o), '{}') into v_act
    from jsonb_array_elements(coalesce(v_p->'entrants', '[]'::jsonb)) with ordinality q(x, o)
   where q.x->>'st' = 'in';
  v_n := cardinality(v_act);
  if v_n < 3 then
    return t_no('bad_input', 'At least 3 players are needed to start.');
  end if;
  if v_n > 256 then
    return t_no('bad_input', 'A tournament has at most 256 players.');
  end if;

  -- groups
  v_groups := p_engine->'groups';
  if v_groups is null or jsonb_typeof(v_groups) is distinct from 'array' then
    return v_bad;
  end if;
  v_ng := jsonb_array_length(v_groups);
  if v_ng < 1 or v_ng > v_n then
    return v_bad;
  end if;
  if exists (select 1 from jsonb_array_elements(v_groups) q(x) where jsonb_typeof(q.x) <> 'array') then
    return v_bad;
  end if;
  if exists (select 1 from jsonb_array_elements(v_groups) q(x) where jsonb_array_length(q.x) < 2) then
    return v_bad;
  end if;
  if exists (select 1 from jsonb_array_elements(v_groups) q(x), jsonb_array_elements(q.x) y(k)
              where jsonb_typeof(y.k) <> 'string') then
    return v_bad;
  end if;
  v_flat := t_grouped(jsonb_build_object('groups', v_groups));
  if cardinality(v_flat) <> v_n
     or (select count(distinct z) from unnest(v_flat) z) <> v_n
     or not (v_flat <@ v_act) then
    return t_no('bad_input', 'The groups must hold every player in the list once. Reload the tournament and try again.');
  end if;

  -- group games
  if jsonb_typeof(p_engine->'gm') is distinct from 'array' then
    return v_bad;
  end if;
  for v_m in select q.x from jsonb_array_elements(p_engine->'gm') with ordinality q(x, o) order by q.o loop
    if jsonb_typeof(v_m) is distinct from 'object' or coalesce(v_m->>'g', '') !~ '^[0-9]{1,3}$' then
      return v_bad;
    end if;
    v_g := (v_m->>'g')::int;
    if v_g >= v_ng then
      return v_bad;
    end if;
    if jsonb_typeof(v_m->'a') is distinct from 'string' or jsonb_typeof(v_m->'b') is distinct from 'string'
       or v_m->>'a' = v_m->>'b' then
      return v_bad;
    end if;
    if not ((v_groups->v_g) @> jsonb_build_array(v_m->'a')) or not ((v_groups->v_g) @> jsonb_build_array(v_m->'b')) then
      return v_bad;
    end if;
    if coalesce(jsonb_typeof(v_m->'w'), 'null') <> 'null' then
      return v_bad;
    end if;
    v_rv := v_m->'r';
    if coalesce(jsonb_typeof(v_rv), 'null') = 'null' then
      v_rv := 'null'::jsonb;
    elsif v_rv::text !~ '^[1-9][0-9]{0,2}$' then
      return v_bad;
    end if;
    v_tv := v_m->'tb';
    if coalesce(jsonb_typeof(v_tv), 'null') = 'null' then
      v_tv := 'null'::jsonb;
    elsif v_tv::text !~ '^[1-9][0-9]{0,2}$' then
      return v_bad;
    end if;
    v_gm := v_gm || jsonb_build_array(jsonb_build_object('g', v_g, 'a', v_m->'a', 'b', v_m->'b', 'w', null,
                                                         'r', v_rv, 'tb', v_tv));
  end loop;
  select count(*),
         count(distinct (q.x->>'g') || '|' || least(q.x->>'a', q.x->>'b') || '|' || greatest(q.x->>'a', q.x->>'b'))
    into v_cnt, v_dst
    from jsonb_array_elements(v_gm) q(x);
  select sum(jsonb_array_length(q.x) * (jsonb_array_length(q.x) - 1) / 2) into v_need
    from jsonb_array_elements(v_groups) q(x);
  if v_cnt <> v_need or v_dst <> v_need then
    return t_no('bad_input', 'Every pair of players in a group plays once. Reload the tournament and try again.');
  end if;

  -- tables
  if jsonb_typeof(p_engine->'tables') is distinct from 'number'
     or (p_engine->'tables')::text !~ '^[0-9]{1,2}$' or ((p_engine->'tables')::text)::int > 64 then
    return v_bad;
  end if;
  v_tables := ((p_engine->'tables')::text)::int;

  -- the empty bracket
  v_q := least(v_n, case when v_ng = 1 then 4 else 2 * v_ng end);
  v_k := 1;
  v_l := 0;
  while v_k < v_q loop
    v_k := v_k * 2;
    v_l := v_l + 1;
  end loop;
  if jsonb_typeof(p_engine->'bracket') is distinct from 'array'
     or jsonb_array_length(p_engine->'bracket') <> v_l then
    return v_bad;
  end if;
  for v_r in 0 .. v_l - 1 loop
    v_rd := p_engine->'bracket'->v_r;
    if jsonb_typeof(v_rd) is distinct from 'array' or jsonb_array_length(v_rd) <> (v_k >> (v_r + 1)) then
      return v_bad;
    end if;
    if exists (select 1 from jsonb_array_elements(v_rd) q(x)
                where jsonb_typeof(q.x) <> 'object'
                   or coalesce(q.x->>'a', q.x->>'b', q.x->>'winner') is not null) then
      return v_bad;
    end if;
    v_br := v_br || jsonb_build_array((select jsonb_agg(jsonb_build_object('a', null, 'b', null, 'winner', null))
                                         from generate_series(1, v_k >> (v_r + 1))));
  end loop;

  v_p := (v_p - 'champion' - 'finalized_at')
         || jsonb_build_object('groups', v_groups, 'gm', v_gm, 'tables', v_tables,
                               'bracket', v_br, 'finalized', false);
  if octet_length(v_p::text) > 262144 then
    return t_no('bad_input', 'This tournament is too large.');
  end if;
  update tournaments set payload = v_p, status = 'running', mode = p_mode, rev = rev + 1
   where id = p_tid returning rev into v_rev;
  return jsonb_build_object('ok', true, 'rev', v_rev);
end $$;

-- t_unstart: back to registration while no result has been entered or
-- recorded (forfeits do not count). The draw is cleared. Tracked matches
-- tagged with its games become plain matches; they are untagged before the
-- tournament is locked (lock order: match, then tournament), and the untag
-- is undone if the tournament refuses.
create or replace function public.t_unstart(p_tid uuid, p_rev int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  v_no  jsonb;
  v_t   tournaments%rowtype;
  v_rev int;
begin
  select * into v_t from tournaments x where x.id = p_tid;
  if not found or v_t.status is null or not t_is_org(v_t) then
    return t_no('not_allowed', 'Only the organizer of this tournament can change it.');
  end if;
  begin
    update duels set tournament_id = null, t_ref = null where tournament_id = p_tid;
    v_no := t_lock(p_tid, p_rev);
    if v_no is null then
      select * into v_t from tournaments x where x.id = p_tid;
      if v_t.status <> 'running' then
        v_no := t_no('status', 'The tournament has not started.');
      elsif t_has_results(v_t.payload) then
        v_no := t_no('has_results', 'Results are already in, so the tournament cannot go back to registration.');
      end if;
    end if;
    if v_no is not null then
      raise exception 't_unstart refused' using errcode = 'SL001';
    end if;
    update tournaments
       set payload = payload || jsonb_build_object('groups', '[]'::jsonb, 'gm', '[]'::jsonb, 'tables', 0,
                                                   'bracket', '[]'::jsonb, 'finalized', false),
           status = 'draft', rev = rev + 1
     where id = p_tid returning rev into v_rev;
  exception when sqlstate 'SL001' then
    return v_no;
  end;
  return jsonb_build_object('ok', true, 'rev', v_rev);
end $$;

-- t_result: the organizer enters or clears a result.
--   'g:<i>'      p_winner null (clear) or one of the game's two keys ('a'
--                or 'b' also work). src 'org'; a tracked match already linked
--                (du) stays, and dx marks a different winner. When every
--                group game has a result, p_round0 (the finals draw) places
--                the bracket; it is required when the finals were drawn
--                already (round0_needed); finals matches that keep their two
--                players keep their results (t_place_round0). Otherwise the
--                bracket is emptied.
--   'b:<r>:<k>'  both players placed; p_winner null or one of the two keys.
--                Winners move on (t_propagate): a later match keeps its
--                result while the same two players still meet there, and
--                loses it when they change.
-- Then finished tracked matches of games left without one are attached
-- again (t_reattach), so a result entered by hand never counts twice.
create or replace function public.t_result(p_tid uuid, p_rev int, p_ref text, p_winner text, p_round0 jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := duel_caller();
  v_no   jsonb;
  v_t    tournaments%rowtype;
  v_p    jsonb;
  v_m    jsonb;
  v_i    int;
  v_mm   text[];
  v_r    int;
  v_k    int;
  v_w    text;
  v_side text;
  v_dw   text;
  v_r0   jsonb := case when jsonb_typeof(p_round0) = 'array' then p_round0 end;
  v_rev  int;
begin
  v_no := t_lock(p_tid, p_rev);
  if v_no is not null then
    return v_no;
  end if;
  select * into v_t from tournaments x where x.id = p_tid;
  if v_t.status = 'closed' then
    return t_no('status', 'The tournament is closed. Reopen it to change results.');
  end if;
  if v_t.status <> 'running' then
    return t_no('status', 'The tournament has not started.');
  end if;
  v_p := v_t.payload;

  if p_ref ~ '^g:[0-9]{1,4}$' then
    v_i := substr(p_ref, 3)::int;
    v_m := v_p->'gm'->v_i;
    if v_m is null then
      return t_no('bad_input', 'This game is not in the tournament.');
    end if;
    v_w := case when p_winner is null then null
                when p_winner = 'a' or p_winner = v_m->>'a' then v_m->>'a'
                when p_winner = 'b' or p_winner = v_m->>'b' then v_m->>'b' end;
    if p_winner is not null and v_w is null then
      return t_no('bad_input', 'The winner must be one of the two players.');
    end if;
    if v_w is null then
      v_m := (v_m - 'src' - 'at' - 'auto' - 'dx') || '{"w":null}'::jsonb;
    else
      v_m := (v_m - 'auto' - 'dx') || jsonb_build_object('w', v_w, 'src', 'org', 'at', now());
      if v_m->>'du' is not null then
        select d.winner_id::text into v_dw from duels d where d.id = (v_m->>'du')::uuid and d.status = 'done';
        if v_dw is not null and v_dw <> v_w then
          v_m := v_m || '{"dx":true}'::jsonb;
        end if;
      end if;
    end if;
    v_p := jsonb_set(v_p, array['gm', v_i::text], v_m);
    if t_gm_done(v_p) then
      if v_r0 is not null then
        if not t_round0_ok(v_p, v_r0) then
          return t_no('bad_input', 'The finals draw is not valid. Reload the tournament and try again.');
        end if;
        v_p := t_place_round0(v_p, v_r0);
      elsif not t_r0_empty(v_p) then
        return t_no('round0_needed', 'The finals have to be drawn again. Reload the tournament and try again.');
      end if;
    else
      v_p := t_clear_bracket(v_p);
    end if;

  elsif p_ref ~ '^b:[0-9]{1,2}:[0-9]{1,4}$' then
    v_mm := regexp_match(p_ref, '^b:([0-9]{1,2}):([0-9]{1,4})$');
    v_r := v_mm[1]::int;
    v_k := v_mm[2]::int;
    v_m := v_p->'bracket'->v_r->v_k;
    if v_m is null or v_m #>> '{a,id}' is null or v_m #>> '{b,id}' is null then
      return t_no('bad_input', 'This finals match does not have both players yet.');
    end if;
    v_side := case when p_winner is null then null
                   when p_winner = 'a' or p_winner = v_m #>> '{a,id}' then 'a'
                   when p_winner = 'b' or p_winner = v_m #>> '{b,id}' then 'b' end;
    if p_winner is not null and v_side is null then
      return t_no('bad_input', 'The winner must be one of the two players.');
    end if;
    if v_side is null then
      v_m := (v_m - 'src' - 'at' - 'auto' - 'dx') || '{"winner":null}'::jsonb;
    else
      v_m := (v_m - 'auto' - 'dx') || jsonb_build_object('winner', v_side, 'src', 'org', 'at', now());
      if v_m->>'du' is not null then
        select d.winner_id::text into v_dw from duels d where d.id = (v_m->>'du')::uuid and d.status = 'done';
        if v_dw is not null and v_dw <> (v_m #>> array[v_side, 'id']) then
          v_m := v_m || '{"dx":true}'::jsonb;
        end if;
      end if;
    end if;
    v_p := t_propagate(jsonb_set(v_p, array['bracket', v_r::text, v_k::text], v_m));

  else
    return t_no('bad_input', 'This game is not in the tournament.');
  end if;

  v_p := t_reattach(v_p, p_tid);
  update tournaments set payload = v_p, rev = rev + 1 where id = p_tid returning rev into v_rev;
  return jsonb_build_object('ok', true, 'rev', v_rev);
end $$;

-- t_fill: the finals drawn after the last group game was recorded from a
-- tracked match (the organizer's page sends the draw on its next poll).
create or replace function public.t_fill(p_tid uuid, p_rev int, p_round0 jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  v_no  jsonb;
  v_t   tournaments%rowtype;
  v_rev int;
begin
  v_no := t_lock(p_tid, p_rev);
  if v_no is not null then
    return v_no;
  end if;
  select * into v_t from tournaments x where x.id = p_tid;
  if v_t.status <> 'running' then
    return t_no('status', 'The tournament is not running.');
  end if;
  if not t_gm_done(v_t.payload) then
    return t_no('status', 'The group stage is not finished yet.');
  end if;
  if not t_r0_empty(v_t.payload) then
    return t_no('finals_drawn', 'The finals are already drawn.');
  end if;
  if not t_round0_ok(v_t.payload, p_round0) then
    return t_no('bad_input', 'The finals draw is not valid. Reload the tournament and try again.');
  end if;
  update tournaments set payload = t_reattach(t_place_round0(payload, p_round0), p_tid), rev = rev + 1
   where id = p_tid returning rev into v_rev;
  return jsonb_build_object('ok', true, 'rev', v_rev);
end $$;

-- t_close: closed, finalized, with the final's winner as champion (none when
-- the final was not played). t_reopen: running again.
create or replace function public.t_close(p_tid uuid, p_rev int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := duel_caller();
  v_no   jsonb;
  v_t    tournaments%rowtype;
  v_fin  jsonb;
  v_ch   text;
  v_rev  int;
begin
  v_no := t_lock(p_tid, p_rev);
  if v_no is not null then
    return v_no;
  end if;
  select * into v_t from tournaments x where x.id = p_tid;
  if v_t.status <> 'running' then
    return t_no('status', 'Only a running tournament can be closed.');
  end if;
  if jsonb_typeof(v_t.payload->'bracket') = 'array' and jsonb_array_length(v_t.payload->'bracket') > 0 then
    v_fin := v_t.payload->'bracket'->(jsonb_array_length(v_t.payload->'bracket') - 1)->0;
    v_ch := case v_fin->>'winner' when 'a' then v_fin #>> '{a,id}' when 'b' then v_fin #>> '{b,id}' end;
  end if;
  update tournaments
     set payload = (payload - 'champion')
                   || jsonb_build_object('finalized', true, 'finalized_at', now())
                   || case when v_ch is not null then jsonb_build_object('champion', v_ch) else '{}'::jsonb end,
         status = 'closed', rev = rev + 1
   where id = p_tid returning rev into v_rev;
  return jsonb_build_object('ok', true, 'rev', v_rev);
end $$;

create or replace function public.t_reopen(p_tid uuid, p_rev int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  v_no  jsonb;
  v_t   tournaments%rowtype;
  v_rev int;
begin
  v_no := t_lock(p_tid, p_rev);
  if v_no is not null then
    return v_no;
  end if;
  select * into v_t from tournaments x where x.id = p_tid;
  if v_t.status <> 'closed' then
    return t_no('status', 'The tournament is not closed.');
  end if;
  update tournaments
     set payload = (payload - 'champion' - 'finalized_at') || '{"finalized":false}'::jsonb,
         status = 'running', rev = rev + 1
   where id = p_tid returning rev into v_rev;
  return jsonb_build_object('ok', true, 'rev', v_rev);
end $$;

-- t_discard: deleted with its list of players and its draw, while it is in
-- draft or no result was entered or recorded. Its tracked matches are
-- untagged first (lock order: match, then tournament); if the tournament
-- then refuses, the untag is undone.
create or replace function public.t_discard(p_tid uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  v_no  jsonb;
  v_t   tournaments%rowtype;
begin
  select * into v_t from tournaments x where x.id = p_tid;
  if not found or v_t.status is null or not t_is_org(v_t) then
    return t_no('not_allowed', 'Only the organizer of this tournament can discard it.');
  end if;
  if exists (select 1 from leagues l where l.id = v_t.league_id and l.archived_at is not null) then
    return t_no('archived', 'This community is archived.');
  end if;
  if v_t.status <> 'draft' and t_has_results(v_t.payload) then
    return t_no('has_results', 'Results are already in, so the tournament cannot be discarded. Close it instead.');
  end if;
  begin
    update duels set tournament_id = null, t_ref = null where tournament_id = p_tid;
    select * into v_t from tournaments x where x.id = p_tid for update;
    if not found then
      v_no := t_no('not_allowed', 'This tournament was not found.');
    elsif v_t.status <> 'draft' and t_has_results(v_t.payload) then
      v_no := t_no('has_results', 'Results are already in, so the tournament cannot be discarded. Close it instead.');
    end if;
    if v_no is not null then
      raise exception 't_discard refused' using errcode = 'SL001';
    end if;
    delete from tournaments where id = p_tid;
  exception when sqlstate 'SL001' then
    return v_no;
  end;
  return jsonb_build_object('ok', true);
end $$;

-- t_take_over: when the organizer's account was deleted, or the organizer is
-- no longer the creator or an organizer of the community, the community's
-- creator or one of its organizers (or the site admin) becomes organizer.
create or replace function public.t_take_over(p_tid uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  v_t   tournaments%rowtype;
  v_rev int;
begin
  select * into v_t from tournaments x where x.id = p_tid for update;
  if not found or v_t.status is null then
    return t_no('not_allowed', 'This tournament was not found.');
  end if;
  if v_t.organizer_id is not null
     and exists (select 1 from profiles pr where pr.id = v_t.organizer_id and pr.deleted_at is null)
     and t_user_admin(v_t.league_id, v_t.organizer_id) then
    return t_no('not_allowed', 'This tournament already has an organizer.');
  end if;
  if not (coalesce(is_league_admin(v_t.league_id), false) or coalesce(is_site_admin(), false)) then
    return t_no('not_allowed', 'Only the creator or an organizer of this community can take it over.');
  end if;
  if exists (select 1 from leagues l where l.id = v_t.league_id and l.archived_at is not null) then
    return t_no('archived', 'This community is archived.');
  end if;
  update tournaments set organizer_id = v_uid, rev = rev + 1 where id = p_tid returning rev into v_rev;
  return jsonb_build_object('ok', true, 'rev', v_rev);
end $$;

-- t_live_duels: the tracked matches of this tournament still being played
-- or waiting for confirmation, for its organizer and its players.
create or replace function public.t_live_duels(p_tid uuid)
returns table (t_ref text, status text, claim_winner uuid, claimed_at timestamptz)
language sql stable security definer set search_path = public as $$
  select d.t_ref, d.status, d.claim_winner, d.claimed_at
    from duels d
    join tournaments t on t.id = d.tournament_id
   where d.tournament_id = p_tid
     and d.status in ('live','ending')
     and t.status is not null
     and auth.uid() is not null
     and ((t.organizer_id = auth.uid() and is_league_admin(t.league_id))
          or is_site_admin()
          or t.payload->'entrants' @> jsonb_build_array(jsonb_build_object('id', auth.uid()::text)))
   order by d.t_ref;
$$;

-- t_mine: the Play Network tournaments the caller organizes or plays in,
-- newest first (they may be in a community the caller is not a member of).
create or replace function public.t_mine()
returns setof public.tournaments
language sql stable security definer set search_path = public as $$
  select t.*
    from tournaments t
   where t.status is not null
     and auth.uid() is not null
     and ((t.organizer_id = auth.uid() and is_league_admin(t.league_id))
          or t.payload->'entrants' @> jsonb_build_array(jsonb_build_object('id', auth.uid()::text)))
   order by t.created_at desc
   limit 50;
$$;

-- t_fetch_allow: called by the edge function AS THE CALLER before it reads
-- the official page to import the players: the organizer, in draft, the
-- community not archived, a valid event link, at least 30 seconds since the
-- last import, and the pn_fetch_log brakes of pn_fetch_allow (20 look-ups an
-- hour per account, 300 on the site; the look-up is logged). Refusals are
-- not logged.
create or replace function public.t_fetch_allow(p_tid uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_t   tournaments%rowtype;
  v_url text;
begin
  if v_uid is null or coalesce((auth.jwt()->>'is_anonymous')::boolean, false) or p_tid is null then
    return t_no('not_allowed', 'Only the organizer of this tournament can update its players.');
  end if;
  select * into v_t from tournaments x where x.id = p_tid;
  if not found or v_t.status is null or not t_is_org(v_t) then
    return t_no('not_allowed', 'Only the organizer of this tournament can update its players.');
  end if;
  if exists (select 1 from leagues l where l.id = v_t.league_id and l.archived_at is not null) then
    return t_no('archived', 'This community is archived.');
  end if;
  if v_t.status <> 'draft' then
    return t_no('started', 'The tournament has started, so its list of players is fixed.');
  end if;
  select pn_canonical_url(e.url) into v_url from pn_events e where e.id = v_t.pn_event_id;
  v_url := coalesce(v_url, pn_canonical_url(v_t.payload #>> '{pn,url}'));
  if v_url is null then
    return t_no('not_allowed', 'This tournament has no Play Network event link.');
  end if;
  if (v_t.payload #>> '{pn,at}') is not null
     and (v_t.payload #>> '{pn,at}')::timestamptz > now() - interval '30 seconds' then
    return t_no('rate_limited', 'The players were updated a moment ago. Try again in half a minute.');
  end if;
  perform pg_advisory_xact_lock(hashtext('pn_fetch_allow'));
  delete from pn_fetch_log where created_at < now() - interval '2 days';
  if (select count(*) from pn_fetch_log
      where user_id = v_uid and created_at > now() - interval '1 hour') >= 20
     or (select count(*) from pn_fetch_log where created_at > now() - interval '1 hour') >= 300 then
    return t_no('rate_limited', 'Too many look-ups of the Play Network in the last hour. Try again later.');
  end if;
  insert into pn_fetch_log (user_id, league_id) values (v_uid, v_t.league_id);
  return jsonb_build_object('ok', true, 'url', v_url, 'league_id', v_t.league_id, 'pn_event_id', v_t.pn_event_id);
end $$;

-- t_import: the edge function (service role only) merges the players read
-- from the official page, in draft. p_regs: [{pid, name}], the public id and
-- the nickname, nothing else. p_count: the page's registered count.
--   * a registered player who is no longer on the page goes, but only when
--     the list is complete (p_count is the number of valid registrants
--     read): a list cut short (count_mismatch, too_many, a page read in
--     part) removes nobody. A player who goes after the organizer unlinked
--     a wrong account leaves a 'lock' mark (tournament_marks), so if they
--     register again they come back locked. Players added by hand stay;
--     drops and locks stay; names follow the page;
--   * new registrants are added (not those removed on request, see
--     forget), at most 256 players in all (warning 'too_many');
--   * accounts are matched by profiles.mg_public_id (t_link_all).
-- Answers {ok, rev, total (registrants read), added, removed, linked
-- (players with an account)}.
create or replace function public.t_import(p_tid uuid, p_regs jsonb, p_count int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_t       tournaments%rowtype;
  v_p       jsonb;
  v_reg     jsonb;
  v_regs    jsonb := '[]'::jsonb;
  v_seen    text[] := '{}';
  v_pid     text;
  v_name    text;
  v_full    boolean;
  v_ents    jsonb := '[]'::jsonb;
  v_e       jsonb;
  v_added   int := 0;
  v_removed int := 0;
  v_linked  int;
  v_warn    text;
  v_rev     int;
begin
  if p_tid is null or p_regs is null or jsonb_typeof(p_regs) is distinct from 'array' then
    return t_no('bad_input', 'The list of players is not valid.');
  end if;
  select * into v_t from tournaments x where x.id = p_tid for update;
  if not found or v_t.status is null then
    return t_no('not_allowed', 'This tournament was not found.');
  end if;
  if v_t.status <> 'draft' then
    return t_no('started', 'The tournament has started, so its list of players is fixed.');
  end if;
  if exists (select 1 from leagues l where l.id = v_t.league_id and l.archived_at is not null) then
    return t_no('archived', 'This community is archived.');
  end if;
  v_p := v_t.payload - 'nx';

  -- the registrants: valid public ids, each once
  for v_reg in select q.x from jsonb_array_elements(p_regs) with ordinality q(x, o) order by q.o limit 1000 loop
    if jsonb_typeof(v_reg) is distinct from 'object' then
      continue;
    end if;
    v_pid := v_reg->>'pid';
    if v_pid is null or v_pid !~ '^[A-Za-z0-9]{6,32}$' or v_pid = any(v_seen) then
      continue;
    end if;
    v_seen := v_seen || v_pid;
    v_name := coalesce(t_clean_name(v_reg->>'name'), 'Player');
    v_regs := v_regs || jsonb_build_array(jsonb_build_object('pid', v_pid, 'name', v_name));
  end loop;
  v_full := p_count is not null and p_count = cardinality(v_seen);

  -- the players already in the list
  for v_e in select q.x from jsonb_array_elements(coalesce(v_p->'entrants', '[]'::jsonb)) with ordinality q(x, o) order by q.o loop
    if v_e->>'src' = 'pn' and v_e->>'pid' is not null then
      if not (v_e->>'pid' = any(v_seen)) then
        if not v_full then
          v_ents := v_ents || jsonb_build_array(v_e);
          continue;
        end if;
        if (v_e->>'lock') = 'true' then
          insert into tournament_marks (tournament_id, pid_hash, kind)
          values (p_tid, t_pid_hash(p_tid, v_e->>'pid'), 'lock')
          on conflict do nothing;
        end if;
        v_removed := v_removed + 1;
        continue;
      end if;
      v_e := v_e || jsonb_build_object('name', (select z.x->>'name' from jsonb_array_elements(v_regs) z(x)
                                                 where z.x->>'pid' = v_e->>'pid' limit 1));
    end if;
    v_ents := v_ents || jsonb_build_array(v_e);
  end loop;

  -- the new registrants
  for v_reg in select q.x from jsonb_array_elements(v_regs) with ordinality q(x, o) order by q.o loop
    if v_ents @> jsonb_build_array(jsonb_build_object('pid', v_reg->>'pid')) then
      continue;
    end if;
    if exists (select 1 from tournament_marks k
                where k.tournament_id = p_tid and k.kind = 'forget'
                  and k.pid_hash = t_pid_hash(p_tid, v_reg->>'pid')) then
      continue;
    end if;
    if jsonb_array_length(v_ents) >= 256 then
      v_warn := 'too_many';
      exit;
    end if;
    v_ents := v_ents || jsonb_build_array(jsonb_build_object(
                'id', 'pn:' || (v_reg->>'pid'), 'name', v_reg->>'name', 'pid', v_reg->>'pid',
                'src', 'pn', 'st', 'in', 'seeker', '', 'terrain', '', 'deck', '', 'deckId', '')
                || case when exists (select 1 from tournament_marks k
                                      where k.tournament_id = p_tid and k.kind = 'lock'
                                        and k.pid_hash = t_pid_hash(p_tid, v_reg->>'pid'))
                        then '{"lock":true}'::jsonb else '{}'::jsonb end);
    v_added := v_added + 1;
  end loop;

  v_p := jsonb_set(v_p, '{entrants}', v_ents);
  select q.r, q.linked into v_p, v_linked from t_link_all(v_p) q;
  v_p := jsonb_set(v_p, '{pn}', coalesce(v_p->'pn', '{}'::jsonb)
                                || jsonb_build_object('at', now(),
                                                      'n', case when p_count between 0 and 100000 then p_count end));
  update tournaments set payload = v_p, rev = rev + 1 where id = p_tid returning rev into v_rev;
  return jsonb_build_object('ok', true, 'rev', v_rev, 'total', cardinality(v_seen),
                            'added', v_added, 'removed', v_removed, 'linked', v_linked)
         || case when v_warn is not null then jsonb_build_object('warning', v_warn) else '{}'::jsonb end;
end $$;

revoke all on function public.t_create(uuid, text)                          from public, anon;
revoke all on function public.t_entrant(uuid, int, text, text, text, text)  from public, anon;
revoke all on function public.t_start(uuid, int, text, jsonb)               from public, anon;
revoke all on function public.t_unstart(uuid, int)                          from public, anon;
revoke all on function public.t_result(uuid, int, text, text, jsonb)        from public, anon;
revoke all on function public.t_fill(uuid, int, jsonb)                      from public, anon;
revoke all on function public.t_close(uuid, int)                            from public, anon;
revoke all on function public.t_reopen(uuid, int)                           from public, anon;
revoke all on function public.t_discard(uuid)                               from public, anon;
revoke all on function public.t_take_over(uuid)                             from public, anon;
revoke all on function public.t_live_duels(uuid)                            from public, anon;
revoke all on function public.t_mine()                                      from public, anon;
revoke all on function public.t_fetch_allow(uuid)                           from public, anon;
revoke all on function public.t_import(uuid, jsonb, int)                    from public, anon, authenticated;
grant execute on function public.t_create(uuid, text)                       to authenticated;
grant execute on function public.t_entrant(uuid, int, text, text, text, text) to authenticated;
grant execute on function public.t_start(uuid, int, text, jsonb)            to authenticated;
grant execute on function public.t_unstart(uuid, int)                       to authenticated;
grant execute on function public.t_result(uuid, int, text, text, jsonb)     to authenticated;
grant execute on function public.t_fill(uuid, int, jsonb)                   to authenticated;
grant execute on function public.t_close(uuid, int)                         to authenticated;
grant execute on function public.t_reopen(uuid, int)                        to authenticated;
grant execute on function public.t_discard(uuid)                            to authenticated;
grant execute on function public.t_take_over(uuid)                          to authenticated;
grant execute on function public.t_live_duels(uuid)                         to authenticated;
grant execute on function public.t_mine()                                   to authenticated;
grant execute on function public.t_fetch_allow(uuid)                        to authenticated;
grant execute on function public.t_import(uuid, jsonb, int)                 to service_role;

-- 6. A saved, changed or removed profile link matches the account again ------
-- In draft and running tournaments only (closed ones are frozen): see
-- t_link_all. Before the start the account is linked; after it, an account
-- that changes or removes its link is unlinked, but a new link is only
-- marked (wait) for the organizer to confirm. A failure here never stops
-- the profile from being saved.
create or replace function public.t_profile_link()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_t record;
  v_p jsonb;
begin
  begin
    for v_t in
      select x.id, x.payload, x.status
        from tournaments x
       where x.status is not null
         and x.status in ('draft','running')
         and (x.payload->'entrants' @> jsonb_build_array(jsonb_build_object('id', new.id::text))
              or (new.mg_public_id is not null
                  and x.payload->'entrants' @> jsonb_build_array(jsonb_build_object('pid', new.mg_public_id)))
              or (old.mg_public_id is not null
                  and x.payload->'entrants' @> jsonb_build_array(jsonb_build_object('pid', old.mg_public_id))))
       order by x.created_at
       for update
    loop
      select q.r into v_p from t_link_all(v_t.payload, case when v_t.status = 'draft' then '*' end) q;
      if v_p is distinct from v_t.payload then
        update tournaments set payload = v_p, rev = rev + 1 where id = v_t.id;
      end if;
    end loop;
  exception when others then
    raise warning 't_profile_link: %', sqlerrm;
  end;
  return null;
end $$;
revoke all on function public.t_profile_link() from public, anon, authenticated;
drop trigger if exists t_profile_link on public.profiles;
create trigger t_profile_link after update on public.profiles
  for each row
  when (old.mg_public_id is distinct from new.mg_public_id or old.deleted_at is distinct from new.deleted_at)
  execute function public.t_profile_link();

-- 7. Tracked matches as tournament games ---------------------------------------
-- t_game_for: the tournament game two players are about to play, for
-- duel_join. Running tournaments with both of them in the list, oldest
-- first, locked (lock order: match, then tournament). Neither may be
-- dropped. Their first undecided group game (by round), else their open
-- finals match. A game in the other mode is skipped ('mode'), as is one with
-- another tracked match live or waiting for confirmation ('busy'). Answers
-- the first game that can be tagged, else a row with only skip (and the
-- tournament's title and label), else nothing.
create or replace function public.t_game_for(p_host uuid, p_guest uuid, p_mode text)
returns table (tournament_id uuid, t_ref text, title text, label text, skip text)
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_t      record;
  v_h      text := p_host::text;
  v_g      text := p_guest::text;
  v_ref    text;
  v_skip   text;
  v_stitle text;
  v_slabel text;
begin
  if p_host is null or p_guest is null or p_host = p_guest then
    return;
  end if;
  for v_t in
    select x.id, x.payload, x.mode
      from tournaments x
     where x.status = 'running'
       and x.payload->'entrants' @> jsonb_build_array(jsonb_build_object('id', v_h))
       and x.payload->'entrants' @> jsonb_build_array(jsonb_build_object('id', v_g))
     order by x.created_at
     for update
  loop
    if exists (select 1 from jsonb_array_elements(v_t.payload->'entrants') y(e)
                where y.e->>'id' in (v_h, v_g) and y.e->>'st' = 'drop') then
      continue;
    end if;
    v_ref := null;
    select 'g:' || (y.o - 1) into v_ref
      from jsonb_array_elements(coalesce(v_t.payload->'gm', '[]'::jsonb)) with ordinality y(m, o)
     where y.m->>'w' is null
       and ((y.m->>'a' = v_h and y.m->>'b' = v_g) or (y.m->>'a' = v_g and y.m->>'b' = v_h))
     order by case when y.m->>'r' ~ '^[0-9]{1,3}$' then (y.m->>'r')::int else 0 end, y.o
     limit 1;
    if v_ref is null then
      select 'b:' || (y.o - 1) || ':' || (z.o - 1) into v_ref
        from jsonb_array_elements(coalesce(v_t.payload->'bracket', '[]'::jsonb)) with ordinality y(rd, o),
             jsonb_array_elements(y.rd) with ordinality z(m, o)
       where z.m->>'winner' is null
         and ((z.m #>> '{a,id}' = v_h and z.m #>> '{b,id}' = v_g)
              or (z.m #>> '{a,id}' = v_g and z.m #>> '{b,id}' = v_h))
       order by y.o, z.o
       limit 1;
    end if;
    if v_ref is null then
      continue;
    end if;
    if v_t.mode is distinct from p_mode then
      if v_skip is null then
        v_skip := 'mode';
        v_stitle := nullif(btrim(v_t.payload #>> '{pn,title}'), '');
        v_slabel := t_game_label(v_t.payload, v_ref);
      end if;
      continue;
    end if;
    if exists (select 1 from duels d
                where d.tournament_id = v_t.id and d.t_ref = v_ref and d.status in ('live','ending')) then
      if v_skip is null then
        v_skip := 'busy';
        v_stitle := nullif(btrim(v_t.payload #>> '{pn,title}'), '');
        v_slabel := t_game_label(v_t.payload, v_ref);
      end if;
      continue;
    end if;
    return query select v_t.id, v_ref, nullif(btrim(v_t.payload #>> '{pn,title}'), ''),
                        t_game_label(v_t.payload, v_ref), null::text;
    return;
  end loop;
  if v_skip is not null then
    return query select null::uuid, null::text, v_stitle, v_slabel, v_skip;
  end if;
end $$;

-- t_record_duel: a tracked match that is done (concession, confirmation or
-- the 48-hour auto-save) is recorded in its tournament game, when the two
-- players at that place are the two players of the match and neither is
-- dropped. While the tournament is running, an undecided game gets the
-- winner (src 'duel', du, at, auto when it was saved after 48 hours; finals:
-- winners move on). A game already decided with no tracked match gets du
-- only, and dx when the winners differ: the organizer's result is kept;
-- this also happens in a closed tournament (a claim saved after the
-- organizer entered the result by hand and closed it), so the game is never
-- counted twice in the Meta.
-- Never raises: it runs inside duel_sweep(), which duel_open() and
-- duel_join() call. Lock order: the match row (already locked by the update
-- that fired the trigger), then the tournament.
create or replace function public.t_record_duel(p_duel uuid, p_auto boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_d    duels%rowtype;
  v_t    tournaments%rowtype;
  v_p    jsonb;
  v_m    jsonb;
  v_h    text;
  v_g    text;
  v_w    text;
  v_a    text;
  v_b    text;
  v_i    int;
  v_mm   text[];
  v_r    int;
  v_k    int;
  v_dec  text;
  v_auto jsonb := case when coalesce(p_auto, false) then '{"auto":true}'::jsonb else '{}'::jsonb end;
begin
  begin
    select * into v_d from duels x where x.id = p_duel;
    if not found or v_d.status <> 'done' or v_d.tournament_id is null or v_d.t_ref is null
       or v_d.guest_id is null or v_d.winner_id is null then
      return;
    end if;
    select * into v_t from tournaments x where x.id = v_d.tournament_id for update;
    if not found or v_t.status is null or v_t.status not in ('running','closed') then
      return;
    end if;
    v_p := v_t.payload;
    v_h := v_d.host_id::text;
    v_g := v_d.guest_id::text;
    v_w := v_d.winner_id::text;
    if exists (select 1 from jsonb_array_elements(coalesce(v_p->'entrants', '[]'::jsonb)) y(e)
                where y.e->>'id' in (v_h, v_g) and y.e->>'st' = 'drop') then
      return;
    end if;

    if v_d.t_ref ~ '^g:[0-9]{1,4}$' then
      v_i := substr(v_d.t_ref, 3)::int;
      v_m := v_p->'gm'->v_i;
      if v_m is null then
        return;
      end if;
      v_a := v_m->>'a';
      v_b := v_m->>'b';
      if not coalesce((v_a = v_h and v_b = v_g) or (v_a = v_g and v_b = v_h), false) then
        return;
      end if;
      if v_m->>'w' is null then
        if v_t.status <> 'running' then
          return;
        end if;
        v_m := (v_m - 'dx') || jsonb_build_object('w', v_w, 'src', 'duel', 'du', v_d.id, 'at', now()) || v_auto;
      elsif v_m->>'du' is null then
        v_m := v_m || jsonb_build_object('du', v_d.id)
                   || case when v_m->>'w' <> v_w then '{"dx":true}'::jsonb else '{}'::jsonb end;
      else
        return;
      end if;
      v_p := jsonb_set(v_p, array['gm', v_i::text], v_m);

    elsif v_d.t_ref ~ '^b:[0-9]{1,2}:[0-9]{1,4}$' then
      v_mm := regexp_match(v_d.t_ref, '^b:([0-9]{1,2}):([0-9]{1,4})$');
      v_r := v_mm[1]::int;
      v_k := v_mm[2]::int;
      v_m := v_p->'bracket'->v_r->v_k;
      if v_m is null then
        return;
      end if;
      v_a := v_m #>> '{a,id}';
      v_b := v_m #>> '{b,id}';
      if not coalesce((v_a = v_h and v_b = v_g) or (v_a = v_g and v_b = v_h), false) then
        return;
      end if;
      if v_m->>'winner' is null then
        if v_t.status <> 'running' then
          return;
        end if;
        v_m := (v_m - 'dx')
               || jsonb_build_object('winner', case when v_a = v_w then 'a' else 'b' end,
                                     'src', 'duel', 'du', v_d.id, 'at', now())
               || v_auto;
        v_p := t_propagate(jsonb_set(v_p, array['bracket', v_r::text, v_k::text], v_m));
      elsif v_m->>'du' is null then
        v_dec := case v_m->>'winner' when 'a' then v_a when 'b' then v_b end;
        v_m := v_m || jsonb_build_object('du', v_d.id)
                   || case when v_dec is distinct from v_w then '{"dx":true}'::jsonb else '{}'::jsonb end;
        v_p := jsonb_set(v_p, array['bracket', v_r::text, v_k::text], v_m);
      else
        return;
      end if;

    else
      return;
    end if;

    update tournaments set payload = v_p, rev = rev + 1 where id = v_t.id;
  exception when others then
    raise warning 't_record_duel: %', sqlerrm;
  end;
end $$;

-- One trigger covers the three ways a match becomes done.
create or replace function public.duel_t_record()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin
    perform t_record_duel(new.id, old.status = 'ending'
                                  and coalesce(old.claimed_at, old.updated_at) < now() - interval '48 hours');
  exception when others then
    raise warning 'duel_t_record: %', sqlerrm;
  end;
  return null;
end $$;
revoke all on function public.t_game_for(uuid, uuid, text)  from public, anon, authenticated;
revoke all on function public.t_record_duel(uuid, boolean)  from public, anon, authenticated;
revoke all on function public.duel_t_record()               from public, anon, authenticated;
drop trigger if exists duel_t_record on public.duels;
create trigger duel_t_record after update on public.duels
  for each row
  when (new.status = 'done' and old.status is distinct from 'done' and new.tournament_id is not null)
  execute function public.duel_t_record();

-- duel_join: as in the MATCH TRACKER section, and the match is tagged with
-- the tournament game of the two players (t_game_for), if any. A failure
-- there never stops the join: the match is then a plain one. The answer
-- gains t: {id, title, label, skip} (null when no tournament game applies).
create or replace function public.duel_join(p_pin text, p_seeker text, p_terrain text, p_deck_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid     uuid := duel_caller();
  v_seeker  text := duel_clean(p_seeker);
  v_terrain text := duel_clean(p_terrain);
  v_pin     text := btrim(coalesce(p_pin, ''));
  d         duels%rowtype;
  v_tid     uuid;
  v_tref    text;
  v_ttitle  text;
  v_tlabel  text;
  v_tskip   text;
begin
  if v_seeker is null or v_terrain is null then
    raise exception 'Pick your Seeker and terrain first' using errcode = '22023';
  end if;
  if p_deck_id is not null
     and not exists (select 1 from decks k where k.id = p_deck_id and k.user_id = v_uid) then
    raise exception 'Pick one of your own decks' using errcode = '42501';
  end if;
  if v_pin !~ '^[0-9]{4}$' then
    return jsonb_build_object('ok', false, 'reason', 'bad_pin');
  end if;

  perform duel_sweep();
  perform pg_advisory_xact_lock(hashtext('duel_join:' || v_uid::text));
  if (select count(*) from duel_join_attempts a
      where a.user_id = v_uid and a.created_at > now() - interval '1 minute') >= 5
     or (select count(*) from duel_join_attempts a
         where a.user_id = v_uid and a.created_at > now() - interval '1 hour') >= 20
     or (select count(*) from duel_join_attempts a
         where a.user_id = v_uid and a.created_at > now() - interval '1 day') >= 60 then
    return jsonb_build_object('ok', false, 'reason', 'rate_limited');
  end if;
  if (select count(*) from duel_join_attempts a
      where a.created_at > now() - interval '10 minutes') >= 600 then
    return jsonb_build_object('ok', false, 'reason', 'busy');
  end if;

  select * into d from duels x where x.pin = v_pin and x.status = 'waiting' for update;
  if not found or d.pin_expires_at <= now() then
    insert into duel_join_attempts (user_id) values (v_uid);
    return jsonb_build_object('ok', false, 'reason', 'bad_pin');
  end if;
  if d.host_id = v_uid then
    return jsonb_build_object('ok', false, 'reason', 'own_match');
  end if;

  update duels set status = 'cancelled', pin = null, ended_at = now(), updated_at = now()
   where host_id = v_uid and status = 'waiting';
  begin
    select g.tournament_id, g.t_ref, g.title, g.label, g.skip
      into v_tid, v_tref, v_ttitle, v_tlabel, v_tskip
      from t_game_for(d.host_id, v_uid, d.mode) g
     limit 1;
  exception when others then
    v_tid := null; v_tref := null; v_ttitle := null; v_tlabel := null; v_tskip := null;
  end;
  update duels
     set status = 'live', pin = null, guest_id = v_uid,
         guest_seeker = v_seeker, guest_terrain = v_terrain, guest_deck_id = p_deck_id,
         tournament_id = v_tid, t_ref = case when v_tid is not null then v_tref end,
         started_at = now(), updated_at = now()
   where id = d.id;

  return jsonb_build_object(
    'ok', true, 'id', d.id, 'host_id', d.host_id,
    'host_name', (select p.display_name from profiles p where p.id = d.host_id),
    'mode', d.mode, 'target', d.target,
    'host_seeker', d.host_seeker, 'host_terrain', d.host_terrain,
    'server_now', now(),
    't', case when v_tid is not null or v_tskip is not null
              then jsonb_build_object('id', v_tid, 'title', v_ttitle, 'label', v_tlabel, 'skip', v_tskip) end);
end $$;

-- duel_get: as in the MATCH TRACKER section, plus, for a tournament game,
-- t_title, t_label and t_state: 'recorded' (this match is the game's
-- result), 'kept' (the game already had a result, e.g. the organizer's),
-- 'closed' (the tournament was closed first) or 'open'.
create or replace function public.duel_get(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid   uuid := duel_caller();
  d       duels%rowtype;
  v_t     tournaments%rowtype;
  v_m     jsonb;
  v_mm    text[];
  v_a     text;
  v_b     text;
  v_w     text;
  v_state text;
  v_extra jsonb := '{}'::jsonb;
begin
  select * into d from duels x where x.id = p_id;
  if not found or (v_uid is distinct from d.host_id and v_uid is distinct from d.guest_id) then
    return null;
  end if;
  if d.tournament_id is not null then
    select * into v_t from tournaments x where x.id = d.tournament_id;
    if found then
      if d.t_ref ~ '^g:[0-9]{1,4}$' then
        v_m := v_t.payload->'gm'->(substr(d.t_ref, 3)::int);
        v_a := v_m->>'a';
        v_b := v_m->>'b';
        v_w := v_m->>'w';
      elsif d.t_ref ~ '^b:[0-9]{1,2}:[0-9]{1,4}$' then
        v_mm := regexp_match(d.t_ref, '^b:([0-9]{1,2}):([0-9]{1,4})$');
        v_m := v_t.payload->'bracket'->(v_mm[1]::int)->(v_mm[2]::int);
        v_a := v_m #>> '{a,id}';
        v_b := v_m #>> '{b,id}';
        v_w := case v_m->>'winner' when 'a' then v_a when 'b' then v_b end;
      end if;
      if not coalesce((v_a = d.host_id::text and v_b = d.guest_id::text)
                      or (v_a = d.guest_id::text and v_b = d.host_id::text), false) then
        v_w := null;
        v_m := null;
      end if;
      v_state := case
        when v_m->>'du' = d.id::text and v_m->>'src' = 'duel' then 'recorded'
        when v_w is not null then 'kept'
        when v_t.status = 'closed' then 'closed'
        else 'open' end;
      v_extra := jsonb_build_object('t_title', nullif(btrim(v_t.payload #>> '{pn,title}'), ''),
                                    't_label', t_game_label(v_t.payload, d.t_ref),
                                    't_state', v_state);
    end if;
  end if;
  return to_jsonb(d) || jsonb_build_object(
    'host_name',  (select p.display_name from profiles p where p.id = d.host_id),
    'guest_name', (select p.display_name from profiles p where p.id = d.guest_id),
    'server_now', now()) || v_extra;
end $$;

revoke all on function public.duel_join(text, text, text, uuid) from public, anon;
revoke all on function public.duel_get(uuid)                    from public, anon;
grant execute on function public.duel_join(text, text, text, uuid) to authenticated;
grant execute on function public.duel_get(uuid)                    to authenticated;

-- 8. Reading finished matches ---------------------------------------------------
-- meta_duels: as in the MATCH TRACKER section, plus in_tournament (the match
-- was a tournament game). No tournament id is given. The return type
-- changes, so the function is dropped and made again.
drop function if exists public.meta_duels(timestamptz);
create or replace function public.meta_duels(p_since timestamptz default null)
returns table (id uuid, played_at timestamptz,
               winner_seeker text, loser_seeker text,
               winner_terrain text, loser_terrain text,
               winner_deck_id uuid, loser_deck_id uuid,
               in_tournament boolean)
language sql stable security definer set search_path = public as $$
  select d.id,
         date_trunc('day', d.ended_at),
         case when d.winner_id = d.host_id then d.host_seeker  else d.guest_seeker  end,
         case when d.winner_id = d.host_id then d.guest_seeker  else d.host_seeker  end,
         case when d.winner_id = d.host_id then d.host_terrain else d.guest_terrain end,
         case when d.winner_id = d.host_id then d.guest_terrain else d.host_terrain end,
         case when wk.is_public and wp.matches_visibility = 'public' then wk.id end,
         case when lk.is_public and lp.matches_visibility = 'public' then lk.id end,
         d.tournament_id is not null
    from duels d
    join profiles wp on wp.id = d.winner_id
    join profiles lp on lp.id = d.loser_id
    left join decks wk on wk.id = case when d.winner_id = d.host_id then d.host_deck_id else d.guest_deck_id end
    left join decks lk on lk.id = case when d.winner_id = d.host_id then d.guest_deck_id else d.host_deck_id end
   where d.status = 'done'
     and (p_since is null or d.ended_at >= p_since)
   order by d.ended_at desc;
$$;
revoke all on function public.meta_duels(timestamptz) from public;
grant execute on function public.meta_duels(timestamptz) to anon, authenticated;

-- player_matches: as in the MATCH TRACKER section, but a tournament is named
-- after its Play Network event, and also shown to the two players of the
-- match (a registrant need not belong to the community).
create or replace function public.player_matches(p_user uuid)
returns table (id uuid, played_at timestamptz, opponent_id uuid, opponent_name text,
               my_seeker text, my_terrain text, opp_seeker text, opp_terrain text,
               won boolean, my_score int, opp_score int,
               tournament_id uuid, tournament_name text)
language sql stable security definer set search_path = public as $$
  with v as (
    select auth.uid() as viewer,
           auth.uid() is not null
             and not coalesce((auth.jwt()->>'is_anonymous')::boolean, false)
             and exists (select 1 from profiles vp where vp.id = auth.uid() and vp.deleted_at is null) as signed_in,
           (select p.matches_visibility from profiles p where p.id = p_user) as vis
  )
  select d.id,
         d.ended_at,
         case when s.shown then op.id end,
         case when s.shown then op.display_name
              when op.deleted_at is not null then 'Deleted player'
              else 'Private player' end,
         case when d.host_id = p_user then d.host_seeker  else d.guest_seeker  end,
         case when d.host_id = p_user then d.host_terrain else d.guest_terrain end,
         case when s.shown then case when d.host_id = p_user then d.guest_seeker  else d.host_seeker  end end,
         case when s.shown then case when d.host_id = p_user then d.guest_terrain else d.host_terrain end end,
         d.winner_id = p_user,
         case when d.winner_id = p_user then d.winner_score else d.loser_score end,
         case when d.winner_id = p_user then d.loser_score else d.winner_score end,
         case when l.is_public or is_league_member(l.id) or coalesce(v.viewer in (d.host_id, d.guest_id), false)
              then t.id end,
         case when l.is_public or is_league_member(l.id) or coalesce(v.viewer in (d.host_id, d.guest_id), false)
              then coalesce(nullif(btrim(t.payload #>> '{pn,title}'), ''),
                            nullif(btrim(t.payload->>'name'), ''),
                            l.name || ' ' || t.month) end
    from duels d
    cross join v
    join profiles op on op.id = case when d.host_id = p_user then d.guest_id else d.host_id end
    cross join lateral (
      select coalesce(v.viewer in (d.host_id, d.guest_id), false)
             or op.matches_visibility = 'public'
             or (op.matches_visibility = 'players' and v.signed_in) as shown
    ) s
    left join tournaments t on t.id = d.tournament_id
    left join leagues l on l.id = t.league_id
   where d.status = 'done'
     and p_user in (d.host_id, d.guest_id)
     and (v.viewer = p_user
          or v.viewer = d.host_id or v.viewer = d.guest_id
          or v.vis = 'public'
          or (v.vis = 'players' and v.signed_in))
   order by d.ended_at desc;
$$;
revoke all on function public.player_matches(uuid) from public;
grant execute on function public.player_matches(uuid) to anon, authenticated;

-- 9. erase_user_data(): as in the MATCH TRACKER section, plus tournaments ----
-- The account stops organizing its tournaments (the community's creator or
-- organizers can take them over), and is unlinked from every tournament it
-- plays in, closed ones included: its key becomes 'pn:<pid>' again, so the
-- player stays listed (and their results stay) under their Play Network
-- nickname only, with nothing left that ties the deleted account to that
-- nickname or profile id. A failure there never stops the deletion.
create or replace function erase_user_data(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  l record;
  v_t record;
  v_e jsonb;
  v_k text;
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
  delete from duel_join_attempts where user_id = p_user;

  update duels
     set status = 'cancelled', pin = null, ended_at = coalesce(ended_at, now()), updated_at = now()
   where status in ('waiting','live','ending') and (host_id = p_user or guest_id = p_user);

  update tournaments set organizer_id = null where organizer_id = p_user;
  begin
    for v_t in
      select x.id, x.payload
        from tournaments x
       where x.status is not null
         and x.payload->'entrants' @> jsonb_build_array(jsonb_build_object('id', p_user::text))
       order by x.created_at
       for update
    loop
      select q.x into v_e
        from jsonb_array_elements(v_t.payload->'entrants') q(x)
       where q.x->>'id' = p_user::text
       limit 1;
      v_k := case when coalesce(v_e->>'pid', '') ~ '^[A-Za-z0-9]{6,32}$'
                       and not (v_t.payload->'entrants' @> jsonb_build_array(jsonb_build_object('id', 'pn:' || (v_e->>'pid'))))
                  then 'pn:' || (v_e->>'pid') else t_rand_key(v_t.payload) end;
      update tournaments set payload = t_rekey(payload, p_user::text, v_k), rev = rev + 1 where id = v_t.id;
    end loop;
  exception when others then
    raise warning 'erase_user_data tournaments: %', sqlerrm;
  end;

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
         matches_visibility = 'private',
         deleted_at = coalesce(deleted_at, now())
   where id = p_user;
end $$;
revoke all on function erase_user_data(uuid) from public, anon, authenticated;

-- ============================================================
--  TOURNAMENT DECKS (2026-11-12)
--  Decklists are required for tournament games: duel_join tags a tournament
--  game only when both players picked a deck.
-- ============================================================

-- duel_join: as in the PLAY NETWORK TOURNAMENTS section, and a tournament
-- game is tagged only when both players picked one of their decks. If one
-- did not, the match is a plain one and the answer says t.skip = 'deck'.
create or replace function public.duel_join(p_pin text, p_seeker text, p_terrain text, p_deck_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid     uuid := duel_caller();
  v_seeker  text := duel_clean(p_seeker);
  v_terrain text := duel_clean(p_terrain);
  v_pin     text := btrim(coalesce(p_pin, ''));
  d         duels%rowtype;
  v_tid     uuid;
  v_tref    text;
  v_ttitle  text;
  v_tlabel  text;
  v_tskip   text;
begin
  if v_seeker is null or v_terrain is null then
    raise exception 'Pick your Seeker and terrain first' using errcode = '22023';
  end if;
  if p_deck_id is not null
     and not exists (select 1 from decks k where k.id = p_deck_id and k.user_id = v_uid) then
    raise exception 'Pick one of your own decks' using errcode = '42501';
  end if;
  if v_pin !~ '^[0-9]{4}$' then
    return jsonb_build_object('ok', false, 'reason', 'bad_pin');
  end if;

  perform duel_sweep();
  perform pg_advisory_xact_lock(hashtext('duel_join:' || v_uid::text));
  if (select count(*) from duel_join_attempts a
      where a.user_id = v_uid and a.created_at > now() - interval '1 minute') >= 5
     or (select count(*) from duel_join_attempts a
         where a.user_id = v_uid and a.created_at > now() - interval '1 hour') >= 20
     or (select count(*) from duel_join_attempts a
         where a.user_id = v_uid and a.created_at > now() - interval '1 day') >= 60 then
    return jsonb_build_object('ok', false, 'reason', 'rate_limited');
  end if;
  if (select count(*) from duel_join_attempts a
      where a.created_at > now() - interval '10 minutes') >= 600 then
    return jsonb_build_object('ok', false, 'reason', 'busy');
  end if;

  select * into d from duels x where x.pin = v_pin and x.status = 'waiting' for update;
  if not found or d.pin_expires_at <= now() then
    insert into duel_join_attempts (user_id) values (v_uid);
    return jsonb_build_object('ok', false, 'reason', 'bad_pin');
  end if;
  if d.host_id = v_uid then
    return jsonb_build_object('ok', false, 'reason', 'own_match');
  end if;

  update duels set status = 'cancelled', pin = null, ended_at = now(), updated_at = now()
   where host_id = v_uid and status = 'waiting';
  begin
    select g.tournament_id, g.t_ref, g.title, g.label, g.skip
      into v_tid, v_tref, v_ttitle, v_tlabel, v_tskip
      from t_game_for(d.host_id, v_uid, d.mode) g
     limit 1;
  exception when others then
    v_tid := null; v_tref := null; v_ttitle := null; v_tlabel := null; v_tskip := null;
  end;
  -- A tournament game counts only when both players picked a deck.
  if v_tid is not null and (d.host_deck_id is null or p_deck_id is null) then
    v_tid := null; v_tref := null; v_tskip := 'deck';
  end if;
  update duels
     set status = 'live', pin = null, guest_id = v_uid,
         guest_seeker = v_seeker, guest_terrain = v_terrain, guest_deck_id = p_deck_id,
         tournament_id = v_tid, t_ref = case when v_tid is not null then v_tref end,
         started_at = now(), updated_at = now()
   where id = d.id;

  return jsonb_build_object(
    'ok', true, 'id', d.id, 'host_id', d.host_id,
    'host_name', (select p.display_name from profiles p where p.id = d.host_id),
    'mode', d.mode, 'target', d.target,
    'host_seeker', d.host_seeker, 'host_terrain', d.host_terrain,
    'server_now', now(),
    't', case when v_tid is not null or v_tskip is not null
              then jsonb_build_object('id', v_tid, 'title', v_ttitle, 'label', v_tlabel, 'skip', v_tskip) end);
end $$;

-- ============================================================
--  SWISS TOURNAMENTS (2026-11-14)
-- ============================================================
-- Run as migration-2026-11-14-swiss.sql.
-- What changes:
--   * Every new Play Network tournament runs as Swiss rounds, the official
--     format (Malediction Tournament Guide): round 1 at random, then each
--     round pairs players with the same points, nobody meets the same
--     opponent twice, and the bye goes to the lowest-ranked player without
--     one. Victory 3 points, tie 2, defeat 1, bye 3 (and 20 mastery
--     differential). Standings: tournament points, then mastery
--     differential, then strength of schedule, then head to head (worked
--     out on the page). There is no top cut: the champion tops the final
--     standings. The pairings and standings are made on the organizer's
--     page; the server checks them (t_sw_* helpers) and stores them in the
--     payload (v 3, fmt 'swiss'). Earlier groups-and-finals tournaments (no
--     fmt) keep working as before and can still be finished.
--   * New organizer functions t_pair (pair the next round), t_unpair (undo
--     the last round's pairings) and t_plan (change the number of rounds).
--     t_start, t_unstart, t_result (now also a draw and both masteries),
--     t_entrant (a drop is kept with its round; bringing a player back is
--     allowed only until the next round is paired), t_fill, t_close (now
--     with the standings from the page, frozen at close), t_reopen,
--     t_create, t_game_label, t_reattach, t_record_duel and t_rekey (it
--     also moves the frozen standings) are replaced.
--     t_result, t_close and t_import gain arguments, so their old versions
--     are dropped.
--   * pn_events gains num_rounds, round_minutes and game_mode (read from
--     the official event page by the edge function). t_create copies them
--     into the tournament and refuses team (2v2) events; t_import (service
--     role only) takes them again in draft (p_meta).
--   * tournaments_v3_shape accepts fmt 'swiss' and payloads up to 1 MB.
--   * Draws in the match tracker: duels.is_draw. A player claims a draw
--     (only with equal mastery: the official draw is equal mastery when
--     time runs out) and the opponent confirms it like a win; the 48-hour
--     auto-save also saves a draw. duel_claim gains p_draw (the old
--     version is dropped; a call without it works as before); duel_answer,
--     duel_sweep and duel_notify handle draws. A finished draw has no
--     winner and no loser. In a Swiss tournament a tracked draw is recorded
--     in the game (2 points each, mastery differential 0).
--   * meta_duels and player_matches gain is_draw (a draw is a win for
--     nobody; player_matches gives won null for a draw). Their return type
--     changes, so they are dropped and made again.

-- 1. Play Network event settings ------------------------------------------------
-- Read from the official event page by the edge function play-network-event
-- (event settings only, no player data): num_rounds (the organizer's planned
-- rounds; 0 when not set), round_minutes (round length) and game_mode
-- ('1x1' or '2x2'). Hand-typed listings leave them empty.
alter table public.pn_events
  add column if not exists num_rounds    int,
  add column if not exists round_minutes int,
  add column if not exists game_mode     text;
do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'pn_events_num_rounds' and conrelid = 'public.pn_events'::regclass) then
    alter table public.pn_events add constraint pn_events_num_rounds
      check (num_rounds is null or num_rounds between 0 and 100);
  end if;
  if not exists (select 1 from pg_constraint
                 where conname = 'pn_events_round_minutes' and conrelid = 'public.pn_events'::regclass) then
    alter table public.pn_events add constraint pn_events_round_minutes
      check (round_minutes is null or round_minutes between 0 and 1440);
  end if;
  if not exists (select 1 from pg_constraint
                 where conname = 'pn_events_game_mode' and conrelid = 'public.pn_events'::regclass) then
    alter table public.pn_events add constraint pn_events_game_mode
      check (game_mode is null or game_mode in ('1x1','2x2'));
  end if;
end $$;

-- 2. tournaments: Swiss payloads -------------------------------------------------
-- A Play Network tournament is payload v 3 with fmt 'swiss' (every new one)
-- or no fmt (the earlier groups-and-finals tournaments, kept as they are).
-- Swiss rounds are appended one at a time, so the cap goes up to 1 MB.
alter table public.tournaments drop constraint if exists tournaments_v3_shape;
alter table public.tournaments add constraint tournaments_v3_shape
  check (status is null or (payload->>'v' = '3' and mode is not null
                            and (payload->>'fmt' is null or payload->>'fmt' = 'swiss')
                            and octet_length(payload::text) <= 1048576));

-- 3. Draws in the match tracker ---------------------------------------------------
-- A draw (time ran out with equal mastery) is claimed like a win and
-- confirmed by the opponent (or saved after 48 hours). While the claim waits
-- (status ending) is_draw is true and claim_winner is null; a finished draw
-- has is_draw true and no winner or loser. Both scores are the same mastery.
alter table public.duels add column if not exists is_draw boolean not null default false;
alter table public.duels drop constraint if exists duels_done_has_result;
alter table public.duels add constraint duels_done_has_result
  check (status <> 'done'
         or (not is_draw and winner_id is not null and loser_id is not null)
         or (is_draw and winner_id is null and loser_id is null));
alter table public.duels drop constraint if exists duels_draw_claimed;
alter table public.duels add constraint duels_draw_claimed
  check (not is_draw or status in ('ending','done','cancelled'));

-- Housekeeping: as in the MATCH TRACKER section, and a draw claimed and left
-- unanswered for 48 hours is saved as a draw.
create or replace function public.duel_sweep()
returns integer language plpgsql security definer set search_path = public as $$
declare
  n int := 0;
  m int;
begin
  if not pg_try_advisory_xact_lock(hashtext('duel_sweep')) then
    return 0;
  end if;
  update duels set status = 'expired', pin = null, ended_at = now(), updated_at = now()
   where status = 'waiting' and pin_expires_at <= now();
  get diagnostics m = row_count; n := n + m;
  update duels set status = 'cancelled', ended_at = now(), updated_at = now()
   where status = 'live' and updated_at < now() - interval '12 hours';
  get diagnostics m = row_count; n := n + m;
  update duels set status = 'done',
         winner_id = case when is_draw then null else claim_winner end,
         loser_id = case when is_draw then null
                         when claim_winner = host_id then guest_id else host_id end,
         ended_at = now(), updated_at = now()
   where status = 'ending' and (claim_winner is not null or is_draw)
     and coalesce(claimed_at, updated_at) < now() - interval '48 hours';
  get diagnostics m = row_count; n := n + m;
  delete from duels where status = 'expired' and created_at < now() - interval '7 days';
  delete from duels where status = 'cancelled' and created_at < now() - interval '30 days';
  delete from duel_join_attempts where created_at < now() - interval '2 days';
  return n;
end $$;
revoke all on function public.duel_sweep() from public, anon, authenticated;

-- duel_claim: as in the MATCH TRACKER section, plus p_draw. With p_draw true
-- the claim is a draw (p_winner is ignored; send null): both scores must be
-- given and equal (a draw is a tie on mastery), and the opponent confirms it
-- as a win claim (status ending). A call without p_draw works as before.
-- The argument list changes, so the old function is dropped first.
drop function if exists public.duel_claim(uuid, uuid, int, int, int, jsonb);
create or replace function public.duel_claim(p_id uuid, p_winner uuid, p_winner_score int, p_loser_score int,
                                             p_rounds int, p_state jsonb, p_draw boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  d     duels%rowtype;
begin
  if (p_winner_score is not null and p_winner_score not between 0 and 999)
     or (p_loser_score is not null and p_loser_score not between 0 and 999)
     or (p_rounds is not null and p_rounds not between 0 and 999) then
    raise exception 'Scores and rounds must be between 0 and 999' using errcode = '22023';
  end if;
  if p_state is not null and (jsonb_typeof(p_state) <> 'object' or octet_length(p_state::text) > 8192) then
    raise exception 'The match state must be a JSON object of at most 8 KB' using errcode = '22023', hint = 'too_large';
  end if;
  select * into d from duels x where x.id = p_id for update;
  if not found or (v_uid is distinct from d.host_id and v_uid is distinct from d.guest_id) then
    raise exception 'This is not one of your matches' using errcode = '42501';
  end if;
  if d.status <> 'live' then
    return jsonb_build_object('ok', false, 'status', d.status);
  end if;

  if coalesce(p_draw, false) then
    if p_winner_score is null or p_loser_score is null or p_winner_score <> p_loser_score then
      raise exception 'A draw needs the same mastery for both players' using errcode = '22023', hint = 'draw_unequal';
    end if;
    update duels
       set status = 'ending', claim_by = v_uid, claim_winner = null, is_draw = true, claimed_at = now(),
           winner_score = p_winner_score, loser_score = p_loser_score, rounds = p_rounds,
           state = coalesce(p_state, state), state_at = case when p_state is null then state_at else now() end,
           updated_at = now()
     where id = d.id;
    return jsonb_build_object('ok', true, 'status', 'ending');
  end if;

  if p_winner is null or (p_winner is distinct from d.host_id and p_winner is distinct from d.guest_id) then
    raise exception 'The winner must be one of the two players' using errcode = '22023';
  end if;

  if p_winner <> v_uid then
    update duels
       set status = 'done', claim_by = v_uid, claim_winner = p_winner, is_draw = false,
           winner_id = p_winner, loser_id = v_uid,
           winner_score = p_winner_score, loser_score = p_loser_score, rounds = p_rounds,
           state = coalesce(p_state, state), state_at = case when p_state is null then state_at else now() end,
           ended_at = now(), updated_at = now()
     where id = d.id;
    return jsonb_build_object('ok', true, 'status', 'done');
  end if;

  update duels
     set status = 'ending', claim_by = v_uid, claim_winner = v_uid, is_draw = false, claimed_at = now(),
         winner_score = p_winner_score, loser_score = p_loser_score, rounds = p_rounds,
         state = coalesce(p_state, state), state_at = case when p_state is null then state_at else now() end,
         updated_at = now()
   where id = d.id;
  return jsonb_build_object('ok', true, 'status', 'ending');
end $$;

-- duel_answer: as in the MATCH TRACKER section; accepting a draw claim
-- saves a draw (no winner or loser), and "Not right" also clears it.
create or replace function public.duel_answer(p_id uuid, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  d     duels%rowtype;
begin
  select * into d from duels x where x.id = p_id for update;
  if not found or (v_uid is distinct from d.host_id and v_uid is distinct from d.guest_id) then
    raise exception 'This is not one of your matches' using errcode = '42501';
  end if;
  if d.status <> 'ending' then
    return jsonb_build_object('ok', false, 'status', d.status);
  end if;
  if v_uid = d.claim_by then
    raise exception 'Your opponent confirms this result' using errcode = '42501';
  end if;
  if coalesce(p_accept, false) then
    update duels
       set status = 'done',
           winner_id = case when d.is_draw then null else d.claim_winner end,
           loser_id = case when d.is_draw then null
                           when d.claim_winner = d.host_id then d.guest_id else d.host_id end,
           ended_at = now(), updated_at = now()
     where id = d.id;
    return jsonb_build_object('ok', true, 'status', 'done');
  end if;
  update duels
     set status = 'live', claim_by = null, claim_winner = null, claimed_at = null, is_draw = false,
         winner_score = null, loser_score = null, rounds = null, updated_at = now()
   where id = d.id;
  return jsonb_build_object('ok', true, 'status', 'live');
end $$;

revoke all on function public.duel_claim(uuid, uuid, int, int, int, jsonb, boolean) from public, anon;
revoke all on function public.duel_answer(uuid, boolean)                            from public, anon;
grant execute on function public.duel_claim(uuid, uuid, int, int, int, jsonb, boolean) to authenticated;
grant execute on function public.duel_answer(uuid, boolean)                            to authenticated;

-- duel_notify: as in the MATCH TRACKER section, and the broadcast carries
-- is_draw (a draw claim has no claim_winner).
create or replace function public.duel_notify()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status
     or new.claim_by is distinct from old.claim_by
     or new.claim_winner is distinct from old.claim_winner
     or new.is_draw is distinct from old.is_draw
     or new.guest_id is distinct from old.guest_id then
    begin
      perform realtime.send(
        jsonb_build_object('status', new.status, 'claim_by', new.claim_by,
                           'claim_winner', new.claim_winner, 'is_draw', new.is_draw,
                           'guest_id', new.guest_id),
        'duel_status', 'duel:' || new.id::text, true);
    exception when others then
      null;
    end;
  end if;
  return null;
end $$;
revoke all on function public.duel_notify() from public, anon, authenticated;

-- 4. Swiss helpers (not callable over the API) ----------------------------------
-- The Swiss payload (v 3, fmt 'swiss'): groups is one pseudo-group holding
-- every player active at the start; rounds (planned, 1-15) and seed (the
-- round-1 shuffle, made on the organizer's page); gm is appended one round
-- at a time, in round order, and never reordered:
--   {g:0, a, b|null, w: key|'draw'|null, r, tb|null, sa?, sb? (final
--    mastery of a and b), src?: org|duel|drop|bye, du?, dx?, at?, auto?,
--    rm? (an accepted rematch)}
-- A bye is {b:null, w:a, src:'bye', tb:null}. 'draw' can never be a key.
-- Entrants gain dr: the round when they were dropped (0 before the start).
-- standings is frozen at close. No top cut: bracket stays [].

-- The current round: the highest r in gm, 0 when none.
create or replace function public.t_sw_cur(p jsonb)
returns int language sql immutable security definer set search_path = public as $$
  select coalesce(max(case when q.x->>'r' ~ '^[0-9]{1,3}$' then (q.x->>'r')::int end), 0)
    from jsonb_array_elements(case when jsonb_typeof(p->'gm') = 'array' then p->'gm' else '[]'::jsonb end) q(x);
$$;

-- The most rounds n players can play before a rematch is certain (at most 15).
create or replace function public.t_sw_max_rounds(n int)
returns int language sql immutable security definer set search_path = public as $$
  select greatest(0, least(15, case when n % 2 = 1 then n else n - 1 end));
$$;

-- The Swiss score of every player in the groups (zeros for a player with no
-- result), counting only games with a result. Per game (Malediction
-- Tournament Guide): a victory or a bye is 3 tournament points, a tie 2, a
-- defeat 1. Mastery differential (MD): the winner gets own mastery minus the
-- opponent's (never below 0; 0 when either mastery is missing), a bye or a
-- forfeit from a dropped opponent (src 'drop') gives the winner 20, a loss
-- or a draw 0. w counts victories (byes and forfeits included), d draws,
-- l defeats. It must give the same tp/w/d/l/md as swTable() on the page;
-- t_close checks the standings sent from the page against it.
-- Review fixtures (the check query below runs both):
--   S1  r1: a beats b 40-31, c draws d 25-25; r2: c beats a 40-38, b beats d
--       (no mastery entered)
--       id  tp  w  d  l  md
--       a    4  1  0  1   9
--       b    4  1  0  1   0
--       c    5  1  1  0   2
--       d    3  0  1  1   0
--   S2  r1: x beats y 40-35, z has a bye; r2: z vs x is a forfeit for z
--       (x dropped), y has a bye; then y drops too
--       id  tp  w  d  l  md
--       x    4  1  0  1   5
--       y    4  1  0  1  20
--       z    6  2  0  0  40
create or replace function public.t_sw_score(p jsonb)
returns table (id text, tp int, w int, d int, l int, md int)
language sql immutable security definer set search_path = public as $$
  with g as (
    select q.x as m
      from jsonb_array_elements(case when jsonb_typeof(p->'gm') = 'array' then p->'gm' else '[]'::jsonb end) q(x)
     where jsonb_typeof(q.x) = 'object' and q.x->>'w' is not null
  ), s as (
    select g.m->>'a' as k,
           case when g.m->>'src' = 'bye' then 'W'
                when g.m->>'w' = 'draw' then 'D'
                when g.m->>'w' = g.m->>'a' then 'W'
                else 'L' end as res,
           case when g.m->>'src' = 'bye' then 20
                when g.m->>'w' = 'draw' then 0
                when g.m->>'w' = g.m->>'a' then
                  case when g.m->>'src' = 'drop' then 20
                       when g.m->>'sa' ~ '^[0-9]{1,3}$' and g.m->>'sb' ~ '^[0-9]{1,3}$'
                         then greatest(0, (g.m->>'sa')::int - (g.m->>'sb')::int)
                       else 0 end
                else 0 end as v
      from g
    union all
    select g.m->>'b',
           case when g.m->>'w' = 'draw' then 'D'
                when g.m->>'w' = g.m->>'b' then 'W'
                else 'L' end,
           case when g.m->>'w' = 'draw' then 0
                when g.m->>'w' = g.m->>'b' then
                  case when g.m->>'src' = 'drop' then 20
                       when g.m->>'sa' ~ '^[0-9]{1,3}$' and g.m->>'sb' ~ '^[0-9]{1,3}$'
                         then greatest(0, (g.m->>'sb')::int - (g.m->>'sa')::int)
                       else 0 end
                else 0 end
      from g
     where g.m->>'b' is not null
  )
  select z.k,
         coalesce(sum(case s.res when 'W' then 3 when 'D' then 2 when 'L' then 1 end), 0)::int,
         (count(s.res) filter (where s.res = 'W'))::int,
         (count(s.res) filter (where s.res = 'D'))::int,
         (count(s.res) filter (where s.res = 'L'))::int,
         coalesce(sum(s.v), 0)::int
    from unnest(t_grouped(p)) with ordinality z(k, o)
    left join s on s.k = z.k
   group by z.k, z.o
   order by z.o;
$$;

-- The pairings of a round, made on the organizer's page: null when valid,
-- otherwise 'bad_input' or 'rematch'. p_pairs is [[keyA, keyB|null], ...]:
-- every active player exactly once, one null (the bye) when their number is
-- odd and none otherwise; the bye goes to a player who has not had one
-- while such a player is still active; and no pair has met before (any game
-- with both players, forfeits included) unless p_rematch.
create or replace function public.t_sw_pairs_ok(p jsonb, p_pairs jsonb, p_rematch boolean)
returns text language plpgsql immutable security definer set search_path = public as $$
declare
  v_act   text[] := t_active(p);
  v_gm    jsonb := case when jsonb_typeof(p->'gm') = 'array' then p->'gm' else '[]'::jsonb end;
  v_keys  text[];
  v_nulls int;
  v_bye   text;
begin
  if p_pairs is null or jsonb_typeof(p_pairs) is distinct from 'array' then
    return 'bad_input';
  end if;
  if exists (select 1 from jsonb_array_elements(p_pairs) q(x) where jsonb_typeof(q.x) <> 'array') then
    return 'bad_input';
  end if;
  if exists (select 1 from jsonb_array_elements(p_pairs) q(x) where jsonb_array_length(q.x) <> 2) then
    return 'bad_input';
  end if;
  if exists (select 1 from jsonb_array_elements(p_pairs) q(x)
              where jsonb_typeof(q.x->0) <> 'string' or jsonb_typeof(q.x->1) not in ('string','null')) then
    return 'bad_input';
  end if;
  select coalesce(array_agg(y.k #>> '{}'), '{}') into v_keys
    from jsonb_array_elements(p_pairs) q(x), jsonb_array_elements(q.x) y(k)
   where jsonb_typeof(y.k) = 'string';
  if cardinality(v_keys) <> (select count(distinct z) from unnest(v_keys) z)
     or cardinality(v_keys) <> cardinality(v_act)
     or not (v_keys <@ v_act) then
    return 'bad_input';
  end if;
  select count(*) into v_nulls from jsonb_array_elements(p_pairs) q(x) where jsonb_typeof(q.x->1) = 'null';
  if v_nulls <> cardinality(v_act) % 2 then
    return 'bad_input';
  end if;
  if v_nulls = 1 then
    select q.x->>0 into v_bye from jsonb_array_elements(p_pairs) q(x) where jsonb_typeof(q.x->1) = 'null';
    if v_gm @> jsonb_build_array(jsonb_build_object('a', v_bye, 'src', 'bye'))
       and exists (select 1 from unnest(v_act) z
                    where not (v_gm @> jsonb_build_array(jsonb_build_object('a', z, 'src', 'bye')))) then
      return 'bad_input';
    end if;
  end if;
  if not coalesce(p_rematch, false) and exists (
       select 1 from jsonb_array_elements(p_pairs) q(x), jsonb_array_elements(v_gm) g(m)
        where jsonb_typeof(q.x->1) = 'string' and g.m->>'b' is not null
          and ((g.m->>'a' = q.x->>0 and g.m->>'b' = q.x->>1)
               or (g.m->>'a' = q.x->>1 and g.m->>'b' = q.x->>0))) then
    return 'rematch';
  end if;
  return null;
end $$;

-- Round p_r appended to gm from pairings that passed t_sw_pairs_ok: a game
-- per pair, tables 1, 2, ... in the order sent (rm when the two met
-- before), and the bye decided at once (3 points, MD 20).
create or replace function public.t_sw_append(p jsonb, p_pairs jsonb, p_r int)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_gm  jsonb := case when jsonb_typeof(p->'gm') = 'array' then p->'gm' else '[]'::jsonb end;
  v_x   jsonb;
  v_tb  int := 0;
  v_met boolean;
begin
  for v_x in select q.x from jsonb_array_elements(p_pairs) with ordinality q(x, o) order by q.o loop
    if jsonb_typeof(v_x->1) = 'string' then
      v_tb := v_tb + 1;
      v_met := exists (select 1 from jsonb_array_elements(v_gm) g(m)
                        where g.m->>'b' is not null
                          and ((g.m->>'a' = v_x->>0 and g.m->>'b' = v_x->>1)
                               or (g.m->>'a' = v_x->>1 and g.m->>'b' = v_x->>0)));
      v_gm := v_gm || jsonb_build_array(
                jsonb_build_object('g', 0, 'a', v_x->0, 'b', v_x->1, 'w', null, 'r', p_r, 'tb', v_tb)
                || case when v_met then '{"rm":true}'::jsonb else '{}'::jsonb end);
    else
      v_gm := v_gm || jsonb_build_array(
                jsonb_build_object('g', 0, 'a', v_x->0, 'b', null, 'w', v_x->0, 'r', p_r, 'tb', null,
                                   'src', 'bye', 'at', now()));
    end if;
  end loop;
  return jsonb_set(p, '{gm}', v_gm);
end $$;

-- The final mastery of a tracked match on a Swiss game, as {sa, sb} for its
-- a and b sides (keys left out when not known). p_w is the match's winner
-- key, or 'draw' (both scores are the same mastery then).
create or replace function public.t_sw_duel_scores(m jsonb, p_w text, p_ws int, p_ls int)
returns jsonb language sql immutable security definer set search_path = public as $$
  select jsonb_strip_nulls(jsonb_build_object(
           'sa', case when p_w = 'draw' then p_ws when m->>'a' = p_w then p_ws else p_ls end,
           'sb', case when p_w = 'draw' then p_ls when m->>'b' = p_w then p_ws else p_ls end));
$$;

revoke all on function public.t_sw_cur(jsonb)                       from public, anon, authenticated;
revoke all on function public.t_sw_max_rounds(int)                  from public, anon, authenticated;
revoke all on function public.t_sw_score(jsonb)                     from public, anon, authenticated;
revoke all on function public.t_sw_pairs_ok(jsonb, jsonb, boolean)  from public, anon, authenticated;
revoke all on function public.t_sw_append(jsonb, jsonb, int)        from public, anon, authenticated;
revoke all on function public.t_sw_duel_scores(jsonb, text, int, int) from public, anon, authenticated;

-- 5. Tournament functions, changed ----------------------------------------------
-- "Round 2 · Table 3", "Round 2 · Bye" for a Swiss game; earlier
-- tournaments as in the PLAY NETWORK TOURNAMENTS section.
create or replace function public.t_game_label(p jsonb, p_ref text)
returns text language plpgsql immutable security definer set search_path = public as $$
declare
  v_tb int := case when p->>'tables' ~ '^[0-9]{1,3}$' then (p->>'tables')::int else 0 end;
  v_m  jsonb;
  v_mm text[];
  v_l  int;
begin
  if p_ref ~ '^g:[0-9]{1,4}$' then
    v_m := p->'gm'->(substr(p_ref, 3)::int);
    if v_m is null then
      return null;
    end if;
    if p->>'fmt' = 'swiss' then
      return case when v_m->>'r' ~ '^[0-9]{1,3}$' then 'Round ' || (v_m->>'r') else 'Round' end
          || case when v_m->>'src' = 'bye' then ' · Bye'
                  when v_m->>'tb' ~ '^[0-9]{1,3}$' then ' · Table ' || (v_m->>'tb') else '' end;
    end if;
    return case when v_m->>'r' ~ '^[0-9]{1,3}$' then 'Round ' || (v_m->>'r') else 'Group stage' end
        || case when v_tb > 0 and v_m->>'tb' ~ '^[0-9]{1,3}$' then ' · Table ' || (v_m->>'tb') else '' end;
  end if;
  v_mm := regexp_match(coalesce(p_ref, ''), '^b:([0-9]{1,2}):([0-9]{1,4})$');
  if v_mm is null or jsonb_typeof(p->'bracket') is distinct from 'array' then
    return null;
  end if;
  v_l := jsonb_array_length(p->'bracket');
  if v_mm[1]::int >= v_l or p->'bracket'->(v_mm[1]::int)->(v_mm[2]::int) is null then
    return null;
  end if;
  return t_round_name(v_l, v_mm[1]::int)
      || case when v_tb > 0 then ' · Table ' || ((v_mm[2]::int) % v_tb + 1) else '' end;
end $$;

-- Tracked matches attached again: as in the PLAY NETWORK TOURNAMENTS
-- section, plus draws and mastery. A tracked draw is attached only to a
-- Swiss game (earlier tournaments have no draws). On a Swiss game the
-- match's final mastery goes to sa/sb: always when the match gives the
-- result, and to fill missing ones when the result agrees with it. The
-- mastery is taken only from a draw or from a win claimed by its winner
-- (confirmed by the opponent or saved after 48 hours): a concession is
-- sent by the loser alone, so its masteries are left for the organizer.
create or replace function public.t_reattach(p jsonb, p_tid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_d     record;
  v_m     jsonb;
  v_i     int;
  v_mm    text[];
  v_r     int;
  v_k     int;
  v_a     text;
  v_b     text;
  v_dec   text;
  v_drops text[];
  v_sw    boolean := coalesce(p->>'fmt' = 'swiss', false);
  v_more  boolean := true;
  v_pass  int := 0;
begin
  if p is null or p_tid is null then
    return p;
  end if;
  select coalesce(array_agg(q.x->>'id'), '{}') into v_drops
    from jsonb_array_elements(coalesce(p->'entrants', '[]'::jsonb)) q(x)
   where q.x->>'st' = 'drop';
  while v_more and v_pass < 12 loop
    v_more := false;
    v_pass := v_pass + 1;
    for v_d in
      select d.id, d.t_ref, d.host_id::text as h, d.guest_id::text as g,
             case when d.is_draw then 'draw' else d.winner_id::text end as w,
             d.is_draw,
             case when d.is_draw or d.claim_by = d.winner_id then d.winner_score end as ws,
             case when d.is_draw or d.claim_by = d.winner_id then d.loser_score end as ls,
             d.ended_at
        from duels d
       where d.tournament_id = p_tid and d.status = 'done' and d.t_ref is not null
         and d.guest_id is not null and (d.winner_id is not null or d.is_draw)
       order by d.ended_at desc, d.id
    loop
      if v_d.h = any(v_drops) or v_d.g = any(v_drops) then
        continue;
      end if;
      if v_d.is_draw and not v_sw then
        continue;
      end if;
      if v_d.t_ref ~ '^g:[0-9]{1,4}$' then
        v_i := substr(v_d.t_ref, 3)::int;
        v_m := p->'gm'->v_i;
        if v_m is null or v_m->>'du' is not null then
          continue;
        end if;
        if not coalesce((v_m->>'a' = v_d.h and v_m->>'b' = v_d.g) or (v_m->>'a' = v_d.g and v_m->>'b' = v_d.h), false) then
          continue;
        end if;
        if v_m->>'w' is null then
          v_m := (v_m - 'dx') || jsonb_build_object('w', v_d.w, 'src', 'duel', 'du', v_d.id, 'at', v_d.ended_at)
                 || case when v_sw then t_sw_duel_scores(v_m, v_d.w, v_d.ws, v_d.ls) else '{}'::jsonb end;
        else
          v_m := v_m || jsonb_build_object('du', v_d.id)
                     || case when v_m->>'w' <> v_d.w then '{"dx":true}'::jsonb else '{}'::jsonb end;
          if v_sw and v_m->>'w' = v_d.w then
            v_m := t_sw_duel_scores(v_m, v_d.w, v_d.ws, v_d.ls) || v_m;
          end if;
        end if;
        p := jsonb_set(p, array['gm', v_i::text], v_m);
      elsif v_d.t_ref ~ '^b:[0-9]{1,2}:[0-9]{1,4}$' then
        if v_d.is_draw then
          continue;
        end if;
        v_mm := regexp_match(v_d.t_ref, '^b:([0-9]{1,2}):([0-9]{1,4})$');
        v_r := v_mm[1]::int;
        v_k := v_mm[2]::int;
        v_m := p->'bracket'->v_r->v_k;
        if v_m is null or jsonb_typeof(v_m) <> 'object' or v_m->>'du' is not null then
          continue;
        end if;
        v_a := v_m #>> '{a,id}';
        v_b := v_m #>> '{b,id}';
        if not coalesce((v_a = v_d.h and v_b = v_d.g) or (v_a = v_d.g and v_b = v_d.h), false) then
          continue;
        end if;
        if v_m->>'winner' is null then
          v_m := (v_m - 'dx')
                 || jsonb_build_object('winner', case when v_a = v_d.w then 'a' else 'b' end,
                                       'src', 'duel', 'du', v_d.id, 'at', v_d.ended_at);
          p := t_propagate(jsonb_set(p, array['bracket', v_r::text, v_k::text], v_m));
          v_more := true;
        else
          v_dec := case v_m->>'winner' when 'a' then v_a when 'b' then v_b end;
          v_m := v_m || jsonb_build_object('du', v_d.id)
                     || case when v_dec is distinct from v_d.w then '{"dx":true}'::jsonb else '{}'::jsonb end;
          p := jsonb_set(p, array['bracket', v_r::text, v_k::text], v_m);
        end if;
      end if;
    end loop;
  end loop;
  return p;
end $$;

-- t_record_duel: as in the PLAY NETWORK TOURNAMENTS section, plus draws and
-- mastery. A tracked draw is recorded only in a Swiss game (w 'draw', 2
-- points each, MD 0); in an earlier tournament it is left out and the
-- organizer enters the game. On a Swiss game the match's final mastery
-- goes to sa/sb when the match gives the result, and fills missing ones
-- when the organizer's result agrees with it. The mastery is taken only
-- from a draw or from a win claimed by its winner (confirmed by the
-- opponent or saved after 48 hours): a concession is sent by the loser
-- alone, and the Guide scores a forfeit from the relics anyway, so its
-- masteries are left for the organizer. Never raises.
create or replace function public.t_record_duel(p_duel uuid, p_auto boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_d    duels%rowtype;
  v_t    tournaments%rowtype;
  v_p    jsonb;
  v_m    jsonb;
  v_h    text;
  v_g    text;
  v_w    text;
  v_a    text;
  v_b    text;
  v_i    int;
  v_mm   text[];
  v_r    int;
  v_k    int;
  v_dec  text;
  v_sw   boolean;
  v_ws   int;
  v_ls   int;
  v_auto jsonb := case when coalesce(p_auto, false) then '{"auto":true}'::jsonb else '{}'::jsonb end;
begin
  begin
    select * into v_d from duels x where x.id = p_duel;
    if not found or v_d.status <> 'done' or v_d.tournament_id is null or v_d.t_ref is null
       or v_d.guest_id is null or (v_d.winner_id is null and not v_d.is_draw) then
      return;
    end if;
    select * into v_t from tournaments x where x.id = v_d.tournament_id for update;
    if not found or v_t.status is null or v_t.status not in ('running','closed') then
      return;
    end if;
    v_p := v_t.payload;
    v_sw := coalesce(v_p->>'fmt' = 'swiss', false);
    if v_d.is_draw and not v_sw then
      return;
    end if;
    v_h := v_d.host_id::text;
    v_g := v_d.guest_id::text;
    v_w := case when v_d.is_draw then 'draw' else v_d.winner_id::text end;
    if v_d.is_draw or v_d.claim_by = v_d.winner_id then
      v_ws := v_d.winner_score;
      v_ls := v_d.loser_score;
    end if;
    if exists (select 1 from jsonb_array_elements(coalesce(v_p->'entrants', '[]'::jsonb)) y(e)
                where y.e->>'id' in (v_h, v_g) and y.e->>'st' = 'drop') then
      return;
    end if;

    if v_d.t_ref ~ '^g:[0-9]{1,4}$' then
      v_i := substr(v_d.t_ref, 3)::int;
      v_m := v_p->'gm'->v_i;
      if v_m is null then
        return;
      end if;
      v_a := v_m->>'a';
      v_b := v_m->>'b';
      if not coalesce((v_a = v_h and v_b = v_g) or (v_a = v_g and v_b = v_h), false) then
        return;
      end if;
      if v_m->>'w' is null then
        if v_t.status <> 'running' then
          return;
        end if;
        v_m := (v_m - 'dx') || jsonb_build_object('w', v_w, 'src', 'duel', 'du', v_d.id, 'at', now()) || v_auto
               || case when v_sw then t_sw_duel_scores(v_m, v_w, v_ws, v_ls)
                       else '{}'::jsonb end;
      elsif v_m->>'du' is null then
        v_m := v_m || jsonb_build_object('du', v_d.id)
                   || case when v_m->>'w' <> v_w then '{"dx":true}'::jsonb else '{}'::jsonb end;
        if v_sw and v_m->>'w' = v_w then
          v_m := t_sw_duel_scores(v_m, v_w, v_ws, v_ls) || v_m;
        end if;
      else
        return;
      end if;
      v_p := jsonb_set(v_p, array['gm', v_i::text], v_m);

    elsif v_d.t_ref ~ '^b:[0-9]{1,2}:[0-9]{1,4}$' then
      if v_d.is_draw then
        return;
      end if;
      v_mm := regexp_match(v_d.t_ref, '^b:([0-9]{1,2}):([0-9]{1,4})$');
      v_r := v_mm[1]::int;
      v_k := v_mm[2]::int;
      v_m := v_p->'bracket'->v_r->v_k;
      if v_m is null then
        return;
      end if;
      v_a := v_m #>> '{a,id}';
      v_b := v_m #>> '{b,id}';
      if not coalesce((v_a = v_h and v_b = v_g) or (v_a = v_g and v_b = v_h), false) then
        return;
      end if;
      if v_m->>'winner' is null then
        if v_t.status <> 'running' then
          return;
        end if;
        v_m := (v_m - 'dx')
               || jsonb_build_object('winner', case when v_a = v_w then 'a' else 'b' end,
                                     'src', 'duel', 'du', v_d.id, 'at', now())
               || v_auto;
        v_p := t_propagate(jsonb_set(v_p, array['bracket', v_r::text, v_k::text], v_m));
      elsif v_m->>'du' is null then
        v_dec := case v_m->>'winner' when 'a' then v_a when 'b' then v_b end;
        v_m := v_m || jsonb_build_object('du', v_d.id)
                   || case when v_dec is distinct from v_w then '{"dx":true}'::jsonb else '{}'::jsonb end;
        v_p := jsonb_set(v_p, array['bracket', v_r::text, v_k::text], v_m);
      else
        return;
      end if;

    else
      return;
    end if;

    update tournaments set payload = v_p, rev = rev + 1 where id = v_t.id;
  exception when others then
    raise warning 't_record_duel: %', sqlerrm;
  end;
end $$;

-- t_rekey: as in the PLAY NETWORK TOURNAMENTS section, and the frozen
-- Swiss standings too. Every place a key sits in the payload, and only
-- those: entrants[].id, groups[][], gm[].a/b/w, bracket[][].a.id/b.id,
-- champion and standings[].id. "Remove name" (t_entrant forget) and
-- erase_user_data run it on closed tournaments, so the old key (a Play
-- Network id or an account id) must not stay behind in the standings.
create or replace function public.t_rekey(p jsonb, p_old text, p_new text)
returns jsonb language sql immutable security definer set search_path = public as $$
  select case when p is null or p_old is null or p_new is null or p_old = p_new then p else
    p
    || jsonb_build_object('entrants', coalesce((
         select jsonb_agg(case when q.x->>'id' = p_old then q.x || jsonb_build_object('id', p_new) else q.x end
                          order by q.o)
           from jsonb_array_elements(coalesce(p->'entrants', '[]'::jsonb)) with ordinality q(x, o)), '[]'::jsonb))
    || jsonb_build_object('groups', coalesce((
         select jsonb_agg(coalesce((
                  select jsonb_agg(case when y.k #>> '{}' = p_old then to_jsonb(p_new) else y.k end order by y.o)
                    from jsonb_array_elements(q.x) with ordinality y(k, o)), '[]'::jsonb) order by q.o)
           from jsonb_array_elements(coalesce(p->'groups', '[]'::jsonb)) with ordinality q(x, o)), '[]'::jsonb))
    || jsonb_build_object('gm', coalesce((
         select jsonb_agg(q.x || jsonb_strip_nulls(jsonb_build_object(
                  'a', case when q.x->>'a' = p_old then p_new end,
                  'b', case when q.x->>'b' = p_old then p_new end,
                  'w', case when q.x->>'w' = p_old then p_new end)) order by q.o)
           from jsonb_array_elements(coalesce(p->'gm', '[]'::jsonb)) with ordinality q(x, o)), '[]'::jsonb))
    || jsonb_build_object('bracket', coalesce((
         select jsonb_agg(coalesce((
                  select jsonb_agg(y.m || jsonb_strip_nulls(jsonb_build_object(
                           'a', case when y.m #>> '{a,id}' = p_old then jsonb_build_object('id', p_new) end,
                           'b', case when y.m #>> '{b,id}' = p_old then jsonb_build_object('id', p_new) end))
                           order by y.o)
                    from jsonb_array_elements(q.x) with ordinality y(m, o)), '[]'::jsonb) order by q.o)
           from jsonb_array_elements(coalesce(p->'bracket', '[]'::jsonb)) with ordinality q(x, o)), '[]'::jsonb))
    || case when p->>'champion' = p_old then jsonb_build_object('champion', p_new) else '{}'::jsonb end
    || case when jsonb_typeof(p->'standings') = 'array' then jsonb_build_object('standings', coalesce((
         select jsonb_agg(case when q.x->>'id' = p_old then q.x || jsonb_build_object('id', p_new) else q.x end
                          order by q.o)
           from jsonb_array_elements(p->'standings') with ordinality q(x, o)), '[]'::jsonb))
       else '{}'::jsonb end
  end;
$$;

-- t_create: as in the PLAY NETWORK TOURNAMENTS section, and the listing's
-- settings go to pn: rounds (num_rounds 1-100), system ('Swiss' or
-- 'League'), minutes (round length 1-1440) and gmode ('1x1' or '2x2'),
-- null when not known. A team (2v2) event is refused.
create or replace function public.t_create(p_pn_event uuid, p_mode text default 'clash')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  v_e   pn_events%rowtype;
  v_id  uuid;
begin
  if p_mode is null or p_mode not in ('clash','demo') then
    return t_no('bad_input', 'A tournament plays Clash or Demo.');
  end if;
  select * into v_e from pn_events x where x.id = p_pn_event;
  if not found
     or ((v_e.created_by is distinct from v_uid or not coalesce(is_league_admin(v_e.league_id), false))
         and not coalesce(is_site_admin(), false)) then
    return t_no('not_allowed', 'Only the organizer who linked this event can run it as a tournament.');
  end if;
  if not v_e.fetch_ok then
    return t_no('bad_input', 'Refresh this event from the Play Network first.');
  end if;
  if v_e.game_mode = '2x2' then
    return t_no('bad_input', 'Team (2v2) events cannot be run as a tournament here yet.');
  end if;
  if exists (select 1 from leagues l where l.id = v_e.league_id and l.archived_at is not null) then
    return t_no('archived', 'This community is archived.');
  end if;
  select x.id into v_id from tournaments x where x.pn_event_id = v_e.id;
  if v_id is not null then
    return t_no('duplicate', 'This event already has a tournament.') || jsonb_build_object('id', v_id);
  end if;
  begin
    insert into tournaments (league_id, month, payload, created_by, pn_event_id, organizer_id, status, mode, rev)
    values (v_e.league_id,
            to_char(coalesce(v_e.starts_at, now()) at time zone 'UTC', 'YYYY-MM'),
            jsonb_build_object('v', 3,
                               'pn', jsonb_build_object(
                                       'id', v_e.pn_id, 'url', v_e.url, 'title', v_e.title,
                                       'rounds', case when v_e.num_rounds between 1 and 100 then v_e.num_rounds end,
                                       'system', case when v_e.format in ('Swiss','League') then v_e.format end,
                                       'minutes', case when v_e.round_minutes between 1 and 1440 then v_e.round_minutes end,
                                       'gmode', case when v_e.game_mode in ('1x1','2x2') then v_e.game_mode end),
                               'entrants', '[]'::jsonb, 'groups', '[]'::jsonb, 'gm', '[]'::jsonb,
                               'tables', 0, 'bracket', '[]'::jsonb, 'finalized', false),
            v_uid, v_e.id, v_uid, 'draft', p_mode, 0)
    returning id into v_id;
  exception when unique_violation then
    select x.id into v_id from tournaments x where x.pn_event_id = v_e.id;
    return t_no('duplicate', 'This event already has a tournament.') || jsonb_build_object('id', v_id);
  end;
  return jsonb_build_object('ok', true, 'id', v_id, 'rev', 0);
end $$;

-- t_entrant: as in the PLAY NETWORK TOURNAMENTS section, plus:
--   drop      before the start, and in a Swiss tournament, also stores dr,
--             the current round (0 before the start). The player's
--             undecided game of the current round goes to the opponent
--             (src 'drop': 3 points and MD 20 for the opponent, a defeat
--             for the dropped player); past results stay, and the player
--             is never paired again
--   undrop    in a running Swiss tournament, only while no round has been
--             paired since the drop (dr not below the current round); the
--             forfeit is undone
create or replace function public.t_entrant(p_tid uuid, p_rev int, p_op text, p_key text default null,
                                            p_name text default null, p_link text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := duel_caller();
  v_no   jsonb;
  v_t    tournaments%rowtype;
  v_p    jsonb;
  v_e    jsonb;
  v_i    int;
  v_raw  text;
  v_pid  text;
  v_key  text;
  v_n    int;
  v_rev  int;
begin
  if p_op is null or p_op not in ('drop','undrop','add','remove','unlink','relink','forget') then
    return t_no('bad_input', 'This change is not known.');
  end if;
  v_no := t_lock(p_tid, p_rev, p_op = 'forget');
  if v_no is not null then
    return v_no;
  end if;
  select * into v_t from tournaments x where x.id = p_tid;
  v_p := v_t.payload;

  if p_op <> 'add' then
    select q.o - 1, q.x into v_i, v_e
      from jsonb_array_elements(coalesce(v_p->'entrants', '[]'::jsonb)) with ordinality q(x, o)
     where q.x->>'id' = p_key
     limit 1;
    if v_e is null then
      return t_no('bad_input', 'This player is not in the list.');
    end if;
  end if;
  if p_op in ('drop','undrop','unlink','relink') and v_t.status = 'closed' then
    return t_no('status', 'The tournament is closed. Reopen it first.');
  end if;
  if p_op in ('add','remove') and v_t.status <> 'draft' then
    return t_no('status', 'The tournament has started, so its list of players is fixed.');
  end if;

  if p_op = 'drop' then
    if v_e->>'st' = 'drop' then
      return jsonb_build_object('ok', true, 'rev', v_t.rev);
    end if;
    v_p := jsonb_set(v_p, array['entrants', v_i::text, 'st'], '"drop"'::jsonb);
    if v_t.status = 'draft' or v_p->>'fmt' = 'swiss' then
      v_p := jsonb_set(v_p, array['entrants', v_i::text, 'dr'], to_jsonb(t_sw_cur(v_p)));
    end if;
    if v_t.status = 'running' then
      v_p := t_forfeits(v_p);
      if not t_r0_empty(v_p) then
        v_p := t_propagate(v_p);
      end if;
    end if;

  elsif p_op = 'undrop' then
    if v_e->>'st' is distinct from 'drop' then
      return jsonb_build_object('ok', true, 'rev', v_t.rev);
    end if;
    if v_t.status = 'running' then
      if not t_r0_empty(v_p) then
        return t_no('finals_drawn', 'The finals are drawn; this player stays dropped.');
      end if;
      if not (p_key = any(t_grouped(v_p))) then
        return t_no('status', 'This player was dropped before the start, so they are not in the draw.');
      end if;
      if v_p->>'fmt' = 'swiss'
         and coalesce(case when v_e->>'dr' ~ '^[0-9]{1,3}$' then (v_e->>'dr')::int end, 0) < t_sw_cur(v_p) then
        return t_no('status', 'Round ' || t_sw_cur(v_p) || ' is already paired without this player, so they stay dropped.');
      end if;
    end if;
    v_p := jsonb_set(v_p, array['entrants', v_i::text], ((v_p->'entrants'->v_i) - 'dr') || '{"st":"in"}'::jsonb);
    if v_t.status = 'running' then
      v_p := t_forfeits(v_p);
    end if;

  elsif p_op = 'add' then
    v_raw := btrim(regexp_replace(coalesce(p_name, ''), '[[:cntrl:]]', '', 'g'));
    if char_length(v_raw) not between 1 and 40 then
      return t_no('bad_input', 'A name has 1 to 40 characters.');
    end if;
    if jsonb_array_length(coalesce(v_p->'entrants', '[]'::jsonb)) >= 256 then
      return t_no('bad_input', 'A tournament has at most 256 players.');
    end if;
    if nullif(btrim(coalesce(p_link, '')), '') is not null then
      v_pid := mg_public_id(p_link);
      if v_pid is null then
        return t_no('bad_input', 'Paste the address of a malediction.gg profile, like https://malediction.gg/app/profile/AbC123xYz0/');
      end if;
      if coalesce(v_p->'entrants' @> jsonb_build_array(jsonb_build_object('pid', v_pid)), false)
         or coalesce(v_p->'entrants' @> jsonb_build_array(jsonb_build_object('id', 'pn:' || v_pid)), false) then
        return t_no('duplicate', 'This player is already in the list.');
      end if;
      v_key := 'pn:' || v_pid;
    else
      v_key := t_rand_key(v_p);
    end if;
    v_p := jsonb_set(v_p, '{entrants}', coalesce(v_p->'entrants', '[]'::jsonb) || jsonb_build_array(
             jsonb_build_object('id', v_key, 'name', v_raw, 'pid', v_pid, 'src', 'hand', 'st', 'in',
                                'seeker', '', 'terrain', '', 'deck', '', 'deckId', '')));
    if v_pid is not null then
      select q.r into v_p from t_link_all(v_p) q;
    end if;

  elsif p_op = 'remove' then
    if v_e->>'src' is distinct from 'hand' then
      return t_no('bad_input', 'Only players you added can be removed. Drop a registered player instead.');
    end if;
    v_p := jsonb_set(v_p, '{entrants}', (v_p->'entrants') - v_i);

  elsif p_op = 'unlink' then
    v_p := jsonb_set(v_p, array['entrants', v_i::text, 'lock'], 'true'::jsonb);
    if t_acct(v_e->>'id') then
      v_key := case when coalesce(v_e->>'pid', '') ~ '^[A-Za-z0-9]{6,32}$' then 'pn:' || (v_e->>'pid')
                    else t_rand_key(v_p) end;
      v_p := t_rekey(v_p, v_e->>'id', v_key);
    end if;

  elsif p_op = 'relink' then
    v_p := jsonb_set(v_p, array['entrants', v_i::text], (v_p->'entrants'->v_i) - 'lock');
    if v_e->>'pid' is not null then
      delete from tournament_marks
       where tournament_id = p_tid and kind = 'lock' and pid_hash = t_pid_hash(p_tid, v_e->>'pid');
    end if;
    select q.r into v_p from t_link_all(v_p, case when v_t.status = 'draft' then '*' else p_key end) q;

  elsif p_op = 'forget' then
    -- The entrant moves to the end of the list, so its place no longer
    -- matches the official page, and is named after a counter (fx).
    v_pid := v_e->>'pid';
    v_n := coalesce(case when v_p->>'fx' ~ '^[0-9]{1,4}$' then (v_p->>'fx')::int end, 0) + 1;
    v_e := (v_e - 'wait') || jsonb_build_object('name', 'Player ' || v_n, 'pid', null, 'lock', true);
    v_p := jsonb_set(v_p - 'nx', '{entrants}', ((v_p->'entrants') - v_i) || jsonb_build_array(v_e))
           || jsonb_build_object('fx', v_n);
    if v_pid is not null then
      insert into tournament_marks (tournament_id, pid_hash, kind)
      values (p_tid, t_pid_hash(p_tid, v_pid), 'forget')
      on conflict do nothing;
    end if;
    if p_key !~ '^h:' then
      v_p := t_rekey(v_p, p_key, t_rand_key(v_p));
    end if;
  end if;

  update tournaments set payload = v_p, rev = rev + 1 where id = p_tid returning rev into v_rev;
  return jsonb_build_object('ok', true, 'rev', v_rev);
end $$;

-- t_start: draft only, and every tournament now starts as Swiss rounds (a
-- page that sends anything else is told to reload). p_engine is
-- {fmt:'swiss', rounds, seed, pairs}, made on the organizer's page:
--   * 3 to 256 active players (st 'in'); they form the one pseudo-group, in
--     the order of the list;
--   * rounds 1 to t_sw_max_rounds(players);
--   * seed 0 to 4294967295 (the round-1 shuffle, kept for reference);
--   * pairs: round 1, checked by t_sw_pairs_ok. Round 1 is paired at random
--     on the page; the server checks the structure only.
-- No top cut: a cut other than 0 is refused, and none is stored.
create or replace function public.t_start(p_tid uuid, p_rev int, p_mode text, p_engine jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := duel_caller();
  v_no     jsonb;
  v_bad    jsonb := t_no('bad_input', 'The draw is not valid. Reload the tournament and try again.');
  v_t      tournaments%rowtype;
  v_p      jsonb;
  v_act    text[];
  v_n      int;
  v_rounds int;
  v_seed   bigint;
  v_rev    int;
begin
  v_no := t_lock(p_tid, p_rev);
  if v_no is not null then
    return v_no;
  end if;
  select * into v_t from tournaments x where x.id = p_tid;
  if v_t.status <> 'draft' then
    return t_no('status', 'The tournament has already started.');
  end if;
  if p_mode is null or p_mode not in ('clash','demo') then
    return t_no('bad_input', 'A tournament plays Clash or Demo.');
  end if;
  if p_engine is null or jsonb_typeof(p_engine) is distinct from 'object' then
    return v_bad;
  end if;
  if p_engine->>'fmt' is distinct from 'swiss' then
    return t_no('bad_input', 'Reload the page: tournaments now run as Swiss rounds.');
  end if;
  v_p := v_t.payload;
  select coalesce(array_agg(q.x->>'id' order by q.o), '{}') into v_act
    from jsonb_array_elements(coalesce(v_p->'entrants', '[]'::jsonb)) with ordinality q(x, o)
   where q.x->>'st' = 'in';
  v_n := cardinality(v_act);
  if v_n < 3 then
    return t_no('bad_input', 'At least 3 players are needed to start.');
  end if;
  if v_n > 256 then
    return t_no('bad_input', 'A tournament has at most 256 players.');
  end if;

  -- rounds
  if jsonb_typeof(p_engine->'rounds') is distinct from 'number' or (p_engine->>'rounds') !~ '^[0-9]{1,3}$' then
    return v_bad;
  end if;
  v_rounds := (p_engine->>'rounds')::int;
  if v_rounds < 1 or v_rounds > t_sw_max_rounds(v_n) then
    return t_no('bad_input', 'With ' || v_n || ' players a tournament plays 1 to ' || t_sw_max_rounds(v_n) || ' rounds.');
  end if;
  -- no top cut
  if coalesce(p_engine->>'cut', '0') <> '0' then
    return t_no('bad_input', 'There is no top cut: the champion tops the Swiss standings. Reload the page.');
  end if;
  -- the round-1 seed
  if jsonb_typeof(p_engine->'seed') is distinct from 'number' or (p_engine->>'seed') !~ '^[0-9]{1,10}$'
     or (p_engine->>'seed')::bigint > 4294967295 then
    return v_bad;
  end if;
  v_seed := (p_engine->>'seed')::bigint;

  -- round 1
  v_p := (v_p - 'champion' - 'finalized_at' - 'standings' - 'cut')
         || jsonb_build_object('fmt', 'swiss', 'groups', jsonb_build_array(to_jsonb(v_act)), 'gm', '[]'::jsonb,
                               'tables', 0, 'rounds', v_rounds, 'seed', v_seed,
                               'bracket', '[]'::jsonb, 'finalized', false);
  if t_sw_pairs_ok(v_p, p_engine->'pairs', false) is not null then
    return t_no('bad_input', 'The round 1 pairings are not valid. Reload the tournament and try again.');
  end if;
  v_p := t_sw_append(v_p, p_engine->'pairs', 1);
  if octet_length(v_p::text) > 1048576 then
    return t_no('bad_input', 'This tournament is too large.');
  end if;
  update tournaments set payload = v_p, status = 'running', mode = p_mode, rev = rev + 1
   where id = p_tid returning rev into v_rev;
  return jsonb_build_object('ok', true, 'rev', v_rev);
end $$;

-- t_unstart: as in the PLAY NETWORK TOURNAMENTS section; the Swiss settings
-- (fmt, rounds, seed, standings) go too, and each player's dr.
create or replace function public.t_unstart(p_tid uuid, p_rev int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  v_no  jsonb;
  v_t   tournaments%rowtype;
  v_rev int;
begin
  select * into v_t from tournaments x where x.id = p_tid;
  if not found or v_t.status is null or not t_is_org(v_t) then
    return t_no('not_allowed', 'Only the organizer of this tournament can change it.');
  end if;
  begin
    update duels set tournament_id = null, t_ref = null where tournament_id = p_tid;
    v_no := t_lock(p_tid, p_rev);
    if v_no is null then
      select * into v_t from tournaments x where x.id = p_tid;
      if v_t.status <> 'running' then
        v_no := t_no('status', 'The tournament has not started.');
      elsif t_has_results(v_t.payload) then
        v_no := t_no('has_results', 'Results are already in, so the tournament cannot go back to registration.');
      end if;
    end if;
    if v_no is not null then
      raise exception 't_unstart refused' using errcode = 'SL001';
    end if;
    update tournaments
       set payload = (payload - 'fmt' - 'rounds' - 'cut' - 'seed' - 'standings')
                     || jsonb_build_object('groups', '[]'::jsonb, 'gm', '[]'::jsonb, 'tables', 0,
                                           'bracket', '[]'::jsonb, 'finalized', false,
                                           'entrants', coalesce((
                                             select jsonb_agg(q.x - 'dr' order by q.o)
                                               from jsonb_array_elements(coalesce(payload->'entrants', '[]'::jsonb))
                                                    with ordinality q(x, o)), '[]'::jsonb)),
           status = 'draft', rev = rev + 1
     where id = p_tid returning rev into v_rev;
  exception when sqlstate 'SL001' then
    return v_no;
  end;
  return jsonb_build_object('ok', true, 'rev', v_rev);
end $$;

-- t_result: as in the PLAY NETWORK TOURNAMENTS section, plus a Swiss branch
-- for 'g:<i>' and the mastery p_sa/p_sb (0-999 or null) of the game's a
-- and b players:
--   * a bye cannot be changed;
--   * p_winner null (clear), 'a'/'b', one of the two keys, or 'draw'. A
--     draw is a tie on mastery: two different masteries are refused, and
--     a kept mastery that differs from the other goes;
--   * setting a result: src 'org', at; given masteries replace sa/sb, the
--     others stay; dx when the linked tracked match says otherwise;
--   * clearing removes the result and the masteries, and is refused for a
--     game of an earlier round (the next round is already paired: enter
--     the corrected result instead) and for a game with a dropped player
--     (it would stay open and hold up the next round, or a forfeit
--     would come back at once);
--   * no bracket: p_round0 is ignored.
-- 'draw' and masteries are refused in the earlier tournaments. The
-- argument list changes, so the old function is dropped first.
drop function if exists public.t_result(uuid, int, text, text, jsonb);
create or replace function public.t_result(p_tid uuid, p_rev int, p_ref text, p_winner text,
                                           p_round0 jsonb default null, p_sa int default null,
                                           p_sb int default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := duel_caller();
  v_no   jsonb;
  v_t    tournaments%rowtype;
  v_p    jsonb;
  v_m    jsonb;
  v_i    int;
  v_mm   text[];
  v_r    int;
  v_k    int;
  v_w    text;
  v_side text;
  v_dw   text;
  v_sw   boolean;
  v_cur  int;
  v_r0   jsonb := case when jsonb_typeof(p_round0) = 'array' then p_round0 end;
  v_rev  int;
begin
  v_no := t_lock(p_tid, p_rev);
  if v_no is not null then
    return v_no;
  end if;
  select * into v_t from tournaments x where x.id = p_tid;
  if v_t.status = 'closed' then
    return t_no('status', 'The tournament is closed. Reopen it to change results.');
  end if;
  if v_t.status <> 'running' then
    return t_no('status', 'The tournament has not started.');
  end if;
  v_p := v_t.payload;
  v_sw := coalesce(v_p->>'fmt' = 'swiss', false);
  if not v_sw and (p_winner = 'draw' or p_sa is not null or p_sb is not null) then
    return t_no('bad_input', 'Draws and mastery are entered only in Swiss tournaments. Reload the page.');
  end if;
  if (p_sa is not null and p_sa not between 0 and 999) or (p_sb is not null and p_sb not between 0 and 999) then
    return t_no('bad_input', 'Mastery is a number from 0 to 999.');
  end if;

  if v_sw and p_ref ~ '^g:[0-9]{1,4}$' then
    v_i := substr(p_ref, 3)::int;
    v_m := v_p->'gm'->v_i;
    if v_m is null or jsonb_typeof(v_m) <> 'object' then
      return t_no('bad_input', 'This game is not in the tournament.');
    end if;
    if v_m->>'src' = 'bye' or v_m->>'b' is null then
      return t_no('bad_input', 'A bye cannot be changed.');
    end if;
    v_w := case when p_winner is null then null
                when p_winner = 'draw' then 'draw'
                when p_winner = 'a' or p_winner = v_m->>'a' then v_m->>'a'
                when p_winner = 'b' or p_winner = v_m->>'b' then v_m->>'b' end;
    if p_winner is not null and v_w is null then
      return t_no('bad_input', 'The winner must be one of the two players.');
    end if;
    if v_w is null then
      v_cur := t_sw_cur(v_p);
      if coalesce(case when v_m->>'r' ~ '^[0-9]{1,3}$' then (v_m->>'r')::int end, 0) < v_cur then
        return t_no('status', 'Round ' || v_cur || ' is already paired. Enter the corrected result instead of clearing it.');
      end if;
      if exists (select 1 from jsonb_array_elements(coalesce(v_p->'entrants', '[]'::jsonb)) y(e)
                  where y.e->>'id' in (v_m->>'a', v_m->>'b') and y.e->>'st' = 'drop') then
        return t_no('bad_input', 'A player in this game has dropped, so its result cannot be cleared. Enter the corrected result instead.');
      end if;
      v_m := (v_m - 'src' - 'at' - 'auto' - 'dx' - 'sa' - 'sb') || '{"w":null}'::jsonb;
    else
      if v_w = 'draw' and p_sa is not null and p_sb is not null and p_sa <> p_sb then
        return t_no('bad_input', 'A draw is a tie on mastery: enter the same mastery for both players.');
      end if;
      v_m := (v_m - 'auto' - 'dx') || jsonb_build_object('w', v_w, 'src', 'org', 'at', now())
             || jsonb_strip_nulls(jsonb_build_object('sa', p_sa, 'sb', p_sb));
      if v_w = 'draw' and v_m->>'sa' is not null and v_m->>'sb' is not null and v_m->>'sa' <> v_m->>'sb' then
        if p_sa is null then
          v_m := v_m - 'sa';
        end if;
        if p_sb is null then
          v_m := v_m - 'sb';
        end if;
      end if;
      if v_m->>'du' is not null then
        select case when d.is_draw then 'draw' else d.winner_id::text end into v_dw
          from duels d where d.id = (v_m->>'du')::uuid and d.status = 'done';
        if v_dw is not null and v_dw <> v_w then
          v_m := v_m || '{"dx":true}'::jsonb;
        end if;
      end if;
    end if;
    v_p := jsonb_set(v_p, array['gm', v_i::text], v_m);

  elsif p_ref ~ '^g:[0-9]{1,4}$' then
    v_i := substr(p_ref, 3)::int;
    v_m := v_p->'gm'->v_i;
    if v_m is null then
      return t_no('bad_input', 'This game is not in the tournament.');
    end if;
    v_w := case when p_winner is null then null
                when p_winner = 'a' or p_winner = v_m->>'a' then v_m->>'a'
                when p_winner = 'b' or p_winner = v_m->>'b' then v_m->>'b' end;
    if p_winner is not null and v_w is null then
      return t_no('bad_input', 'The winner must be one of the two players.');
    end if;
    if v_w is null then
      v_m := (v_m - 'src' - 'at' - 'auto' - 'dx') || '{"w":null}'::jsonb;
    else
      v_m := (v_m - 'auto' - 'dx') || jsonb_build_object('w', v_w, 'src', 'org', 'at', now());
      if v_m->>'du' is not null then
        select d.winner_id::text into v_dw from duels d where d.id = (v_m->>'du')::uuid and d.status = 'done';
        if v_dw is not null and v_dw <> v_w then
          v_m := v_m || '{"dx":true}'::jsonb;
        end if;
      end if;
    end if;
    v_p := jsonb_set(v_p, array['gm', v_i::text], v_m);
    if t_gm_done(v_p) then
      if v_r0 is not null then
        if not t_round0_ok(v_p, v_r0) then
          return t_no('bad_input', 'The finals draw is not valid. Reload the tournament and try again.');
        end if;
        v_p := t_place_round0(v_p, v_r0);
      elsif not t_r0_empty(v_p) then
        return t_no('round0_needed', 'The finals have to be drawn again. Reload the tournament and try again.');
      end if;
    else
      v_p := t_clear_bracket(v_p);
    end if;

  elsif p_ref ~ '^b:[0-9]{1,2}:[0-9]{1,4}$' then
    v_mm := regexp_match(p_ref, '^b:([0-9]{1,2}):([0-9]{1,4})$');
    v_r := v_mm[1]::int;
    v_k := v_mm[2]::int;
    v_m := v_p->'bracket'->v_r->v_k;
    if v_m is null or v_m #>> '{a,id}' is null or v_m #>> '{b,id}' is null then
      return t_no('bad_input', 'This finals match does not have both players yet.');
    end if;
    v_side := case when p_winner is null then null
                   when p_winner = 'a' or p_winner = v_m #>> '{a,id}' then 'a'
                   when p_winner = 'b' or p_winner = v_m #>> '{b,id}' then 'b' end;
    if p_winner is not null and v_side is null then
      return t_no('bad_input', 'The winner must be one of the two players.');
    end if;
    if v_side is null then
      v_m := (v_m - 'src' - 'at' - 'auto' - 'dx') || '{"winner":null}'::jsonb;
    else
      v_m := (v_m - 'auto' - 'dx') || jsonb_build_object('winner', v_side, 'src', 'org', 'at', now());
      if v_m->>'du' is not null then
        select d.winner_id::text into v_dw from duels d where d.id = (v_m->>'du')::uuid and d.status = 'done';
        if v_dw is not null and v_dw <> (v_m #>> array[v_side, 'id']) then
          v_m := v_m || '{"dx":true}'::jsonb;
        end if;
      end if;
    end if;
    v_p := t_propagate(jsonb_set(v_p, array['bracket', v_r::text, v_k::text], v_m));

  else
    return t_no('bad_input', 'This game is not in the tournament.');
  end if;

  v_p := t_reattach(v_p, p_tid);
  update tournaments set payload = v_p, rev = rev + 1 where id = p_tid returning rev into v_rev;
  return jsonb_build_object('ok', true, 'rev', v_rev);
end $$;

-- t_fill: as in the PLAY NETWORK TOURNAMENTS section, for the earlier
-- tournaments only: a Swiss tournament has no finals.
create or replace function public.t_fill(p_tid uuid, p_rev int, p_round0 jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  v_no  jsonb;
  v_t   tournaments%rowtype;
  v_rev int;
begin
  v_no := t_lock(p_tid, p_rev);
  if v_no is not null then
    return v_no;
  end if;
  select * into v_t from tournaments x where x.id = p_tid;
  if v_t.status <> 'running' then
    return t_no('status', 'The tournament is not running.');
  end if;
  if v_t.payload->>'fmt' = 'swiss' then
    return t_no('status', 'A Swiss tournament has no finals: the champion tops the standings.');
  end if;
  if not t_gm_done(v_t.payload) then
    return t_no('status', 'The group stage is not finished yet.');
  end if;
  if not t_r0_empty(v_t.payload) then
    return t_no('finals_drawn', 'The finals are already drawn.');
  end if;
  if not t_round0_ok(v_t.payload, p_round0) then
    return t_no('bad_input', 'The finals draw is not valid. Reload the tournament and try again.');
  end if;
  update tournaments set payload = t_reattach(t_place_round0(payload, p_round0), p_tid), rev = rev + 1
   where id = p_tid returning rev into v_rev;
  return jsonb_build_object('ok', true, 'rev', v_rev);
end $$;

-- t_close: closed and finalized. A Swiss tournament needs p_standings, the
-- standings made on the page (swTable): one row {id, rk, tp, w, d, l, md,
-- sos, drop} per player in the groups, best first. They are checked against
-- the results (t_sw_score: tp, w, d, l, md), the order (tp, then md, never
-- going up), the ranks (1 first; each row the rank of the row above, only
-- when tp and md are the same, or its own place) and the drops, then frozen
-- in the payload (standings). The champion is the first player not
-- dropped, unless another player not dropped shares that rank (no
-- champion then). Closing before the last round is allowed: the standings
-- count the results entered so far. The earlier tournaments close as
-- before (the final's winner). The argument list changes, so the old
-- function is dropped first.
drop function if exists public.t_close(uuid, int);
create or replace function public.t_close(p_tid uuid, p_rev int, p_standings jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid   uuid := duel_caller();
  v_no    jsonb;
  v_t     tournaments%rowtype;
  v_p     jsonb;
  v_fin   jsonb;
  v_ch    text;
  v_rev   int;
  v_bad   jsonb := t_no('bad_input', 'The standings do not match the results. Reload the page and close again.');
  v_ids   text[];
  v_drops text[];
  v_score jsonb;
  v_row   jsonb;
  v_prev  jsonb;
  v_i     int := 0;
  v_rk    int;
  v_rows  jsonb := '[]'::jsonb;
begin
  v_no := t_lock(p_tid, p_rev);
  if v_no is not null then
    return v_no;
  end if;
  select * into v_t from tournaments x where x.id = p_tid;
  if v_t.status <> 'running' then
    return t_no('status', 'Only a running tournament can be closed.');
  end if;
  v_p := v_t.payload;

  if v_p->>'fmt' = 'swiss' then
    if p_standings is null or jsonb_typeof(p_standings) is distinct from 'array' then
      return t_no('bad_input', 'Reload the page and close again.');
    end if;
    v_ids := t_grouped(v_p);
    if jsonb_array_length(p_standings) <> cardinality(v_ids)
       or (select count(distinct q.x->>'id') from jsonb_array_elements(p_standings) q(x)) <> cardinality(v_ids) then
      return v_bad;
    end if;
    select coalesce(array_agg(q.x->>'id'), '{}') into v_drops
      from jsonb_array_elements(coalesce(v_p->'entrants', '[]'::jsonb)) q(x)
     where q.x->>'st' = 'drop';
    select jsonb_object_agg(s.id, jsonb_build_array(s.tp, s.w, s.d, s.l, s.md)) into v_score
      from t_sw_score(v_p) s;
    for v_row in select q.x from jsonb_array_elements(p_standings) with ordinality q(x, o) order by q.o loop
      if jsonb_typeof(v_row) is distinct from 'object'
         or jsonb_typeof(v_row->'id') is distinct from 'string'
         or jsonb_typeof(v_row->'drop') is distinct from 'boolean' then
        return v_bad;
      end if;
      if exists (select 1 from unnest(array['rk','tp','w','d','l','md','sos']) f
                  where jsonb_typeof(v_row->f) is distinct from 'number' or (v_row->>f) !~ '^[0-9]{1,7}$') then
        return v_bad;
      end if;
      if not ((v_row->>'id') = any(v_ids))
         or jsonb_build_array((v_row->>'tp')::int, (v_row->>'w')::int, (v_row->>'d')::int,
                              (v_row->>'l')::int, (v_row->>'md')::int) is distinct from v_score->(v_row->>'id')
         or (v_row->'drop' = 'true'::jsonb) <> ((v_row->>'id') = any(v_drops)) then
        return v_bad;
      end if;
      v_rk := (v_row->>'rk')::int;
      if v_i = 0 then
        if v_rk <> 1 then
          return v_bad;
        end if;
      else
        if (v_row->>'tp')::int > (v_prev->>'tp')::int
           or ((v_row->>'tp')::int = (v_prev->>'tp')::int and (v_row->>'md')::int > (v_prev->>'md')::int) then
          return v_bad;
        end if;
        if v_rk = (v_prev->>'rk')::int then
          if (v_row->>'tp')::int <> (v_prev->>'tp')::int or (v_row->>'md')::int <> (v_prev->>'md')::int then
            return v_bad;
          end if;
        elsif v_rk <> v_i + 1 then
          return v_bad;
        end if;
      end if;
      v_rows := v_rows || jsonb_build_array(jsonb_build_object(
                  'id', v_row->>'id', 'rk', v_rk, 'tp', (v_row->>'tp')::int, 'w', (v_row->>'w')::int,
                  'd', (v_row->>'d')::int, 'l', (v_row->>'l')::int, 'md', (v_row->>'md')::int,
                  'sos', (v_row->>'sos')::int, 'drop', v_row->'drop'));
      v_prev := v_row;
      v_i := v_i + 1;
    end loop;
    select q.x->>'id', (q.x->>'rk')::int into v_ch, v_rk
      from jsonb_array_elements(v_rows) with ordinality q(x, o)
     where q.x->'drop' = 'false'::jsonb
     order by q.o
     limit 1;
    if v_ch is not null and (select count(*) from jsonb_array_elements(v_rows) q(x)
                              where q.x->'drop' = 'false'::jsonb and (q.x->>'rk')::int = v_rk) > 1 then
      v_ch := null;
    end if;
    update tournaments
       set payload = (payload - 'champion')
                     || jsonb_build_object('finalized', true, 'finalized_at', now(), 'standings', v_rows)
                     || case when v_ch is not null then jsonb_build_object('champion', v_ch) else '{}'::jsonb end,
           status = 'closed', rev = rev + 1
     where id = p_tid returning rev into v_rev;
    return jsonb_build_object('ok', true, 'rev', v_rev);
  end if;

  if jsonb_typeof(v_p->'bracket') = 'array' and jsonb_array_length(v_p->'bracket') > 0 then
    v_fin := v_p->'bracket'->(jsonb_array_length(v_p->'bracket') - 1)->0;
    v_ch := case v_fin->>'winner' when 'a' then v_fin #>> '{a,id}' when 'b' then v_fin #>> '{b,id}' end;
  end if;
  update tournaments
     set payload = (payload - 'champion')
                   || jsonb_build_object('finalized', true, 'finalized_at', now())
                   || case when v_ch is not null then jsonb_build_object('champion', v_ch) else '{}'::jsonb end,
         status = 'closed', rev = rev + 1
   where id = p_tid returning rev into v_rev;
  return jsonb_build_object('ok', true, 'rev', v_rev);
end $$;

-- t_reopen: as in the PLAY NETWORK TOURNAMENTS section; the frozen
-- standings go too.
create or replace function public.t_reopen(p_tid uuid, p_rev int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  v_no  jsonb;
  v_t   tournaments%rowtype;
  v_rev int;
begin
  v_no := t_lock(p_tid, p_rev);
  if v_no is not null then
    return v_no;
  end if;
  select * into v_t from tournaments x where x.id = p_tid;
  if v_t.status <> 'closed' then
    return t_no('status', 'The tournament is not closed.');
  end if;
  update tournaments
     set payload = (payload - 'champion' - 'finalized_at' - 'standings') || '{"finalized":false}'::jsonb,
         status = 'running', rev = rev + 1
   where id = p_tid returning rev into v_rev;
  return jsonb_build_object('ok', true, 'rev', v_rev);
end $$;

-- t_import: as in the PLAY NETWORK TOURNAMENTS section, plus p_meta, the
-- event settings read by the edge function: {rounds, system, minutes,
-- game_mode (or gmode)}. In draft they replace pn.rounds (1-100; 0 or
-- anything else is null), pn.system ('Swiss' or 'League', else null),
-- pn.minutes (1-1440, else null) and pn.gmode ('1x1' or '2x2', else null).
-- Without p_meta pn keeps them. The argument list changes, so the old
-- function is dropped first.
drop function if exists public.t_import(uuid, jsonb, int);
create or replace function public.t_import(p_tid uuid, p_regs jsonb, p_count int, p_meta jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_t       tournaments%rowtype;
  v_p       jsonb;
  v_reg     jsonb;
  v_regs    jsonb := '[]'::jsonb;
  v_seen    text[] := '{}';
  v_pid     text;
  v_name    text;
  v_full    boolean;
  v_ents    jsonb := '[]'::jsonb;
  v_e       jsonb;
  v_added   int := 0;
  v_removed int := 0;
  v_linked  int;
  v_warn    text;
  v_meta    jsonb := '{}'::jsonb;
  v_gmode   text;
  v_rev     int;
begin
  if p_tid is null or p_regs is null or jsonb_typeof(p_regs) is distinct from 'array' then
    return t_no('bad_input', 'The list of players is not valid.');
  end if;
  select * into v_t from tournaments x where x.id = p_tid for update;
  if not found or v_t.status is null then
    return t_no('not_allowed', 'This tournament was not found.');
  end if;
  if v_t.status <> 'draft' then
    return t_no('started', 'The tournament has started, so its list of players is fixed.');
  end if;
  if exists (select 1 from leagues l where l.id = v_t.league_id and l.archived_at is not null) then
    return t_no('archived', 'This community is archived.');
  end if;
  v_p := v_t.payload - 'nx';

  -- the event settings
  if jsonb_typeof(p_meta) = 'object' then
    v_gmode := coalesce(p_meta->>'game_mode', p_meta->>'gmode');
    v_meta := jsonb_build_object(
      'rounds', case when coalesce(p_meta->>'rounds', '') ~ '^[0-9]{1,3}$'
                          and (p_meta->>'rounds')::int between 1 and 100 then (p_meta->>'rounds')::int end,
      'system', case when p_meta->>'system' in ('Swiss','League') then p_meta->>'system' end,
      'minutes', case when coalesce(p_meta->>'minutes', '') ~ '^[0-9]{1,4}$'
                           and (p_meta->>'minutes')::int between 1 and 1440 then (p_meta->>'minutes')::int end,
      'gmode', case when v_gmode in ('1x1','2x2') then v_gmode end);
  end if;

  -- the registrants: valid public ids, each once
  for v_reg in select q.x from jsonb_array_elements(p_regs) with ordinality q(x, o) order by q.o limit 1000 loop
    if jsonb_typeof(v_reg) is distinct from 'object' then
      continue;
    end if;
    v_pid := v_reg->>'pid';
    if v_pid is null or v_pid !~ '^[A-Za-z0-9]{6,32}$' or v_pid = any(v_seen) then
      continue;
    end if;
    v_seen := v_seen || v_pid;
    v_name := coalesce(t_clean_name(v_reg->>'name'), 'Player');
    v_regs := v_regs || jsonb_build_array(jsonb_build_object('pid', v_pid, 'name', v_name));
  end loop;
  v_full := p_count is not null and p_count = cardinality(v_seen);

  -- the players already in the list
  for v_e in select q.x from jsonb_array_elements(coalesce(v_p->'entrants', '[]'::jsonb)) with ordinality q(x, o) order by q.o loop
    if v_e->>'src' = 'pn' and v_e->>'pid' is not null then
      if not (v_e->>'pid' = any(v_seen)) then
        if not v_full then
          v_ents := v_ents || jsonb_build_array(v_e);
          continue;
        end if;
        if (v_e->>'lock') = 'true' then
          insert into tournament_marks (tournament_id, pid_hash, kind)
          values (p_tid, t_pid_hash(p_tid, v_e->>'pid'), 'lock')
          on conflict do nothing;
        end if;
        v_removed := v_removed + 1;
        continue;
      end if;
      v_e := v_e || jsonb_build_object('name', (select z.x->>'name' from jsonb_array_elements(v_regs) z(x)
                                                 where z.x->>'pid' = v_e->>'pid' limit 1));
    end if;
    v_ents := v_ents || jsonb_build_array(v_e);
  end loop;

  -- the new registrants
  for v_reg in select q.x from jsonb_array_elements(v_regs) with ordinality q(x, o) order by q.o loop
    if v_ents @> jsonb_build_array(jsonb_build_object('pid', v_reg->>'pid')) then
      continue;
    end if;
    if exists (select 1 from tournament_marks k
                where k.tournament_id = p_tid and k.kind = 'forget'
                  and k.pid_hash = t_pid_hash(p_tid, v_reg->>'pid')) then
      continue;
    end if;
    if jsonb_array_length(v_ents) >= 256 then
      v_warn := 'too_many';
      exit;
    end if;
    v_ents := v_ents || jsonb_build_array(jsonb_build_object(
                'id', 'pn:' || (v_reg->>'pid'), 'name', v_reg->>'name', 'pid', v_reg->>'pid',
                'src', 'pn', 'st', 'in', 'seeker', '', 'terrain', '', 'deck', '', 'deckId', '')
                || case when exists (select 1 from tournament_marks k
                                      where k.tournament_id = p_tid and k.kind = 'lock'
                                        and k.pid_hash = t_pid_hash(p_tid, v_reg->>'pid'))
                        then '{"lock":true}'::jsonb else '{}'::jsonb end);
    v_added := v_added + 1;
  end loop;

  v_p := jsonb_set(v_p, '{entrants}', v_ents);
  select q.r, q.linked into v_p, v_linked from t_link_all(v_p) q;
  v_p := jsonb_set(v_p, '{pn}', coalesce(v_p->'pn', '{}'::jsonb)
                                || jsonb_build_object('at', now(),
                                                      'n', case when p_count between 0 and 100000 then p_count end)
                                || v_meta);
  update tournaments set payload = v_p, rev = rev + 1 where id = p_tid returning rev into v_rev;
  return jsonb_build_object('ok', true, 'rev', v_rev, 'total', cardinality(v_seen),
                            'added', v_added, 'removed', v_removed, 'linked', v_linked)
         || case when v_warn is not null then jsonb_build_object('warning', v_warn) else '{}'::jsonb end;
end $$;

-- 6. Swiss rounds: the organizer's new functions --------------------------------
-- Refusals answer {ok:false, reason, message} as the other t_* functions,
-- with the new reasons rematch, round_open and rounds_done (and busy for
-- t_unpair). Success answers {ok:true, rev}.

-- t_pair: the next round, paired on the organizer's page (swNextPairs) and
-- checked here (t_sw_pairs_ok): p_round must be the next round (else
-- stale), within the planned rounds, every game of the current round must
-- have a result, at least 2 players must still be in, and a rematch needs
-- p_rematch (the page found no pairing without one).
create or replace function public.t_pair(p_tid uuid, p_rev int, p_round int, p_pairs jsonb, p_rematch boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := duel_caller();
  v_no     jsonb;
  v_t      tournaments%rowtype;
  v_p      jsonb;
  v_cur    int;
  v_rounds int;
  v_why    text;
  v_rev    int;
begin
  v_no := t_lock(p_tid, p_rev);
  if v_no is not null then
    return v_no;
  end if;
  select * into v_t from tournaments x where x.id = p_tid;
  if v_t.status <> 'running' then
    return t_no('status', 'The tournament is not running.');
  end if;
  v_p := v_t.payload;
  if v_p->>'fmt' is distinct from 'swiss' then
    return t_no('status', 'Only a Swiss tournament is paired round by round.');
  end if;
  v_cur := t_sw_cur(v_p);
  v_rounds := case when v_p->>'rounds' ~ '^[0-9]{1,3}$' then (v_p->>'rounds')::int else 0 end;
  if p_round is distinct from v_cur + 1 then
    return t_no('stale', 'The tournament changed on another device. It has been reloaded; check it and try again.')
           || jsonb_build_object('rev', v_t.rev);
  end if;
  if p_round > v_rounds then
    return t_no('rounds_done', 'All ' || v_rounds || ' rounds are paired.');
  end if;
  if not t_gm_done(v_p) then
    return t_no('round_open', 'Round ' || v_cur || ' still has games without a result.');
  end if;
  if cardinality(t_active(v_p)) < 2 then
    return t_no('bad_input', 'At least 2 players must still be in to pair a round.');
  end if;
  v_why := t_sw_pairs_ok(v_p, p_pairs, p_rematch);
  if v_why = 'rematch' then
    return t_no('rematch', 'This pairing has a rematch. Reload and pair again.');
  elsif v_why is not null then
    return t_no('bad_input', 'These pairings are not valid. Reload the tournament and pair again.');
  end if;
  v_p := t_sw_append(v_p, p_pairs, p_round);
  if octet_length(v_p::text) > 1048576 then
    return t_no('bad_input', 'This tournament is too large.');
  end if;
  update tournaments set payload = v_p, rev = rev + 1 where id = p_tid returning rev into v_rev;
  return jsonb_build_object('ok', true, 'rev', v_rev);
end $$;

-- t_unpair: the last round's pairings undone (round 2 or later; round 1 goes
-- with t_unstart), while no game of that round has a result entered or
-- recorded (forfeits and the bye do not count) and no tracked match of it
-- is being played or waiting for confirmation (busy). Finished or
-- cancelled tracked matches tagged with its games become plain matches
-- first (lock order: match, then tournament; undone if the tournament
-- refuses), since the next pairing reuses the game positions. Players
-- dropped during that round keep dr, so they can be brought back.
create or replace function public.t_unpair(p_tid uuid, p_rev int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := duel_caller();
  v_no   jsonb;
  v_t    tournaments%rowtype;
  v_r    int;
  v_refs text[];
  v_rev  int;
begin
  select * into v_t from tournaments x where x.id = p_tid;
  if not found or v_t.status is null or not t_is_org(v_t) then
    return t_no('not_allowed', 'Only the organizer of this tournament can change it.');
  end if;
  v_r := t_sw_cur(v_t.payload);
  select coalesce(array_agg('g:' || (q.o - 1)), '{}') into v_refs
    from jsonb_array_elements(coalesce(v_t.payload->'gm', '[]'::jsonb)) with ordinality q(x, o)
   where q.x->>'r' = v_r::text;
  begin
    update duels set tournament_id = null, t_ref = null
     where tournament_id = p_tid and t_ref = any(v_refs) and status not in ('live','ending');
    v_no := t_lock(p_tid, p_rev);
    if v_no is null then
      select * into v_t from tournaments x where x.id = p_tid;
      if v_t.status <> 'running' then
        v_no := t_no('status', 'The tournament is not running.');
      elsif v_t.payload->>'fmt' is distinct from 'swiss' then
        v_no := t_no('status', 'Only the rounds of a Swiss tournament can be undone.');
      elsif t_sw_cur(v_t.payload) <> v_r then
        v_no := t_no('stale', 'The tournament changed on another device. It has been reloaded; check it and try again.')
                || jsonb_build_object('rev', v_t.rev);
      elsif v_r < 2 then
        v_no := t_no('status', 'Use Back to registration to undo round 1.');
      elsif exists (select 1 from jsonb_array_elements(v_t.payload->'gm') q(x)
                     where q.x->>'r' = v_r::text and q.x->>'src' in ('org','duel')) then
        v_no := t_no('has_results', 'Round ' || v_r || ' already has results, so its pairings cannot be undone. Clear them first.');
      elsif exists (select 1 from duels d
                     where d.tournament_id = p_tid and d.t_ref = any(v_refs) and d.status in ('live','ending')) then
        v_no := t_no('busy', 'A tracked match of round ' || v_r || ' is being played or waits for confirmation. Try again when it has ended.');
      end if;
    end if;
    if v_no is not null then
      raise exception 't_unpair refused' using errcode = 'SL001';
    end if;
    update tournaments
       set payload = jsonb_set(payload, '{gm}', coalesce((
                       select jsonb_agg(q.x order by q.o)
                         from jsonb_array_elements(payload->'gm') with ordinality q(x, o)
                        where (q.x->>'r') is distinct from v_r::text), '[]'::jsonb)),
           rev = rev + 1
     where id = p_tid returning rev into v_rev;
  exception when sqlstate 'SL001' then
    return v_no;
  end;
  return jsonb_build_object('ok', true, 'rev', v_rev);
end $$;

-- t_plan: the planned number of rounds changed while running, from the
-- current round (at least 1) to t_sw_max_rounds(players). There is no top
-- cut: p_cut is accepted only as 0 or null (it may be left out).
create or replace function public.t_plan(p_tid uuid, p_rev int, p_rounds int, p_cut int default 0)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  v_no  jsonb;
  v_t   tournaments%rowtype;
  v_p   jsonb;
  v_min int;
  v_max int;
  v_rev int;
begin
  v_no := t_lock(p_tid, p_rev);
  if v_no is not null then
    return v_no;
  end if;
  select * into v_t from tournaments x where x.id = p_tid;
  if v_t.status <> 'running' then
    return t_no('status', 'The tournament is not running.');
  end if;
  v_p := v_t.payload;
  if v_p->>'fmt' is distinct from 'swiss' then
    return t_no('status', 'Only a Swiss tournament has a number of rounds to change.');
  end if;
  if coalesce(p_cut, 0) <> 0 then
    return t_no('bad_input', 'There is no top cut: the champion tops the Swiss standings. Reload the page.');
  end if;
  v_min := greatest(1, t_sw_cur(v_p));
  v_max := t_sw_max_rounds(cardinality(t_grouped(v_p)));
  if p_rounds is null or p_rounds < v_min or p_rounds > v_max then
    return t_no('bad_input', 'Choose ' || v_min || ' to ' || v_max || ' rounds.');
  end if;
  update tournaments set payload = payload || jsonb_build_object('rounds', p_rounds), rev = rev + 1
   where id = p_tid returning rev into v_rev;
  return jsonb_build_object('ok', true, 'rev', v_rev);
end $$;

revoke all on function public.t_create(uuid, text)                                   from public, anon;
revoke all on function public.t_entrant(uuid, int, text, text, text, text)           from public, anon;
revoke all on function public.t_start(uuid, int, text, jsonb)                        from public, anon;
revoke all on function public.t_unstart(uuid, int)                                   from public, anon;
revoke all on function public.t_result(uuid, int, text, text, jsonb, int, int)       from public, anon;
revoke all on function public.t_fill(uuid, int, jsonb)                               from public, anon;
revoke all on function public.t_close(uuid, int, jsonb)                              from public, anon;
revoke all on function public.t_reopen(uuid, int)                                    from public, anon;
revoke all on function public.t_pair(uuid, int, int, jsonb, boolean)                 from public, anon;
revoke all on function public.t_unpair(uuid, int)                                    from public, anon;
revoke all on function public.t_plan(uuid, int, int, int)                            from public, anon;
revoke all on function public.t_import(uuid, jsonb, int, jsonb)                      from public, anon, authenticated;
revoke all on function public.t_game_label(jsonb, text)                              from public, anon, authenticated;
revoke all on function public.t_reattach(jsonb, uuid)                                from public, anon, authenticated;
revoke all on function public.t_record_duel(uuid, boolean)                           from public, anon, authenticated;
revoke all on function public.t_rekey(jsonb, text, text)                             from public, anon, authenticated;
grant execute on function public.t_create(uuid, text)                                to authenticated;
grant execute on function public.t_entrant(uuid, int, text, text, text, text)        to authenticated;
grant execute on function public.t_start(uuid, int, text, jsonb)                     to authenticated;
grant execute on function public.t_unstart(uuid, int)                                to authenticated;
grant execute on function public.t_result(uuid, int, text, text, jsonb, int, int)    to authenticated;
grant execute on function public.t_fill(uuid, int, jsonb)                            to authenticated;
grant execute on function public.t_close(uuid, int, jsonb)                           to authenticated;
grant execute on function public.t_reopen(uuid, int)                                 to authenticated;
grant execute on function public.t_pair(uuid, int, int, jsonb, boolean)              to authenticated;
grant execute on function public.t_unpair(uuid, int)                                 to authenticated;
grant execute on function public.t_plan(uuid, int, int, int)                         to authenticated;
grant execute on function public.t_import(uuid, jsonb, int, jsonb)                   to service_role;

-- 7. Reading finished matches: draws -------------------------------------------
-- meta_duels: as in the PLAY NETWORK TOURNAMENTS section, plus is_draw. A
-- draw is a win for nobody: its "winner" columns are the host and its
-- "loser" columns the guest, and is_draw is true. The return type changes,
-- so the function is dropped and made again.
drop function if exists public.meta_duels(timestamptz);
create or replace function public.meta_duels(p_since timestamptz default null)
returns table (id uuid, played_at timestamptz,
               winner_seeker text, loser_seeker text,
               winner_terrain text, loser_terrain text,
               winner_deck_id uuid, loser_deck_id uuid,
               in_tournament boolean, is_draw boolean)
language sql stable security definer set search_path = public as $$
  select d.id,
         date_trunc('day', d.ended_at),
         case when x.wh then d.host_seeker  else d.guest_seeker  end,
         case when x.wh then d.guest_seeker  else d.host_seeker  end,
         case when x.wh then d.host_terrain else d.guest_terrain end,
         case when x.wh then d.guest_terrain else d.host_terrain end,
         case when wk.is_public and wp.matches_visibility = 'public' then wk.id end,
         case when lk.is_public and lp.matches_visibility = 'public' then lk.id end,
         d.tournament_id is not null,
         d.is_draw
    from duels d
    cross join lateral (select d.is_draw or d.winner_id = d.host_id as wh) x
    join profiles wp on wp.id = case when x.wh then d.host_id else d.guest_id end
    join profiles lp on lp.id = case when x.wh then d.guest_id else d.host_id end
    left join decks wk on wk.id = case when x.wh then d.host_deck_id else d.guest_deck_id end
    left join decks lk on lk.id = case when x.wh then d.guest_deck_id else d.host_deck_id end
   where d.status = 'done'
     and (p_since is null or d.ended_at >= p_since)
   order by d.ended_at desc;
$$;
revoke all on function public.meta_duels(timestamptz) from public;
grant execute on function public.meta_duels(timestamptz) to anon, authenticated;

-- player_matches: as in the PLAY NETWORK TOURNAMENTS section, plus is_draw;
-- won is null for a draw (both scores are the same mastery then). The
-- return type changes, so the function is dropped and made again.
drop function if exists public.player_matches(uuid);
create or replace function public.player_matches(p_user uuid)
returns table (id uuid, played_at timestamptz, opponent_id uuid, opponent_name text,
               my_seeker text, my_terrain text, opp_seeker text, opp_terrain text,
               won boolean, my_score int, opp_score int,
               tournament_id uuid, tournament_name text, is_draw boolean)
language sql stable security definer set search_path = public as $$
  with v as (
    select auth.uid() as viewer,
           auth.uid() is not null
             and not coalesce((auth.jwt()->>'is_anonymous')::boolean, false)
             and exists (select 1 from profiles vp where vp.id = auth.uid() and vp.deleted_at is null) as signed_in,
           (select p.matches_visibility from profiles p where p.id = p_user) as vis
  )
  select d.id,
         d.ended_at,
         case when s.shown then op.id end,
         case when s.shown then op.display_name
              when op.deleted_at is not null then 'Deleted player'
              else 'Private player' end,
         case when d.host_id = p_user then d.host_seeker  else d.guest_seeker  end,
         case when d.host_id = p_user then d.host_terrain else d.guest_terrain end,
         case when s.shown then case when d.host_id = p_user then d.guest_seeker  else d.host_seeker  end end,
         case when s.shown then case when d.host_id = p_user then d.guest_terrain else d.host_terrain end end,
         case when d.is_draw then null else d.winner_id = p_user end,
         case when d.winner_id = p_user then d.winner_score else d.loser_score end,
         case when d.winner_id = p_user then d.loser_score else d.winner_score end,
         case when l.is_public or is_league_member(l.id) or coalesce(v.viewer in (d.host_id, d.guest_id), false)
              then t.id end,
         case when l.is_public or is_league_member(l.id) or coalesce(v.viewer in (d.host_id, d.guest_id), false)
              then coalesce(nullif(btrim(t.payload #>> '{pn,title}'), ''),
                            nullif(btrim(t.payload->>'name'), ''),
                            l.name || ' ' || t.month) end,
         d.is_draw
    from duels d
    cross join v
    join profiles op on op.id = case when d.host_id = p_user then d.guest_id else d.host_id end
    cross join lateral (
      select coalesce(v.viewer in (d.host_id, d.guest_id), false)
             or op.matches_visibility = 'public'
             or (op.matches_visibility = 'players' and v.signed_in) as shown
    ) s
    left join tournaments t on t.id = d.tournament_id
    left join leagues l on l.id = t.league_id
   where d.status = 'done'
     and p_user in (d.host_id, d.guest_id)
     and (v.viewer = p_user
          or v.viewer = d.host_id or v.viewer = d.guest_id
          or v.vis = 'public'
          or (v.vis = 'players' and v.signed_in))
   order by d.ended_at desc;
$$;
revoke all on function public.player_matches(uuid) from public;
grant execute on function public.player_matches(uuid) to anon, authenticated;

-- ============================================================
--  TOURNAMENT AUTOMATION (2026-11-15)
-- ============================================================
-- Run as migration-2026-11-15-tournament-auto.sql.
-- What changes:
--   * Deck once. A player with a linked account registers one of their
--     decks for a Swiss tournament (t_deck_set, read back with t_deck_get),
--     like the official deck list. The copy is kept in the new table
--     tournament_decks, which nobody reads directly: card lists never
--     leave the server. Before the start the player can change it; at the
--     start it is refreshed from the deck and locked; a player who
--     registers after the start is locked at once. While the tournament is
--     in registration or running, the Seeker and terrain are shown only to
--     its organizer (and to the player). When it closes they are written
--     into the players of the payload, so everyone who can see the
--     tournament sees them; reopening hides them again.
--   * Tournament games without a PIN. t_duel_start makes an invitation
--     (duels.t_invite, no PIN, 30 minutes, refreshed while the host's page
--     is open) for the caller's game of the current round, with the
--     registered deck; the opponent accepts it with t_duel_accept. If both
--     start at once, the second one joins the first. t_inbox lists the
--     caller's invitations (the polling fallback). The private Realtime
--     topic user:<account id> carries 'invite', 'invite_end' and
--     'tournament' (a round paired, a status change) to that account only.
--   * Automatic pairing and close. The edge function tournament-auto runs
--     the page's own Swiss engine and calls t_auto_pair or t_auto_close
--     (service role only), after t_auto_allow (as the caller: the
--     organizer or a player). Both lock the row and check rev, so each
--     round is paired once. Undoing a round's pairings pauses automatic
--     pairing for that round (payload.hold.pair) until the organizer pairs
--     it; reopening stops the automatic close (payload.hold.close)
--     and pauses the pairing of the next round (hold.pair), so the
--     organizer decides what happens after a reopen. t_auto_allow has
--     hourly brakes (t_auto_log), like t_fetch_allow.
--     payload.auto {r} marks a round paired automatically and payload.ac a
--     tournament closed automatically.
--   * Changed: t_close's Swiss part moves to t_sw_close_apply (the same
--     checks and answers); t_game_for leaves Swiss tournaments out, so a
--     PIN match is a casual one there; t_unpair and t_unstart leave
--     invitations tagged (the trigger cancels them); t_rekey clears the
--     moved player's seeker, terrain, deck and deckId; t_live_duels also
--     lists invitations; erase_user_data deletes the registrations;
--     meta_duels and player_matches leave out the matches of a Swiss
--     tournament still in registration or running (its Seekers and
--     terrains are the organizer's until the close).
--     Earlier groups-and-finals tournaments are not touched by any of it.

-- 1. duels: tournament invitations -------------------------------------------
-- An invitation is a waiting match with no PIN, made by t_duel_start for a
-- Swiss game: t_invite is true, guest_id is the opponent (who may read the
-- row, as any guest), tournament_id and t_ref are set, and pin_expires_at
-- is 30 minutes ahead, so duel_sweep expires it like a PIN. Only the guest
-- can accept it (t_duel_accept); either player can cancel it (duel_cancel).
-- duel_open and duel_join cancel the caller's own waiting matches, so an
-- invitation the caller made is withdrawn when they start or join another
-- match. tournament_id is not required: it is set null when the tournament
-- is deleted, and t_duel_accept then answers 'gone'. There is no unique
-- index on (tournament_id, t_ref): the tournament row lock is what keeps
-- one open match per game.
alter table public.duels add column if not exists t_invite boolean not null default false;
alter table public.duels drop constraint if exists duels_pin_only_waiting;
alter table public.duels add constraint duels_pin_only_waiting
  check ((pin is not null) = (status = 'waiting' and not t_invite));
alter table public.duels drop constraint if exists duels_invite_guest;
alter table public.duels add constraint duels_invite_guest
  check (not t_invite or guest_id is not null);

-- 2. tournament_decks: the deck each player registered ------------------------
-- One row per player (an account) and tournament: a copy of the deck as it
-- was registered (refreshed at the start), locked from the start
-- (locked_at). deck_id goes null when the deck is deleted; the copy stays.
-- RLS on and no policies: it is read and written only by the functions
-- below, so card lists never reach a page. erase_user_data deletes a
-- player's rows.
create table if not exists public.tournament_decks (
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  user_id       uuid not null references public.profiles(id) on delete cascade,
  deck_id       uuid references public.decks(id) on delete set null,
  name          text not null default '',
  seeker        text not null,
  terrain       text not null,
  cards         jsonb not null,
  side          jsonb,
  registered_at timestamptz not null default now(),
  locked_at     timestamptz,
  primary key (tournament_id, user_id)
);
create index if not exists idx_tournament_decks_user on public.tournament_decks(user_id);
create index if not exists idx_tournament_decks_deck on public.tournament_decks(deck_id);
alter table public.tournament_decks enable row level security;
revoke all on public.tournament_decks from anon, authenticated;

-- t_auto_log: the asks t_auto_allow let through, for its hourly brakes.
-- Only an account id and a time, kept two days (t_auto_allow purges it,
-- erase_user_data deletes an account's rows). Nobody reads it directly.
create table if not exists public.t_auto_log (
  id         bigint generated always as identity primary key,
  user_id    uuid not null,
  created_at timestamptz not null default now()
);
create index if not exists idx_t_auto_log_user on public.t_auto_log(user_id, created_at);
create index if not exists idx_t_auto_log_at on public.t_auto_log(created_at);
alter table public.t_auto_log enable row level security;
revoke all on public.t_auto_log from anon, authenticated;

-- 3. Helpers (not callable over the API) ---------------------------------------
-- The caller's game in the current round of a Swiss payload, for
-- t_duel_start: i (its index in gm) and opp (the opponent's key), or why:
-- 'not_entrant', 'dropped', 'no_game' (no undecided game with an opponent
-- in this round, or the opponent dropped) or 'opp_no_account' (i and opp
-- are then set).
create or replace function public.t_my_game(p jsonb, p_me text, out i int, out opp text, out why text)
language plpgsql immutable security definer set search_path = public as $$
declare
  v_e   jsonb;
  v_cur int := t_sw_cur(p);
begin
  select q.x into v_e
    from jsonb_array_elements(case when jsonb_typeof(p->'entrants') = 'array' then p->'entrants' else '[]'::jsonb end) q(x)
   where q.x->>'id' = p_me
   limit 1;
  if v_e is null then
    why := 'not_entrant';
    return;
  end if;
  if v_e->>'st' = 'drop' then
    why := 'dropped';
    return;
  end if;
  select q.o - 1, case when q.x->>'a' = p_me then q.x->>'b' else q.x->>'a' end
    into i, opp
    from jsonb_array_elements(case when jsonb_typeof(p->'gm') = 'array' then p->'gm' else '[]'::jsonb end) with ordinality q(x, o)
   where jsonb_typeof(q.x) = 'object'
     and q.x->>'r' = v_cur::text and q.x->>'w' is null and q.x->>'b' is not null
     and p_me in (q.x->>'a', q.x->>'b')
   order by q.o
   limit 1;
  if i is null then
    why := 'no_game';
    return;
  end if;
  if exists (select 1 from jsonb_array_elements(p->'entrants') q(x)
              where q.x->>'id' = opp and q.x->>'st' = 'drop') then
    i := null;
    opp := null;
    why := 'no_game';
    return;
  end if;
  if not t_acct(opp) then
    why := 'opp_no_account';
  end if;
end $$;

-- An invitation still matches an open game: p is a Swiss payload, p_ref is
-- 'g:<i>', that game is in the current round with no result and is between
-- the two accounts (either way round), and neither of them dropped.
create or replace function public.t_invite_ok(p jsonb, p_ref text, p_host uuid, p_guest uuid)
returns boolean language plpgsql immutable security definer set search_path = public as $$
declare
  v_m jsonb;
  v_h text := p_host::text;
  v_g text := p_guest::text;
begin
  if p is null or p->>'fmt' is distinct from 'swiss' or p_ref is null or p_ref !~ '^g:[0-9]{1,4}$'
     or v_h is null or v_g is null or jsonb_typeof(p->'gm') is distinct from 'array' then
    return false;
  end if;
  v_m := p->'gm'->(substr(p_ref, 3)::int);
  if v_m is null or jsonb_typeof(v_m) <> 'object' or v_m->>'w' is not null or v_m->>'b' is null then
    return false;
  end if;
  if v_m->>'r' is distinct from t_sw_cur(p)::text then
    return false;
  end if;
  if not coalesce((v_m->>'a' = v_h and v_m->>'b' = v_g) or (v_m->>'a' = v_g and v_m->>'b' = v_h), false) then
    return false;
  end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p->'entrants', '[]'::jsonb)) y(e)
              where y.e->>'id' in (v_h, v_g) and y.e->>'st' = 'drop') then
    return false;
  end if;
  return true;
end $$;

-- The players of a payload with their seeker and terrain emptied: they
-- stay hidden while the tournament is in registration or running.
create or replace function public.t_deck_hide(p jsonb)
returns jsonb language sql immutable security definer set search_path = public as $$
  select case when jsonb_typeof(p->'entrants') is distinct from 'array' then p else
    p || jsonb_build_object('entrants', coalesce((
           select jsonb_agg(case when jsonb_typeof(q.x) = 'object'
                                 then q.x || '{"seeker":"","terrain":""}'::jsonb else q.x end
                            order by q.o)
             from jsonb_array_elements(p->'entrants') with ordinality q(x, o)), '[]'::jsonb))
  end;
$$;

-- The players of a payload with the Seeker and terrain of their registered
-- deck (empty when they registered none), written at close. Never the
-- deck's name or cards.
create or replace function public.t_deck_pub(p jsonb, p_tid uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when jsonb_typeof(p->'entrants') is distinct from 'array' then p else
    p || jsonb_build_object('entrants', coalesce((
           select jsonb_agg(case when jsonb_typeof(q.x) = 'object'
                                 then q.x || jsonb_build_object('seeker', coalesce(k.seeker, ''),
                                                                'terrain', coalesce(k.terrain, ''))
                                 else q.x end
                            order by q.o)
             from jsonb_array_elements(p->'entrants') with ordinality q(x, o)
             left join tournament_decks k
               on k.tournament_id = p_tid and k.user_id::text = q.x->>'id'), '[]'::jsonb))
  end;
$$;

-- 4. Players: the registered deck ----------------------------------------------
-- Refusals answer {ok:false, reason, message} as the other t_* functions.

-- t_deck_set: the caller registers one of their decks for this tournament.
-- The caller must be signed in (not anonymous) and be a player of it with
-- their account (entrant id = account id), not dropped. Before the start
-- (draft) p_deck_id null removes the registration, and another deck
-- replaces it. Once a Swiss tournament is running, a player with no
-- registration can register once and it is locked at once; a registered
-- one is refused ('locked'). The Seeker comes from the deck; p_terrain must
-- be one of the deck's cards (with at least one copy): the page sends the
-- deck's terrain, and checks the deck is legal (the server has no card
-- list). Never touches the payload, rev or duels.
-- Answers {ok:true, deck:{deck_id, name, seeker, terrain, locked}} (deck
-- null when removed).
create or replace function public.t_deck_set(p_tid uuid, p_deck_id uuid, p_terrain text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_t   tournaments%rowtype;
  v_e   jsonb;
  v_k   decks%rowtype;
  v_has boolean;
  v_ter text := btrim(coalesce(p_terrain, ''));
  v_row tournament_decks%rowtype;
begin
  if v_uid is null or coalesce((auth.jwt()->>'is_anonymous')::boolean, false)
     or not exists (select 1 from profiles pr where pr.id = v_uid and pr.deleted_at is null) then
    return t_no('not_allowed', 'Sign in first.');
  end if;
  select * into v_t from tournaments x where x.id = p_tid for update;
  if not found or v_t.status is null then
    return t_no('not_allowed', 'This tournament was not found.');
  end if;
  if not (v_t.status = 'draft' or (v_t.status = 'running' and v_t.payload->>'fmt' = 'swiss')) then
    return t_no('status', 'Decks are registered before the start, or during a Swiss tournament before your first game.');
  end if;
  select q.x into v_e
    from jsonb_array_elements(coalesce(v_t.payload->'entrants', '[]'::jsonb)) q(x)
   where q.x->>'id' = v_uid::text
   limit 1;
  if v_e is null then
    return t_no('not_entrant', 'Link your malediction.gg profile in Account › Profile, then ask the organizer to add you.');
  end if;
  if v_e->>'st' = 'drop' then
    return t_no('dropped', 'You have dropped from this tournament.');
  end if;
  perform 1 from tournament_decks k where k.tournament_id = p_tid and k.user_id = v_uid;
  v_has := found;
  if v_t.status = 'running' and v_has then
    return t_no('locked', 'Your deck is locked for this tournament.');
  end if;
  if v_t.status = 'draft' and p_deck_id is null then
    delete from tournament_decks where tournament_id = p_tid and user_id = v_uid;
    return jsonb_build_object('ok', true, 'deck', null);
  end if;
  select * into v_k from decks k where k.id = p_deck_id and k.user_id = v_uid;
  if not found then
    return t_no('not_yours', 'Pick one of your own decks.');
  end if;
  if duel_clean(v_k.seeker) is null then
    return t_no('no_seeker', 'This deck has no Seeker.');
  end if;
  if duel_clean(v_ter) is null or jsonb_typeof(v_k.cards) is distinct from 'object'
     or coalesce(v_k.cards->>v_ter, '') !~ '^[1-9][0-9]{0,3}$' then
    return t_no('no_terrain', 'This deck has no terrain.');
  end if;
  insert into tournament_decks (tournament_id, user_id, deck_id, name, seeker, terrain, cards, side,
                                registered_at, locked_at)
  values (p_tid, v_uid, v_k.id, coalesce(v_k.name, ''), duel_clean(v_k.seeker), duel_clean(v_ter), v_k.cards, v_k.side,
          now(), case when v_t.status = 'running' then now() end)
  on conflict (tournament_id, user_id) do update
     set deck_id = excluded.deck_id, name = excluded.name, seeker = excluded.seeker,
         terrain = excluded.terrain, cards = excluded.cards, side = excluded.side,
         registered_at = excluded.registered_at, locked_at = excluded.locked_at
  returning * into v_row;
  return jsonb_build_object('ok', true, 'deck', jsonb_build_object(
           'deck_id', v_row.deck_id, 'name', v_row.name, 'seeker', v_row.seeker,
           'terrain', v_row.terrain, 'locked', v_row.locked_at is not null));
end $$;

-- t_deck_get: what the tournament page shows about registered decks.
-- {ok:true, status, mine, can, org}:
--   mine  the caller's registration {deck_id, name, seeker, terrain, locked,
--         changed (the deck in My decks no longer matches the copy, or was
--         deleted)}, or null;
--   can   'ok' (t_deck_set would accept a deck now), 'not_entrant',
--         'dropped', 'locked' or 'status';
--   org   for the organizer only: one {id, registered, seeker, terrain} per
--         player, in list order (seeker and terrain null when not
--         registered); null for everyone else. Never a card list.
-- Refused ('not_allowed') when the caller cannot see the tournament.
-- Read-only, no locks.
create or replace function public.t_deck_get(p_tid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid  uuid := auth.uid();
  v_t    tournaments%rowtype;
  v_e    jsonb;
  v_org  boolean;
  v_row  tournament_decks%rowtype;
  v_has  boolean := false;
  v_can  text;
  v_mine jsonb;
  v_list jsonb;
begin
  select * into v_t from tournaments x where x.id = p_tid;
  if not found or v_t.status is null then
    return t_no('not_allowed', 'This tournament was not found.');
  end if;
  v_org := coalesce(t_is_org(v_t), false);
  if v_uid is not null then
    select q.x into v_e
      from jsonb_array_elements(coalesce(v_t.payload->'entrants', '[]'::jsonb)) q(x)
     where q.x->>'id' = v_uid::text
     limit 1;
  end if;
  if not v_org and v_e is null
     and not coalesce(is_league_member(v_t.league_id) or league_is_public(v_t.league_id), false) then
    return t_no('not_allowed', 'This tournament was not found.');
  end if;
  if v_e is not null then
    select * into v_row from tournament_decks k where k.tournament_id = p_tid and k.user_id = v_uid;
    v_has := found;
  end if;
  v_can := case when not (v_t.status = 'draft' or (v_t.status = 'running' and v_t.payload->>'fmt' = 'swiss')) then 'status'
                when v_e is null or coalesce((auth.jwt()->>'is_anonymous')::boolean, false) then 'not_entrant'
                when v_e->>'st' = 'drop' then 'dropped'
                when v_t.status = 'running' and v_has then 'locked'
                else 'ok' end;
  if v_has then
    v_mine := jsonb_build_object(
      'deck_id', v_row.deck_id, 'name', v_row.name, 'seeker', v_row.seeker, 'terrain', v_row.terrain,
      'locked', v_row.locked_at is not null,
      'changed', v_row.deck_id is null
                 or exists (select 1 from decks k
                             where k.id = v_row.deck_id
                               and (k.cards is distinct from v_row.cards or k.side is distinct from v_row.side
                                    or duel_clean(k.seeker) is distinct from v_row.seeker)));
  end if;
  if v_org then
    select coalesce(jsonb_agg(jsonb_build_object('id', q.x->>'id', 'registered', k.user_id is not null,
                                                 'seeker', k.seeker, 'terrain', k.terrain) order by q.o), '[]'::jsonb)
      into v_list
      from jsonb_array_elements(coalesce(v_t.payload->'entrants', '[]'::jsonb)) with ordinality q(x, o)
      left join tournament_decks k on k.tournament_id = p_tid and k.user_id::text = q.x->>'id';
  end if;
  return jsonb_build_object('ok', true, 'status', v_t.status, 'mine', v_mine, 'can', v_can, 'org', v_list);
end $$;

-- 5. Players: tournament games without a PIN -----------------------------------
-- t_duel_start: the caller starts their game of the current round of a
-- running Swiss tournament. The game is found here, never sent by the page.
-- Lock order, as t_record_duel, duel_join and t_unpair: the game's open
-- matches, then the caller's other waiting matches (cancelled, as
-- duel_open does), then the tournament. Then:
--   * a match of this game already live or waiting for confirmation: the
--     caller's own is answered {ok, role, id, status} (resume), anyone
--     else's is refused ('busy');
--   * the caller's own invitation: its 30 minutes start again and it is
--     answered like a new one (the host's page calls this to keep it open);
--   * an invitation from the opponent: {ok, role:'guest', id, accept:true},
--     and the page calls t_duel_accept (so two players who tap at the same
--     moment end up in one match);
--   * otherwise, with a registered deck, a new invitation to the opponent
--     (mode and target from the tournament, the caller's Seeker, terrain
--     and deck from the registration):
--     {ok, role:'host', id, status:'waiting', expires_at, server_now, mode,
--      target, opp:{id, name}, t:{id, title, label, ref}, host_seeker,
--      host_terrain}.
-- Refusals: 'status', 'not_entrant', 'dropped', 'no_game', 'opp_no_account'
-- (the opponent has no linked account: the game is not tracked), 'busy',
-- 'no_deck', 'rate_limited' and 'full' (the duel_open brakes), and 'stale'
-- (the tournament or the game changed meanwhile: the page tries once more).
-- duel_sweep() is not run here (cron runs it every 10 minutes): its 48-hour
-- auto-save records results, which would lock a tournament before the
-- matches. An invitation of this game past its 30 minutes is ended here
-- instead, under the lock of (a).
create or replace function public.t_duel_start(p_tid uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := duel_caller();
  v_me     text := v_uid::text;
  v_t      tournaments%rowtype;
  v_g      record;
  v_g2     record;
  v_ref    text;
  v_ids    uuid[] := '{}';
  v_d      duels%rowtype;
  v_reg    tournament_decks%rowtype;
  v_target int;
  v_id     uuid;
  v_exp    timestamptz;
  v_tj     jsonb;
  v_oppj   jsonb;
begin
  perform pg_advisory_xact_lock(hashtext('duel_open:' || v_me));

  -- the game, read without a lock
  select * into v_t from tournaments x where x.id = p_tid;
  if not found or v_t.status is distinct from 'running' or v_t.payload->>'fmt' is distinct from 'swiss' then
    return t_no('status', 'This tournament is not running.');
  end if;
  select * into v_g from t_my_game(v_t.payload, v_me);
  if v_g.why = 'not_entrant' then
    return t_no('not_entrant', 'Link your malediction.gg profile in Account › Profile, then ask the organizer to add you.');
  elsif v_g.why = 'dropped' then
    return t_no('dropped', 'You have dropped from this tournament.');
  elsif v_g.why = 'no_game' then
    return t_no('no_game', 'You have no game to play in this round.');
  elsif v_g.why = 'opp_no_account' then
    return t_no('opp_no_account', 'Your opponent has no linked account, so this game is not tracked. Play it and tell the organizer the result.');
  end if;
  v_ref := 'g:' || v_g.i;

  -- (a) the game's open matches
  for v_d in
    select * from duels x
     where x.tournament_id = p_tid and x.t_ref = v_ref and x.status in ('waiting','live','ending')
     order by x.created_at
     for update
  loop
    v_ids := v_ids || v_d.id;
  end loop;
  update duels set status = 'expired', pin = null, ended_at = now(), updated_at = now()
   where id = any(v_ids) and status = 'waiting' and pin_expires_at <= now();
  -- (b) the caller's other waiting matches
  update duels set status = 'cancelled', pin = null, ended_at = now(), updated_at = now()
   where host_id = v_uid and status = 'waiting' and not (id = any(v_ids));
  -- (c) the tournament
  select * into v_t from tournaments x where x.id = p_tid for update;
  if not found or v_t.status is distinct from 'running' or v_t.payload->>'fmt' is distinct from 'swiss' then
    return t_no('stale', 'The tournament changed. Try again.');
  end if;
  select * into v_g2 from t_my_game(v_t.payload, v_me);
  if v_g2.why is not null or v_g2.i is distinct from v_g.i or v_g2.opp is distinct from v_g.opp then
    return t_no('stale', 'The tournament changed. Try again.');
  end if;
  if exists (select 1 from duels x
              where x.tournament_id = p_tid and x.t_ref = v_ref and x.status in ('waiting','live','ending')
                and not (x.id = any(v_ids))) then
    return t_no('stale', 'The tournament changed. Try again.');
  end if;

  v_tj := jsonb_build_object('id', v_t.id, 'title', nullif(btrim(v_t.payload #>> '{pn,title}'), ''),
                             'label', t_game_label(v_t.payload, v_ref), 'ref', v_ref);
  v_oppj := jsonb_build_object('id', v_g.opp, 'name', coalesce(
              (select q.x->>'name' from jsonb_array_elements(v_t.payload->'entrants') q(x)
                where q.x->>'id' = v_g.opp limit 1),
              (select pr.display_name from profiles pr where pr.id = v_g.opp::uuid)));

  -- a match of this game being played
  select * into v_d from duels x
   where x.id = any(v_ids) and x.status in ('live','ending')
   order by x.created_at
   limit 1;
  if found then
    if v_uid in (v_d.host_id, v_d.guest_id) then
      return jsonb_build_object('ok', true, 'role', case when v_d.host_id = v_uid then 'host' else 'guest' end,
                                'id', v_d.id, 'status', v_d.status);
    end if;
    return t_no('busy', 'This game is already being played on another phone.');
  end if;
  -- the caller's own invitation: kept open for 30 more minutes
  select * into v_d from duels x
   where x.id = any(v_ids) and x.status = 'waiting' and x.t_invite
     and x.host_id = v_uid and x.guest_id::text = v_g.opp
   order by x.created_at desc
   limit 1;
  if found then
    v_exp := now() + interval '30 minutes';
    update duels set pin_expires_at = v_exp, updated_at = now() where id = v_d.id;
    return jsonb_build_object('ok', true, 'role', 'host', 'id', v_d.id, 'status', 'waiting',
                              'expires_at', v_exp, 'server_now', now(), 'mode', v_d.mode, 'target', v_d.target,
                              'opp', v_oppj, 't', v_tj,
                              'host_seeker', v_d.host_seeker, 'host_terrain', v_d.host_terrain);
  end if;
  -- the opponent's invitation: the caller joins it
  select * into v_d from duels x
   where x.id = any(v_ids) and x.status = 'waiting' and x.t_invite
     and x.guest_id = v_uid and x.host_id::text = v_g.opp
   order by x.created_at
   limit 1;
  if found then
    return jsonb_build_object('ok', true, 'role', 'guest', 'id', v_d.id, 'accept', true);
  end if;
  -- anything else waiting on this game (made for an earlier seat) goes
  update duels set status = 'cancelled', pin = null, ended_at = now(), updated_at = now()
   where id = any(v_ids) and status = 'waiting';

  select * into v_reg from tournament_decks k where k.tournament_id = p_tid and k.user_id = v_uid;
  if not found then
    return t_no('no_deck', 'Register your deck for this tournament first.');
  end if;
  if (select count(*) from duels d
      where d.host_id = v_uid and d.created_at > now() - interval '1 hour') >= 30 then
    return t_no('rate_limited', 'You started 30 matches in the last hour. Try again later.');
  end if;
  if (select count(*) from duels d where d.status = 'waiting') >= 2000 then
    return t_no('full', 'Too many matches are waiting for an opponent right now. Try again in a few minutes.');
  end if;
  v_target := case v_t.mode when 'clash' then 40 when 'demo' then 25 end;
  if v_target is null then
    return t_no('status', 'This tournament has no mode set.');
  end if;
  v_exp := now() + interval '30 minutes';
  insert into duels (pin, pin_expires_at, status, mode, target, host_id, guest_id,
                     host_seeker, host_terrain, host_deck_id, tournament_id, t_ref, t_invite)
  values (null, v_exp, 'waiting', v_t.mode, v_target, v_uid, v_g.opp::uuid,
          v_reg.seeker, v_reg.terrain, v_reg.deck_id, p_tid, v_ref, true)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'role', 'host', 'id', v_id, 'status', 'waiting',
                            'expires_at', v_exp, 'server_now', now(), 'mode', v_t.mode, 'target', v_target,
                            'opp', v_oppj, 't', v_tj,
                            'host_seeker', v_reg.seeker, 'host_terrain', v_reg.terrain);
end $$;

-- t_duel_accept: the invited player joins the invitation p_id. Lock order:
-- the match, then the caller's own waiting matches (cancelled, as
-- duel_join does), then the tournament. The game is checked again under
-- the tournament lock (running, Swiss, the same mode, still the open game
-- of the current round between these two players, neither dropped);
-- otherwise the invitation is cancelled ('gone'). A player with no
-- registered deck is refused ('no_deck') and the invitation stays: the page
-- asks for the deck and tries again. Accepting twice answers the same.
-- Answers as duel_join: {ok, id, host_id, host_name, mode, target,
-- host_seeker, host_terrain, server_now}, plus t:{id, title, label, ref}.
-- Refusals: 'not_allowed' (not this caller's invitation), 'gone', 'no_deck'.
create or replace function public.t_duel_accept(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  d     duels%rowtype;
  v_t   tournaments%rowtype;
  v_reg tournament_decks%rowtype;
  v_ok  boolean;
begin
  select * into d from duels x where x.id = p_id for update;
  if not found or d.guest_id is distinct from v_uid then
    return t_no('not_allowed', 'This is not one of your matches.');
  end if;
  if d.status in ('live','ending') then
    select * into v_t from tournaments x where x.id = d.tournament_id;
  elsif d.status <> 'waiting' or not d.t_invite then
    return t_no('gone', 'This invitation has ended.');
  elsif d.pin_expires_at <= now() then
    update duels set status = 'expired', pin = null, ended_at = now(), updated_at = now() where id = d.id;
    return t_no('gone', 'This invitation has ended.');
  else
    update duels set status = 'cancelled', pin = null, ended_at = now(), updated_at = now()
     where host_id = v_uid and status = 'waiting' and id <> d.id;
    v_ok := d.tournament_id is not null;
    if v_ok then
      select * into v_t from tournaments x where x.id = d.tournament_id for update;
      v_ok := found and v_t.status = 'running' and v_t.mode = d.mode
              and t_invite_ok(v_t.payload, d.t_ref, d.host_id, d.guest_id);
    end if;
    if not coalesce(v_ok, false) then
      update duels set status = 'cancelled', pin = null, ended_at = now(), updated_at = now() where id = d.id;
      return t_no('gone', 'This invitation has ended.');
    end if;
    select * into v_reg from tournament_decks k where k.tournament_id = d.tournament_id and k.user_id = v_uid;
    if not found then
      return t_no('no_deck', 'Register your deck for this tournament first.');
    end if;
    update duels
       set status = 'live', guest_seeker = v_reg.seeker, guest_terrain = v_reg.terrain,
           guest_deck_id = v_reg.deck_id, started_at = now(), updated_at = now()
     where id = d.id;
  end if;
  return jsonb_build_object(
    'ok', true, 'id', d.id, 'host_id', d.host_id,
    'host_name', (select p.display_name from profiles p where p.id = d.host_id),
    'mode', d.mode, 'target', d.target,
    'host_seeker', d.host_seeker, 'host_terrain', d.host_terrain,
    'server_now', now(),
    't', case when v_t.id is not null and d.t_ref is not null
              then jsonb_build_object('id', v_t.id, 'title', nullif(btrim(v_t.payload #>> '{pn,title}'), ''),
                                      'label', t_game_label(v_t.payload, d.t_ref), 'ref', d.t_ref) end);
end $$;

-- t_inbox: the polling fallback of the user:<id> topic, cheap.
-- {ok:true, invites, mine}:
--   invites  the caller's open invitations, oldest first:
--            [{id, tid, ref, host_id, host_name, title, label, expires_at}]
--   mine     the running or closed tournaments the caller plays in or
--            organizes (as t_mine, at most 50, newest first), without
--            payloads: [{id, rev, status}]
create or replace function public.t_inbox()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid  uuid := auth.uid();
  v_inv  jsonb;
  v_mine jsonb;
begin
  if v_uid is null or coalesce((auth.jwt()->>'is_anonymous')::boolean, false) then
    return t_no('not_allowed', 'Sign in first.');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.id, 'tid', d.tournament_id, 'ref', d.t_ref, 'host_id', d.host_id,
           'host_name', coalesce((select q.x->>'name'
                                    from jsonb_array_elements(coalesce(t.payload->'entrants', '[]'::jsonb)) q(x)
                                   where q.x->>'id' = d.host_id::text limit 1), p.display_name),
           'title', nullif(btrim(t.payload #>> '{pn,title}'), ''),
           'label', t_game_label(t.payload, d.t_ref),
           'expires_at', d.pin_expires_at) order by d.created_at), '[]'::jsonb)
    into v_inv
    from duels d
    left join tournaments t on t.id = d.tournament_id
    left join profiles p on p.id = d.host_id
   where d.guest_id = v_uid and d.status = 'waiting' and d.t_invite and d.pin_expires_at > now();
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'rev', x.rev, 'status', x.status)
                            order by x.created_at desc), '[]'::jsonb)
    into v_mine
    from (select t.id, t.rev, t.status, t.created_at
            from tournaments t
           where t.status in ('running','closed')
             and ((t.organizer_id = v_uid and is_league_admin(t.league_id))
                  or t.payload->'entrants' @> jsonb_build_array(jsonb_build_object('id', v_uid::text)))
           order by t.created_at desc
           limit 50) x;
  return jsonb_build_object('ok', true, 'invites', v_inv, 'mine', v_mine);
end $$;

-- t_auto_allow: called by the edge function tournament-auto AS THE CALLER,
-- before it pairs or closes with the service role: {ok:true} when the
-- caller is signed in (not anonymous) and organizes this Swiss tournament,
-- or plays in it with their account and has not dropped. The edge function
-- itself does nothing unless the tournament is running. Brakes, as
-- t_fetch_allow: 60 asks an hour per account and 3000 on the site
-- ('rate_limited'; a page asks only when a round looks complete and when a
-- tracked game ends, a few times a round). The asks let through are logged
-- in t_auto_log; refusals are not.
create or replace function public.t_auto_allow(p_tid uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_t   tournaments%rowtype;
begin
  if v_uid is null or coalesce((auth.jwt()->>'is_anonymous')::boolean, false) or p_tid is null then
    return t_no('not_allowed', 'Sign in first.');
  end if;
  select * into v_t from tournaments x where x.id = p_tid;
  if not found or v_t.status is null or v_t.payload->>'fmt' is distinct from 'swiss' then
    return t_no('not_allowed', 'This tournament was not found.');
  end if;
  if coalesce(t_is_org(v_t), false)
     or exists (select 1 from jsonb_array_elements(coalesce(v_t.payload->'entrants', '[]'::jsonb)) q(x)
                 where q.x->>'id' = v_uid::text and q.x->>'st' is distinct from 'drop') then
    delete from t_auto_log where created_at < now() - interval '2 days';
    if (select count(*) from t_auto_log
        where user_id = v_uid and created_at > now() - interval '1 hour') >= 60
       or (select count(*) from t_auto_log where created_at > now() - interval '1 hour') >= 3000 then
      return t_no('rate_limited', 'Too many automatic checks in the last hour. Pair or close it by hand, or try again later.');
    end if;
    insert into t_auto_log (user_id) values (v_uid);
    return jsonb_build_object('ok', true);
  end if;
  return t_no('not_allowed', 'Only the organizer or a player of this tournament can do this.');
end $$;

-- 6. The edge function: automatic pairing and close (service role only) ------
-- t_auto_pair: the next round, paired by the edge function with the page's
-- own engine (swNextPairs) and checked here as t_pair checks the
-- organizer's, without the organizer check: the row is locked; it must be
-- running and Swiss, the community not archived ('status'); p_rev the
-- current rev and p_round the next round ('stale'); within the planned
-- rounds ('rounds_done'); every game of the current round decided
-- ('not_done'); automatic pairing not paused for this round ('hold'); at
-- least 2 players still in ('status'); valid pairings ('bad_pairs'). The
-- round is marked payload.auto = {r}. Answers {ok:true, rev, round}.
create or replace function public.t_auto_pair(p_tid uuid, p_rev int, p_round int, p_pairs jsonb, p_rematch boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_t      tournaments%rowtype;
  v_p      jsonb;
  v_cur    int;
  v_rounds int;
  v_rev    int;
begin
  select * into v_t from tournaments x where x.id = p_tid for update;
  if not found or v_t.status is distinct from 'running' or v_t.payload->>'fmt' is distinct from 'swiss'
     or exists (select 1 from leagues l where l.id = v_t.league_id and l.archived_at is not null) then
    return t_no('status', 'The tournament is not running.');
  end if;
  if p_rev is distinct from v_t.rev then
    return t_no('stale', 'The tournament changed meanwhile.') || jsonb_build_object('rev', v_t.rev);
  end if;
  v_p := v_t.payload;
  v_cur := t_sw_cur(v_p);
  v_rounds := case when v_p->>'rounds' ~ '^[0-9]{1,3}$' then (v_p->>'rounds')::int else 0 end;
  if p_round is distinct from v_cur + 1 then
    return t_no('stale', 'The tournament changed meanwhile.') || jsonb_build_object('rev', v_t.rev);
  end if;
  if p_round > v_rounds then
    return t_no('rounds_done', 'All ' || v_rounds || ' rounds are paired.');
  end if;
  if not t_gm_done(v_p) then
    return t_no('not_done', 'Round ' || v_cur || ' still has games without a result.');
  end if;
  if (v_p #>> '{hold,pair}') = p_round::text then
    return t_no('hold', 'Automatic pairing is paused for round ' || p_round || '.');
  end if;
  if cardinality(t_active(v_p)) < 2 then
    return t_no('status', 'At least 2 players must still be in to pair a round.');
  end if;
  if t_sw_pairs_ok(v_p, p_pairs, coalesce(p_rematch, false)) is not null then
    return t_no('bad_pairs', 'These pairings are not valid.');
  end if;
  v_p := t_sw_append(v_p, p_pairs, p_round) || jsonb_build_object('auto', jsonb_build_object('r', p_round));
  if octet_length(v_p::text) > 1048576 then
    return t_no('bad_input', 'This tournament is too large.');
  end if;
  update tournaments set payload = v_p, rev = rev + 1 where id = p_tid returning rev into v_rev;
  return jsonb_build_object('ok', true, 'rev', v_rev, 'round', p_round);
end $$;

-- t_sw_close_apply: t_close's Swiss part, shared with t_auto_close. The
-- caller has locked the row and checked it is running. p_standings are
-- checked and frozen exactly as described at t_close (SWISS TOURNAMENTS);
-- with p_ac the payload is also marked ac (closed automatically). Answers
-- {ok:true, rev, champion} (champion null when first place is shared) or
-- t_close's refusals.
create or replace function public.t_sw_close_apply(p_tid uuid, p_standings jsonb, p_ac boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_t     tournaments%rowtype;
  v_p     jsonb;
  v_ch    text;
  v_rev   int;
  v_bad   jsonb := t_no('bad_input', 'The standings do not match the results. Reload the page and close again.');
  v_ids   text[];
  v_drops text[];
  v_score jsonb;
  v_row   jsonb;
  v_prev  jsonb;
  v_i     int := 0;
  v_rk    int;
  v_rows  jsonb := '[]'::jsonb;
begin
  select * into v_t from tournaments x where x.id = p_tid;
  v_p := v_t.payload;
  if p_standings is null or jsonb_typeof(p_standings) is distinct from 'array' then
    return t_no('bad_input', 'Reload the page and close again.');
  end if;
  v_ids := t_grouped(v_p);
  if jsonb_array_length(p_standings) <> cardinality(v_ids)
     or (select count(distinct q.x->>'id') from jsonb_array_elements(p_standings) q(x)) <> cardinality(v_ids) then
    return v_bad;
  end if;
  select coalesce(array_agg(q.x->>'id'), '{}') into v_drops
    from jsonb_array_elements(coalesce(v_p->'entrants', '[]'::jsonb)) q(x)
   where q.x->>'st' = 'drop';
  select jsonb_object_agg(s.id, jsonb_build_array(s.tp, s.w, s.d, s.l, s.md)) into v_score
    from t_sw_score(v_p) s;
  for v_row in select q.x from jsonb_array_elements(p_standings) with ordinality q(x, o) order by q.o loop
    if jsonb_typeof(v_row) is distinct from 'object'
       or jsonb_typeof(v_row->'id') is distinct from 'string'
       or jsonb_typeof(v_row->'drop') is distinct from 'boolean' then
      return v_bad;
    end if;
    if exists (select 1 from unnest(array['rk','tp','w','d','l','md','sos']) f
                where jsonb_typeof(v_row->f) is distinct from 'number' or (v_row->>f) !~ '^[0-9]{1,7}$') then
      return v_bad;
    end if;
    if not ((v_row->>'id') = any(v_ids))
       or jsonb_build_array((v_row->>'tp')::int, (v_row->>'w')::int, (v_row->>'d')::int,
                            (v_row->>'l')::int, (v_row->>'md')::int) is distinct from v_score->(v_row->>'id')
       or (v_row->'drop' = 'true'::jsonb) <> ((v_row->>'id') = any(v_drops)) then
      return v_bad;
    end if;
    v_rk := (v_row->>'rk')::int;
    if v_i = 0 then
      if v_rk <> 1 then
        return v_bad;
      end if;
    else
      if (v_row->>'tp')::int > (v_prev->>'tp')::int
         or ((v_row->>'tp')::int = (v_prev->>'tp')::int and (v_row->>'md')::int > (v_prev->>'md')::int) then
        return v_bad;
      end if;
      if v_rk = (v_prev->>'rk')::int then
        if (v_row->>'tp')::int <> (v_prev->>'tp')::int or (v_row->>'md')::int <> (v_prev->>'md')::int then
          return v_bad;
        end if;
      elsif v_rk <> v_i + 1 then
        return v_bad;
      end if;
    end if;
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
                'id', v_row->>'id', 'rk', v_rk, 'tp', (v_row->>'tp')::int, 'w', (v_row->>'w')::int,
                'd', (v_row->>'d')::int, 'l', (v_row->>'l')::int, 'md', (v_row->>'md')::int,
                'sos', (v_row->>'sos')::int, 'drop', v_row->'drop'));
    v_prev := v_row;
    v_i := v_i + 1;
  end loop;
  select q.x->>'id', (q.x->>'rk')::int into v_ch, v_rk
    from jsonb_array_elements(v_rows) with ordinality q(x, o)
   where q.x->'drop' = 'false'::jsonb
   order by q.o
   limit 1;
  if v_ch is not null and (select count(*) from jsonb_array_elements(v_rows) q(x)
                            where q.x->'drop' = 'false'::jsonb and (q.x->>'rk')::int = v_rk) > 1 then
    v_ch := null;
  end if;
  update tournaments
     set payload = (payload - 'champion')
                   || jsonb_build_object('finalized', true, 'finalized_at', now(), 'standings', v_rows)
                   || case when v_ch is not null then jsonb_build_object('champion', v_ch) else '{}'::jsonb end
                   || case when coalesce(p_ac, false) then '{"ac":true}'::jsonb else '{}'::jsonb end,
         status = 'closed', rev = rev + 1
   where id = p_tid returning rev into v_rev;
  return jsonb_build_object('ok', true, 'rev', v_rev, 'champion', v_ch);
end $$;

-- t_close: as in the SWISS TOURNAMENTS section; its Swiss part is now
-- t_sw_close_apply (the same checks and the same answers).
create or replace function public.t_close(p_tid uuid, p_rev int, p_standings jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid   uuid := duel_caller();
  v_no    jsonb;
  v_t     tournaments%rowtype;
  v_p     jsonb;
  v_fin   jsonb;
  v_ch    text;
  v_rev   int;
begin
  v_no := t_lock(p_tid, p_rev);
  if v_no is not null then
    return v_no;
  end if;
  select * into v_t from tournaments x where x.id = p_tid;
  if v_t.status <> 'running' then
    return t_no('status', 'Only a running tournament can be closed.');
  end if;
  v_p := v_t.payload;

  if v_p->>'fmt' = 'swiss' then
    return t_sw_close_apply(p_tid, p_standings) - 'champion';
  end if;

  if jsonb_typeof(v_p->'bracket') = 'array' and jsonb_array_length(v_p->'bracket') > 0 then
    v_fin := v_p->'bracket'->(jsonb_array_length(v_p->'bracket') - 1)->0;
    v_ch := case v_fin->>'winner' when 'a' then v_fin #>> '{a,id}' when 'b' then v_fin #>> '{b,id}' end;
  end if;
  update tournaments
     set payload = (payload - 'champion')
                   || jsonb_build_object('finalized', true, 'finalized_at', now())
                   || case when v_ch is not null then jsonb_build_object('champion', v_ch) else '{}'::jsonb end,
         status = 'closed', rev = rev + 1
   where id = p_tid returning rev into v_rev;
  return jsonb_build_object('ok', true, 'rev', v_rev);
end $$;

-- t_auto_close: the tournament closed by the edge function with the
-- standings of the page's own engine (swCloseRows), after the last result:
-- the row is locked; it must be running and Swiss, the community not
-- archived ('status'); p_rev the current rev ('stale'); every game of the
-- current round decided, and either the last planned round or fewer than 2
-- players still in ('not_done'); the organizer has not reopened it
-- ('hold'). Then t_sw_close_apply, marked ac. Answers {ok:true, rev,
-- champion} (champion null when first place is shared).
create or replace function public.t_auto_close(p_tid uuid, p_rev int, p_standings jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_t      tournaments%rowtype;
  v_p      jsonb;
  v_rounds int;
begin
  select * into v_t from tournaments x where x.id = p_tid for update;
  if not found or v_t.status is distinct from 'running' or v_t.payload->>'fmt' is distinct from 'swiss'
     or exists (select 1 from leagues l where l.id = v_t.league_id and l.archived_at is not null) then
    return t_no('status', 'The tournament is not running.');
  end if;
  if p_rev is distinct from v_t.rev then
    return t_no('stale', 'The tournament changed meanwhile.') || jsonb_build_object('rev', v_t.rev);
  end if;
  v_p := v_t.payload;
  v_rounds := case when v_p->>'rounds' ~ '^[0-9]{1,3}$' then (v_p->>'rounds')::int else 0 end;
  if not t_gm_done(v_p) or not (t_sw_cur(v_p) >= v_rounds or cardinality(t_active(v_p)) < 2) then
    return t_no('not_done', 'The tournament still has games to play.');
  end if;
  if (v_p #>> '{hold,close}') = 'true' then
    return t_no('hold', 'The organizer reopened this tournament, so it closes by hand.');
  end if;
  return t_sw_close_apply(p_tid, p_standings, true);
end $$;

-- 7. Changed functions (each from its latest definition, with one change) ----
-- t_game_for: as in the PLAY NETWORK TOURNAMENTS section, and Swiss
-- tournaments are left out: their games are played as invitations
-- (t_duel_start), so a match joined with a PIN is a casual one there and
-- never locks or tags a Swiss tournament. Earlier tournaments as before.
create or replace function public.t_game_for(p_host uuid, p_guest uuid, p_mode text)
returns table (tournament_id uuid, t_ref text, title text, label text, skip text)
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_t      record;
  v_h      text := p_host::text;
  v_g      text := p_guest::text;
  v_ref    text;
  v_skip   text;
  v_stitle text;
  v_slabel text;
begin
  if p_host is null or p_guest is null or p_host = p_guest then
    return;
  end if;
  for v_t in
    select x.id, x.payload, x.mode
      from tournaments x
     where x.status = 'running'
       and coalesce(x.payload->>'fmt', '') <> 'swiss'
       and x.payload->'entrants' @> jsonb_build_array(jsonb_build_object('id', v_h))
       and x.payload->'entrants' @> jsonb_build_array(jsonb_build_object('id', v_g))
     order by x.created_at
     for update
  loop
    if exists (select 1 from jsonb_array_elements(v_t.payload->'entrants') y(e)
                where y.e->>'id' in (v_h, v_g) and y.e->>'st' = 'drop') then
      continue;
    end if;
    v_ref := null;
    select 'g:' || (y.o - 1) into v_ref
      from jsonb_array_elements(coalesce(v_t.payload->'gm', '[]'::jsonb)) with ordinality y(m, o)
     where y.m->>'w' is null
       and ((y.m->>'a' = v_h and y.m->>'b' = v_g) or (y.m->>'a' = v_g and y.m->>'b' = v_h))
     order by case when y.m->>'r' ~ '^[0-9]{1,3}$' then (y.m->>'r')::int else 0 end, y.o
     limit 1;
    if v_ref is null then
      select 'b:' || (y.o - 1) || ':' || (z.o - 1) into v_ref
        from jsonb_array_elements(coalesce(v_t.payload->'bracket', '[]'::jsonb)) with ordinality y(rd, o),
             jsonb_array_elements(y.rd) with ordinality z(m, o)
       where z.m->>'winner' is null
         and ((z.m #>> '{a,id}' = v_h and z.m #>> '{b,id}' = v_g)
              or (z.m #>> '{a,id}' = v_g and z.m #>> '{b,id}' = v_h))
       order by y.o, z.o
       limit 1;
    end if;
    if v_ref is null then
      continue;
    end if;
    if v_t.mode is distinct from p_mode then
      if v_skip is null then
        v_skip := 'mode';
        v_stitle := nullif(btrim(v_t.payload #>> '{pn,title}'), '');
        v_slabel := t_game_label(v_t.payload, v_ref);
      end if;
      continue;
    end if;
    if exists (select 1 from duels d
                where d.tournament_id = v_t.id and d.t_ref = v_ref and d.status in ('live','ending')) then
      if v_skip is null then
        v_skip := 'busy';
        v_stitle := nullif(btrim(v_t.payload #>> '{pn,title}'), '');
        v_slabel := t_game_label(v_t.payload, v_ref);
      end if;
      continue;
    end if;
    return query select v_t.id, v_ref, nullif(btrim(v_t.payload #>> '{pn,title}'), ''),
                        t_game_label(v_t.payload, v_ref), null::text;
    return;
  end loop;
  if v_skip is not null then
    return query select null::uuid, null::text, v_stitle, v_slabel, v_skip;
  end if;
end $$;

-- t_unpair: as in the SWISS TOURNAMENTS section, and invitations are not
-- untagged: once the round is gone, t_auto_after cancels them (and pauses
-- automatic pairing for that round).
create or replace function public.t_unpair(p_tid uuid, p_rev int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := duel_caller();
  v_no   jsonb;
  v_t    tournaments%rowtype;
  v_r    int;
  v_refs text[];
  v_rev  int;
begin
  select * into v_t from tournaments x where x.id = p_tid;
  if not found or v_t.status is null or not t_is_org(v_t) then
    return t_no('not_allowed', 'Only the organizer of this tournament can change it.');
  end if;
  v_r := t_sw_cur(v_t.payload);
  select coalesce(array_agg('g:' || (q.o - 1)), '{}') into v_refs
    from jsonb_array_elements(coalesce(v_t.payload->'gm', '[]'::jsonb)) with ordinality q(x, o)
   where q.x->>'r' = v_r::text;
  begin
    update duels set tournament_id = null, t_ref = null
     where tournament_id = p_tid and t_ref = any(v_refs) and status not in ('live','ending')
       and not (status = 'waiting' and t_invite);
    v_no := t_lock(p_tid, p_rev);
    if v_no is null then
      select * into v_t from tournaments x where x.id = p_tid;
      if v_t.status <> 'running' then
        v_no := t_no('status', 'The tournament is not running.');
      elsif v_t.payload->>'fmt' is distinct from 'swiss' then
        v_no := t_no('status', 'Only the rounds of a Swiss tournament can be undone.');
      elsif t_sw_cur(v_t.payload) <> v_r then
        v_no := t_no('stale', 'The tournament changed on another device. It has been reloaded; check it and try again.')
                || jsonb_build_object('rev', v_t.rev);
      elsif v_r < 2 then
        v_no := t_no('status', 'Use Back to registration to undo round 1.');
      elsif exists (select 1 from jsonb_array_elements(v_t.payload->'gm') q(x)
                     where q.x->>'r' = v_r::text and q.x->>'src' in ('org','duel')) then
        v_no := t_no('has_results', 'Round ' || v_r || ' already has results, so its pairings cannot be undone. Clear them first.');
      elsif exists (select 1 from duels d
                     where d.tournament_id = p_tid and d.t_ref = any(v_refs) and d.status in ('live','ending')) then
        v_no := t_no('busy', 'A tracked match of round ' || v_r || ' is being played or waits for confirmation. Try again when it has ended.');
      end if;
    end if;
    if v_no is not null then
      raise exception 't_unpair refused' using errcode = 'SL001';
    end if;
    update tournaments
       set payload = jsonb_set(payload, '{gm}', coalesce((
                       select jsonb_agg(q.x order by q.o)
                         from jsonb_array_elements(payload->'gm') with ordinality q(x, o)
                        where (q.x->>'r') is distinct from v_r::text), '[]'::jsonb)),
           rev = rev + 1
     where id = p_tid returning rev into v_rev;
  exception when sqlstate 'SL001' then
    return v_no;
  end;
  return jsonb_build_object('ok', true, 'rev', v_rev);
end $$;

-- t_unstart: as in the SWISS TOURNAMENTS section, and invitations are not
-- untagged: t_auto_after cancels them once the tournament is back in
-- registration.
create or replace function public.t_unstart(p_tid uuid, p_rev int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  v_no  jsonb;
  v_t   tournaments%rowtype;
  v_rev int;
begin
  select * into v_t from tournaments x where x.id = p_tid;
  if not found or v_t.status is null or not t_is_org(v_t) then
    return t_no('not_allowed', 'Only the organizer of this tournament can change it.');
  end if;
  begin
    update duels set tournament_id = null, t_ref = null
     where tournament_id = p_tid and not (status = 'waiting' and t_invite);
    v_no := t_lock(p_tid, p_rev);
    if v_no is null then
      select * into v_t from tournaments x where x.id = p_tid;
      if v_t.status <> 'running' then
        v_no := t_no('status', 'The tournament has not started.');
      elsif t_has_results(v_t.payload) then
        v_no := t_no('has_results', 'Results are already in, so the tournament cannot go back to registration.');
      end if;
    end if;
    if v_no is not null then
      raise exception 't_unstart refused' using errcode = 'SL001';
    end if;
    update tournaments
       set payload = (payload - 'fmt' - 'rounds' - 'cut' - 'seed' - 'standings')
                     || jsonb_build_object('groups', '[]'::jsonb, 'gm', '[]'::jsonb, 'tables', 0,
                                           'bracket', '[]'::jsonb, 'finalized', false,
                                           'entrants', coalesce((
                                             select jsonb_agg(q.x - 'dr' order by q.o)
                                               from jsonb_array_elements(coalesce(payload->'entrants', '[]'::jsonb))
                                                    with ordinality q(x, o)), '[]'::jsonb)),
           status = 'draft', rev = rev + 1
     where id = p_tid returning rev into v_rev;
  exception when sqlstate 'SL001' then
    return v_no;
  end;
  return jsonb_build_object('ok', true, 'rev', v_rev);
end $$;

-- t_rekey: as in the SWISS TOURNAMENTS section, and the moved player's
-- seeker, terrain, deck and deckId are emptied: a registered deck belongs
-- to an account (tournament_decks), so a seat that changes account never
-- shows the previous account's deck.
create or replace function public.t_rekey(p jsonb, p_old text, p_new text)
returns jsonb language sql immutable security definer set search_path = public as $$
  select case when p is null or p_old is null or p_new is null or p_old = p_new then p else
    p
    || jsonb_build_object('entrants', coalesce((
         select jsonb_agg(case when q.x->>'id' = p_old
                               then q.x || jsonb_build_object('id', p_new, 'seeker', '', 'terrain', '', 'deck', '', 'deckId', '')
                               else q.x end
                          order by q.o)
           from jsonb_array_elements(coalesce(p->'entrants', '[]'::jsonb)) with ordinality q(x, o)), '[]'::jsonb))
    || jsonb_build_object('groups', coalesce((
         select jsonb_agg(coalesce((
                  select jsonb_agg(case when y.k #>> '{}' = p_old then to_jsonb(p_new) else y.k end order by y.o)
                    from jsonb_array_elements(q.x) with ordinality y(k, o)), '[]'::jsonb) order by q.o)
           from jsonb_array_elements(coalesce(p->'groups', '[]'::jsonb)) with ordinality q(x, o)), '[]'::jsonb))
    || jsonb_build_object('gm', coalesce((
         select jsonb_agg(q.x || jsonb_strip_nulls(jsonb_build_object(
                  'a', case when q.x->>'a' = p_old then p_new end,
                  'b', case when q.x->>'b' = p_old then p_new end,
                  'w', case when q.x->>'w' = p_old then p_new end)) order by q.o)
           from jsonb_array_elements(coalesce(p->'gm', '[]'::jsonb)) with ordinality q(x, o)), '[]'::jsonb))
    || jsonb_build_object('bracket', coalesce((
         select jsonb_agg(coalesce((
                  select jsonb_agg(y.m || jsonb_strip_nulls(jsonb_build_object(
                           'a', case when y.m #>> '{a,id}' = p_old then jsonb_build_object('id', p_new) end,
                           'b', case when y.m #>> '{b,id}' = p_old then jsonb_build_object('id', p_new) end))
                           order by y.o)
                    from jsonb_array_elements(q.x) with ordinality y(m, o)), '[]'::jsonb) order by q.o)
           from jsonb_array_elements(coalesce(p->'bracket', '[]'::jsonb)) with ordinality q(x, o)), '[]'::jsonb))
    || case when p->>'champion' = p_old then jsonb_build_object('champion', p_new) else '{}'::jsonb end
    || case when jsonb_typeof(p->'standings') = 'array' then jsonb_build_object('standings', coalesce((
         select jsonb_agg(case when q.x->>'id' = p_old then q.x || jsonb_build_object('id', p_new) else q.x end
                          order by q.o)
           from jsonb_array_elements(p->'standings') with ordinality q(x, o)), '[]'::jsonb))
       else '{}'::jsonb end
  end;
$$;

-- t_live_duels: as in the PLAY NETWORK TOURNAMENTS section, plus open
-- invitations (status 'waiting'), so the page can show "Invited".
create or replace function public.t_live_duels(p_tid uuid)
returns table (t_ref text, status text, claim_winner uuid, claimed_at timestamptz)
language sql stable security definer set search_path = public as $$
  select d.t_ref, d.status, d.claim_winner, d.claimed_at
    from duels d
    join tournaments t on t.id = d.tournament_id
   where d.tournament_id = p_tid
     and (d.status in ('live','ending') or (d.status = 'waiting' and d.t_invite))
     and t.status is not null
     and auth.uid() is not null
     and ((t.organizer_id = auth.uid() and is_league_admin(t.league_id))
          or is_site_admin()
          or t.payload->'entrants' @> jsonb_build_array(jsonb_build_object('id', auth.uid()::text)))
   order by d.t_ref;
$$;

-- erase_user_data(): as in the PLAY NETWORK TOURNAMENTS section, and the
-- account's registered tournament decks and t_auto_log rows are deleted.
-- The account's private decks and its registrations go after its
-- tournaments are re-keyed: a tournament is locked before its
-- registrations (as at the start, t_auto_before, and in t_deck_set), and
-- deleting a deck also writes the registrations that point at it
-- (deck_id set null). The matches it points at are finished ones (the
-- open ones are cancelled above, before any tournament is locked).
create or replace function erase_user_data(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  l record;
  v_t record;
  v_e jsonb;
  v_k text;
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
  delete from feedback       where user_id = p_user;
  delete from site_admins    where user_id = p_user;
  delete from member_discord where user_id = p_user;
  delete from duel_join_attempts where user_id = p_user;
  delete from t_auto_log     where user_id = p_user;

  update duels
     set status = 'cancelled', pin = null, ended_at = coalesce(ended_at, now()), updated_at = now()
   where status in ('waiting','live','ending') and (host_id = p_user or guest_id = p_user);

  update tournaments set organizer_id = null where organizer_id = p_user;
  begin
    for v_t in
      select x.id, x.payload
        from tournaments x
       where x.status is not null
         and x.payload->'entrants' @> jsonb_build_array(jsonb_build_object('id', p_user::text))
       order by x.created_at
       for update
    loop
      select q.x into v_e
        from jsonb_array_elements(v_t.payload->'entrants') q(x)
       where q.x->>'id' = p_user::text
       limit 1;
      v_k := case when coalesce(v_e->>'pid', '') ~ '^[A-Za-z0-9]{6,32}$'
                       and not (v_t.payload->'entrants' @> jsonb_build_array(jsonb_build_object('id', 'pn:' || (v_e->>'pid'))))
                  then 'pn:' || (v_e->>'pid') else t_rand_key(v_t.payload) end;
      update tournaments set payload = t_rekey(payload, p_user::text, v_k), rev = rev + 1 where id = v_t.id;
    end loop;
  exception when others then
    raise warning 'erase_user_data tournaments: %', sqlerrm;
  end;
  delete from decks            where user_id = p_user and not is_public;
  delete from tournament_decks where user_id = p_user;

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
         matches_visibility = 'private',
         deleted_at = coalesce(deleted_at, now())
   where id = p_user;
end $$;

-- meta_duels and player_matches: as in the SWISS TOURNAMENTS section
-- (draws), without the finished matches of a Swiss tournament still in
-- registration or running. Owner decision: its players' Seekers and
-- terrains are shown only to its organizer until the close, and a tracked
-- game is recorded into the public payload with its match id (gm[].du) as
-- it ends, so a match there would tell who played what. The Meta gets them
-- at the close (a reopen takes them out again); player_matches still shows
-- them to the two players of the match and to the tournament's organizer.
-- The columns do not change, so the functions are not dropped.
create or replace function public.meta_duels(p_since timestamptz default null)
returns table (id uuid, played_at timestamptz,
               winner_seeker text, loser_seeker text,
               winner_terrain text, loser_terrain text,
               winner_deck_id uuid, loser_deck_id uuid,
               in_tournament boolean, is_draw boolean)
language sql stable security definer set search_path = public as $$
  select d.id,
         date_trunc('day', d.ended_at),
         case when x.wh then d.host_seeker  else d.guest_seeker  end,
         case when x.wh then d.guest_seeker  else d.host_seeker  end,
         case when x.wh then d.host_terrain else d.guest_terrain end,
         case when x.wh then d.guest_terrain else d.host_terrain end,
         case when wk.is_public and wp.matches_visibility = 'public' then wk.id end,
         case when lk.is_public and lp.matches_visibility = 'public' then lk.id end,
         d.tournament_id is not null,
         d.is_draw
    from duels d
    cross join lateral (select d.is_draw or d.winner_id = d.host_id as wh) x
    join profiles wp on wp.id = case when x.wh then d.host_id else d.guest_id end
    join profiles lp on lp.id = case when x.wh then d.guest_id else d.host_id end
    left join decks wk on wk.id = case when x.wh then d.host_deck_id else d.guest_deck_id end
    left join decks lk on lk.id = case when x.wh then d.guest_deck_id else d.host_deck_id end
    left join tournaments t on t.id = d.tournament_id
   where d.status = 'done'
     and (p_since is null or d.ended_at >= p_since)
     and not coalesce(t.status in ('draft','running') and t.payload->>'fmt' = 'swiss', false)
   order by d.ended_at desc;
$$;

create or replace function public.player_matches(p_user uuid)
returns table (id uuid, played_at timestamptz, opponent_id uuid, opponent_name text,
               my_seeker text, my_terrain text, opp_seeker text, opp_terrain text,
               won boolean, my_score int, opp_score int,
               tournament_id uuid, tournament_name text, is_draw boolean)
language sql stable security definer set search_path = public as $$
  with v as (
    select auth.uid() as viewer,
           auth.uid() is not null
             and not coalesce((auth.jwt()->>'is_anonymous')::boolean, false)
             and exists (select 1 from profiles vp where vp.id = auth.uid() and vp.deleted_at is null) as signed_in,
           (select p.matches_visibility from profiles p where p.id = p_user) as vis
  )
  select d.id,
         d.ended_at,
         case when s.shown then op.id end,
         case when s.shown then op.display_name
              when op.deleted_at is not null then 'Deleted player'
              else 'Private player' end,
         case when d.host_id = p_user then d.host_seeker  else d.guest_seeker  end,
         case when d.host_id = p_user then d.host_terrain else d.guest_terrain end,
         case when s.shown then case when d.host_id = p_user then d.guest_seeker  else d.host_seeker  end end,
         case when s.shown then case when d.host_id = p_user then d.guest_terrain else d.host_terrain end end,
         case when d.is_draw then null else d.winner_id = p_user end,
         case when d.winner_id = p_user then d.winner_score else d.loser_score end,
         case when d.winner_id = p_user then d.loser_score else d.winner_score end,
         case when l.is_public or is_league_member(l.id) or coalesce(v.viewer in (d.host_id, d.guest_id), false)
              then t.id end,
         case when l.is_public or is_league_member(l.id) or coalesce(v.viewer in (d.host_id, d.guest_id), false)
              then coalesce(nullif(btrim(t.payload #>> '{pn,title}'), ''),
                            nullif(btrim(t.payload->>'name'), ''),
                            l.name || ' ' || t.month) end,
         d.is_draw
    from duels d
    cross join v
    join profiles op on op.id = case when d.host_id = p_user then d.guest_id else d.host_id end
    cross join lateral (
      select coalesce(v.viewer in (d.host_id, d.guest_id), false)
             or op.matches_visibility = 'public'
             or (op.matches_visibility = 'players' and v.signed_in) as shown
    ) s
    left join tournaments t on t.id = d.tournament_id
    left join leagues l on l.id = t.league_id
   where d.status = 'done'
     and p_user in (d.host_id, d.guest_id)
     and (v.viewer = p_user
          or v.viewer = d.host_id or v.viewer = d.guest_id
          or v.vis = 'public'
          or (v.vis = 'players' and v.signed_in))
     and not coalesce(t.status in ('draft','running') and t.payload->>'fmt' = 'swiss'
                      and not coalesce(v.viewer in (d.host_id, d.guest_id), false)
                      and not coalesce(t_is_org(t), false), false)
   order by d.ended_at desc;
$$;

-- 8. Triggers on Swiss tournaments ----------------------------------------------
-- Both look only at Swiss tournaments (fmt 'swiss' before or after the
-- change); earlier groups-and-finals tournaments and old community
-- tournaments are left alone.
--
-- t_auto_before (BEFORE UPDATE; after guard_tournament, by name):
--   draft -> running    registered decks are refreshed from My decks (when
--                       the deck still exists, is the player's, has a
--                       Seeker and still holds the registered terrain) and
--                       all are locked; seekers and terrains stay hidden;
--                       hold, auto and ac go
--   running -> draft    registrations are unlocked; hold, auto and ac go
--   running, fewer rounds (t_unpair)  automatic pairing pauses for the
--                       round undone (hold.pair), and its auto mark goes
--   running, more rounds not paired automatically (t_pair)  the pause goes
--   running -> closed   the registered Seekers and terrains are written
--                       into the players (owner decision: shown to all
--                       once the tournament is closed)
--   closed -> running   (t_reopen) they are hidden again; it no longer
--                       closes by itself (hold.close), and when rounds
--                       are left the next one is not paired by itself
--                       either (hold.pair, until the organizer pairs it);
--                       ac goes
-- A failure here never stops the change.
create or replace function public.t_auto_before()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_oc int;
  v_nc int;
  v_h  jsonb;
begin
  if new.status is null or coalesce(new.payload->>'fmt', old.payload->>'fmt') is distinct from 'swiss' then
    return new;
  end if;
  begin
    if old.status = 'draft' and new.status = 'running' then
      update tournament_decks k
         set name = coalesce(d.name, ''), seeker = duel_clean(d.seeker), cards = d.cards, side = d.side
        from decks d
       where k.tournament_id = new.id and d.id = k.deck_id and d.user_id = k.user_id
         and duel_clean(d.seeker) is not null and jsonb_typeof(d.cards) = 'object'
         and coalesce(d.cards->>k.terrain, '') ~ '^[1-9][0-9]{0,3}$';
      update tournament_decks set locked_at = now() where tournament_id = new.id;
      new.payload := t_deck_hide(new.payload) - 'hold' - 'auto' - 'ac';
    elsif old.status = 'running' and new.status = 'draft' then
      update tournament_decks set locked_at = null where tournament_id = new.id;
      new.payload := t_deck_hide(new.payload) - 'hold' - 'auto' - 'ac';
    elsif old.status = 'running' and new.status = 'running' then
      v_oc := t_sw_cur(old.payload);
      v_nc := t_sw_cur(new.payload);
      v_h := case when jsonb_typeof(new.payload->'hold') = 'object' then new.payload->'hold' else '{}'::jsonb end;
      if v_nc < v_oc then
        new.payload := new.payload || jsonb_build_object('hold', v_h || jsonb_build_object('pair', v_oc));
        if (new.payload #>> '{auto,r}') = v_oc::text then
          new.payload := new.payload - 'auto';
        end if;
      elsif v_nc > v_oc and (new.payload #>> '{auto,r}') is distinct from v_nc::text and v_h ? 'pair' then
        v_h := v_h - 'pair';
        new.payload := case when v_h = '{}'::jsonb then new.payload - 'hold'
                            else new.payload || jsonb_build_object('hold', v_h) end;
      end if;
    elsif old.status = 'running' and new.status = 'closed' then
      new.payload := t_deck_pub(new.payload, new.id);
    elsif old.status = 'closed' and new.status = 'running' then
      v_h := case when jsonb_typeof(new.payload->'hold') = 'object' then new.payload->'hold' else '{}'::jsonb end;
      v_nc := t_sw_cur(new.payload);
      if v_nc < (case when new.payload->>'rounds' ~ '^[0-9]{1,3}$' then (new.payload->>'rounds')::int else 0 end) then
        v_h := v_h || jsonb_build_object('pair', v_nc + 1);
      end if;
      new.payload := t_deck_hide(new.payload) - 'ac'
                     || jsonb_build_object('hold', v_h || '{"close":true}'::jsonb);
    end if;
  exception when others then
    raise warning 't_auto_before: %', sqlerrm;
  end;
  return new;
end $$;

-- t_auto_after (AFTER UPDATE), each part on its own so it never fails the
-- change:
--   1. invitations of this tournament that no longer match an open game of
--      the current round (a result, a drop, an undone round, back to
--      registration, closed) are cancelled. The tournament row is locked
--      here, so matches are taken with SKIP LOCKED (lock order: match, then
--      tournament); one being accepted right now is skipped, and
--      t_duel_accept checks the game again itself.
--   2. when the status or the number of games changes (a round paired or
--      undone, the start, the close, a reopen), a 'tournament' ping
--      {tid, rev, status, round} goes to the private topic user:<id> of
--      every player with an account who has not dropped, and of the
--      organizer.
create or replace function public.t_auto_after()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_k   text;
  v_msg jsonb;
begin
  if new.status is null or coalesce(new.payload->>'fmt', old.payload->>'fmt') is distinct from 'swiss' then
    return null;
  end if;
  begin
    update duels set status = 'cancelled', pin = null, ended_at = now(), updated_at = now()
     where id in (select d.id from duels d
                   where d.tournament_id = new.id and d.status = 'waiting' and d.t_invite
                     and (new.status is distinct from 'running'
                          or not t_invite_ok(new.payload, d.t_ref, d.host_id, d.guest_id))
                   for update skip locked);
  exception when others then
    null;
  end;
  if new.status is distinct from old.status
     or coalesce(jsonb_array_length(case when jsonb_typeof(new.payload->'gm') = 'array' then new.payload->'gm' end), 0)
        <> coalesce(jsonb_array_length(case when jsonb_typeof(old.payload->'gm') = 'array' then old.payload->'gm' end), 0) then
    begin
      v_msg := jsonb_build_object('tid', new.id, 'rev', new.rev, 'status', new.status, 'round', t_sw_cur(new.payload));
      for v_k in
        select distinct q.x->>'id'
          from jsonb_array_elements(case when jsonb_typeof(new.payload->'entrants') = 'array'
                                         then new.payload->'entrants' else '[]'::jsonb end) q(x)
         where t_acct(q.x->>'id') and q.x->>'st' is distinct from 'drop'
           and (q.x->>'id') is distinct from new.organizer_id::text
      loop
        perform realtime.send(v_msg, 'tournament', 'user:' || v_k, true);
      end loop;
      if new.organizer_id is not null then
        perform realtime.send(v_msg, 'tournament', 'user:' || new.organizer_id::text, true);
      end if;
    exception when others then
      null;
    end;
  end if;
  return null;
end $$;

drop trigger if exists t_auto_before on public.tournaments;
create trigger t_auto_before before update on public.tournaments
  for each row execute function public.t_auto_before();
drop trigger if exists t_auto_after on public.tournaments;
create trigger t_auto_after after update on public.tournaments
  for each row execute function public.t_auto_after();

-- 9. Invitations reach the invited player --------------------------------------
-- duel_invite_notify (AFTER INSERT OR UPDATE OF status, invitations only):
-- a new invitation sends 'invite' {id, tid, ref} to the guest's private
-- topic user:<id>; when it stops waiting (accepted, cancelled, expired) it
-- sends 'invite_end' {id, status}. The host hears the same changes on
-- duel:<id> (duel_notify). A Realtime failure never blocks the write.
create or replace function public.duel_invite_notify()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(new.t_invite, false) or new.guest_id is null then
    return null;
  end if;
  begin
    if tg_op = 'INSERT' then
      if new.status = 'waiting' then
        perform realtime.send(jsonb_build_object('id', new.id, 'tid', new.tournament_id, 'ref', new.t_ref),
                              'invite', 'user:' || new.guest_id::text, true);
      end if;
    elsif old.status = 'waiting' and new.status is distinct from 'waiting' then
      perform realtime.send(jsonb_build_object('id', new.id, 'status', new.status),
                            'invite_end', 'user:' || new.guest_id::text, true);
    end if;
  exception when others then
    null;
  end;
  return null;
end $$;
drop trigger if exists duel_invite_notify on public.duels;
create trigger duel_invite_notify after insert or update of status on public.duels
  for each row when (new.t_invite) execute function public.duel_invite_notify();

-- 10. Realtime: the private topic 'user:<account id>' --------------------------
-- Only that account may receive on it. Nobody may send on it from a page
-- (no insert policy): only the triggers above send, with realtime.send.
-- Skipped with a warning where the project has no realtime.messages table.
do $outer$
begin
  if to_regclass('realtime.messages') is null then
    raise warning 'realtime.messages does not exist: the user inbox policy was not created.';
    return;
  end if;
  begin
    execute 'drop policy if exists "user inbox receive" on realtime.messages';
    execute $p$
      create policy "user inbox receive" on realtime.messages
        for select to authenticated
        using (realtime.topic() = 'user:' || auth.uid()::text)$p$;
  exception when others then
    raise warning 'The user inbox policy was not created (%).', sqlerrm;
  end;
end $outer$;

-- 11. Who may call what -----------------------------------------------------------
revoke all on function public.t_my_game(jsonb, text)                      from public, anon, authenticated;
revoke all on function public.t_invite_ok(jsonb, text, uuid, uuid)        from public, anon, authenticated;
revoke all on function public.t_deck_hide(jsonb)                          from public, anon, authenticated;
revoke all on function public.t_deck_pub(jsonb, uuid)                     from public, anon, authenticated;
revoke all on function public.t_sw_close_apply(uuid, jsonb, boolean)      from public, anon, authenticated;
revoke all on function public.t_auto_before()                             from public, anon, authenticated;
revoke all on function public.t_auto_after()                              from public, anon, authenticated;
revoke all on function public.duel_invite_notify()                        from public, anon, authenticated;
revoke all on function public.t_game_for(uuid, uuid, text)                from public, anon, authenticated;
revoke all on function public.t_rekey(jsonb, text, text)                  from public, anon, authenticated;
revoke all on function erase_user_data(uuid)                              from public, anon, authenticated;
revoke all on function public.t_deck_set(uuid, uuid, text)                from public, anon, authenticated;
revoke all on function public.t_deck_get(uuid)                            from public, anon, authenticated;
revoke all on function public.t_duel_start(uuid)                          from public, anon, authenticated;
revoke all on function public.t_duel_accept(uuid)                         from public, anon, authenticated;
revoke all on function public.t_inbox()                                   from public, anon, authenticated;
revoke all on function public.t_auto_allow(uuid)                          from public, anon, authenticated;
revoke all on function public.t_auto_pair(uuid, int, int, jsonb, boolean) from public, anon, authenticated;
revoke all on function public.t_auto_close(uuid, int, jsonb)              from public, anon, authenticated;
revoke all on function public.t_close(uuid, int, jsonb)                   from public, anon;
revoke all on function public.t_unstart(uuid, int)                        from public, anon;
revoke all on function public.t_unpair(uuid, int)                         from public, anon;
revoke all on function public.t_live_duels(uuid)                          from public, anon;
revoke all on function public.meta_duels(timestamptz)                     from public;
revoke all on function public.player_matches(uuid)                        from public;
grant execute on function public.t_deck_set(uuid, uuid, text)             to authenticated;
grant execute on function public.t_deck_get(uuid)                         to authenticated;
grant execute on function public.t_duel_start(uuid)                       to authenticated;
grant execute on function public.t_duel_accept(uuid)                      to authenticated;
grant execute on function public.t_inbox()                                to authenticated;
grant execute on function public.t_auto_allow(uuid)                       to authenticated;
grant execute on function public.t_auto_pair(uuid, int, int, jsonb, boolean) to service_role;
grant execute on function public.t_auto_close(uuid, int, jsonb)           to service_role;
grant execute on function public.t_close(uuid, int, jsonb)                to authenticated;
grant execute on function public.t_unstart(uuid, int)                     to authenticated;
grant execute on function public.t_unpair(uuid, int)                      to authenticated;
grant execute on function public.t_live_duels(uuid)                       to authenticated;
grant execute on function public.meta_duels(timestamptz)                  to anon, authenticated;
grant execute on function public.player_matches(uuid)                     to anon, authenticated;

-- ============================================================
--  ROUNDS PLAYED (2026-11-16)
--  Swiss games recorded from a tracked match keep its number of game rounds
--  (rp), shown as "Rounds played" in Copy for the Play Network.
-- ============================================================

-- t_reattach: as in the SWISS TOURNAMENTS section, and on a Swiss game the
-- tracked match's number of game rounds goes to rp ("Rounds played" in the
-- Play Network match form), when the match is attached and rp is missing.
create or replace function public.t_reattach(p jsonb, p_tid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_d     record;
  v_m     jsonb;
  v_i     int;
  v_mm    text[];
  v_r     int;
  v_k     int;
  v_a     text;
  v_b     text;
  v_dec   text;
  v_drops text[];
  v_sw    boolean := coalesce(p->>'fmt' = 'swiss', false);
  v_more  boolean := true;
  v_pass  int := 0;
begin
  if p is null or p_tid is null then
    return p;
  end if;
  select coalesce(array_agg(q.x->>'id'), '{}') into v_drops
    from jsonb_array_elements(coalesce(p->'entrants', '[]'::jsonb)) q(x)
   where q.x->>'st' = 'drop';
  while v_more and v_pass < 12 loop
    v_more := false;
    v_pass := v_pass + 1;
    for v_d in
      select d.id, d.t_ref, d.host_id::text as h, d.guest_id::text as g,
             case when d.is_draw then 'draw' else d.winner_id::text end as w,
             d.is_draw,
             case when d.is_draw or d.claim_by = d.winner_id then d.winner_score end as ws,
             case when d.is_draw or d.claim_by = d.winner_id then d.loser_score end as ls,
             d.ended_at, d.rounds
        from duels d
       where d.tournament_id = p_tid and d.status = 'done' and d.t_ref is not null
         and d.guest_id is not null and (d.winner_id is not null or d.is_draw)
       order by d.ended_at desc, d.id
    loop
      if v_d.h = any(v_drops) or v_d.g = any(v_drops) then
        continue;
      end if;
      if v_d.is_draw and not v_sw then
        continue;
      end if;
      if v_d.t_ref ~ '^g:[0-9]{1,4}$' then
        v_i := substr(v_d.t_ref, 3)::int;
        v_m := p->'gm'->v_i;
        if v_m is null or v_m->>'du' is not null then
          continue;
        end if;
        if not coalesce((v_m->>'a' = v_d.h and v_m->>'b' = v_d.g) or (v_m->>'a' = v_d.g and v_m->>'b' = v_d.h), false) then
          continue;
        end if;
        if v_m->>'w' is null then
          v_m := (v_m - 'dx') || jsonb_build_object('w', v_d.w, 'src', 'duel', 'du', v_d.id, 'at', v_d.ended_at)
                 || case when v_sw then t_sw_duel_scores(v_m, v_d.w, v_d.ws, v_d.ls) else '{}'::jsonb end;
        else
          v_m := v_m || jsonb_build_object('du', v_d.id)
                     || case when v_m->>'w' <> v_d.w then '{"dx":true}'::jsonb else '{}'::jsonb end;
          if v_sw and v_m->>'w' = v_d.w then
            v_m := t_sw_duel_scores(v_m, v_d.w, v_d.ws, v_d.ls) || v_m;
          end if;
        end if;
        if v_sw and coalesce(v_d.rounds, 0) > 0 and v_m->>'rp' is null then
          v_m := v_m || jsonb_build_object('rp', v_d.rounds);
        end if;
        p := jsonb_set(p, array['gm', v_i::text], v_m);
      elsif v_d.t_ref ~ '^b:[0-9]{1,2}:[0-9]{1,4}$' then
        if v_d.is_draw then
          continue;
        end if;
        v_mm := regexp_match(v_d.t_ref, '^b:([0-9]{1,2}):([0-9]{1,4})$');
        v_r := v_mm[1]::int;
        v_k := v_mm[2]::int;
        v_m := p->'bracket'->v_r->v_k;
        if v_m is null or jsonb_typeof(v_m) <> 'object' or v_m->>'du' is not null then
          continue;
        end if;
        v_a := v_m #>> '{a,id}';
        v_b := v_m #>> '{b,id}';
        if not coalesce((v_a = v_d.h and v_b = v_d.g) or (v_a = v_d.g and v_b = v_d.h), false) then
          continue;
        end if;
        if v_m->>'winner' is null then
          v_m := (v_m - 'dx')
                 || jsonb_build_object('winner', case when v_a = v_d.w then 'a' else 'b' end,
                                       'src', 'duel', 'du', v_d.id, 'at', v_d.ended_at);
          p := t_propagate(jsonb_set(p, array['bracket', v_r::text, v_k::text], v_m));
          v_more := true;
        else
          v_dec := case v_m->>'winner' when 'a' then v_a when 'b' then v_b end;
          v_m := v_m || jsonb_build_object('du', v_d.id)
                     || case when v_dec is distinct from v_d.w then '{"dx":true}'::jsonb else '{}'::jsonb end;
          p := jsonb_set(p, array['bracket', v_r::text, v_k::text], v_m);
        end if;
      end if;
    end loop;
  end loop;
  return p;
end $$;

-- t_record_duel: as in the SWISS TOURNAMENTS section, and on a Swiss game
-- the tracked match's number of game rounds goes to rp, as in t_reattach.
-- Never raises.
create or replace function public.t_record_duel(p_duel uuid, p_auto boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_d    duels%rowtype;
  v_t    tournaments%rowtype;
  v_p    jsonb;
  v_m    jsonb;
  v_h    text;
  v_g    text;
  v_w    text;
  v_a    text;
  v_b    text;
  v_i    int;
  v_mm   text[];
  v_r    int;
  v_k    int;
  v_dec  text;
  v_sw   boolean;
  v_ws   int;
  v_ls   int;
  v_auto jsonb := case when coalesce(p_auto, false) then '{"auto":true}'::jsonb else '{}'::jsonb end;
begin
  begin
    select * into v_d from duels x where x.id = p_duel;
    if not found or v_d.status <> 'done' or v_d.tournament_id is null or v_d.t_ref is null
       or v_d.guest_id is null or (v_d.winner_id is null and not v_d.is_draw) then
      return;
    end if;
    select * into v_t from tournaments x where x.id = v_d.tournament_id for update;
    if not found or v_t.status is null or v_t.status not in ('running','closed') then
      return;
    end if;
    v_p := v_t.payload;
    v_sw := coalesce(v_p->>'fmt' = 'swiss', false);
    if v_d.is_draw and not v_sw then
      return;
    end if;
    v_h := v_d.host_id::text;
    v_g := v_d.guest_id::text;
    v_w := case when v_d.is_draw then 'draw' else v_d.winner_id::text end;
    if v_d.is_draw or v_d.claim_by = v_d.winner_id then
      v_ws := v_d.winner_score;
      v_ls := v_d.loser_score;
    end if;
    if exists (select 1 from jsonb_array_elements(coalesce(v_p->'entrants', '[]'::jsonb)) y(e)
                where y.e->>'id' in (v_h, v_g) and y.e->>'st' = 'drop') then
      return;
    end if;

    if v_d.t_ref ~ '^g:[0-9]{1,4}$' then
      v_i := substr(v_d.t_ref, 3)::int;
      v_m := v_p->'gm'->v_i;
      if v_m is null then
        return;
      end if;
      v_a := v_m->>'a';
      v_b := v_m->>'b';
      if not coalesce((v_a = v_h and v_b = v_g) or (v_a = v_g and v_b = v_h), false) then
        return;
      end if;
      if v_m->>'w' is null then
        if v_t.status <> 'running' then
          return;
        end if;
        v_m := (v_m - 'dx') || jsonb_build_object('w', v_w, 'src', 'duel', 'du', v_d.id, 'at', now()) || v_auto
               || case when v_sw then t_sw_duel_scores(v_m, v_w, v_ws, v_ls)
                       else '{}'::jsonb end;
      elsif v_m->>'du' is null then
        v_m := v_m || jsonb_build_object('du', v_d.id)
                   || case when v_m->>'w' <> v_w then '{"dx":true}'::jsonb else '{}'::jsonb end;
        if v_sw and v_m->>'w' = v_w then
          v_m := t_sw_duel_scores(v_m, v_w, v_ws, v_ls) || v_m;
        end if;
      else
        return;
      end if;
      if v_sw and coalesce(v_d.rounds, 0) > 0 and v_m->>'rp' is null then
        v_m := v_m || jsonb_build_object('rp', v_d.rounds);
      end if;
      v_p := jsonb_set(v_p, array['gm', v_i::text], v_m);

    elsif v_d.t_ref ~ '^b:[0-9]{1,2}:[0-9]{1,4}$' then
      if v_d.is_draw then
        return;
      end if;
      v_mm := regexp_match(v_d.t_ref, '^b:([0-9]{1,2}):([0-9]{1,4})$');
      v_r := v_mm[1]::int;
      v_k := v_mm[2]::int;
      v_m := v_p->'bracket'->v_r->v_k;
      if v_m is null then
        return;
      end if;
      v_a := v_m #>> '{a,id}';
      v_b := v_m #>> '{b,id}';
      if not coalesce((v_a = v_h and v_b = v_g) or (v_a = v_g and v_b = v_h), false) then
        return;
      end if;
      if v_m->>'winner' is null then
        if v_t.status <> 'running' then
          return;
        end if;
        v_m := (v_m - 'dx')
               || jsonb_build_object('winner', case when v_a = v_w then 'a' else 'b' end,
                                     'src', 'duel', 'du', v_d.id, 'at', now())
               || v_auto;
        v_p := t_propagate(jsonb_set(v_p, array['bracket', v_r::text, v_k::text], v_m));
      elsif v_m->>'du' is null then
        v_dec := case v_m->>'winner' when 'a' then v_a when 'b' then v_b end;
        v_m := v_m || jsonb_build_object('du', v_d.id)
                   || case when v_dec is distinct from v_w then '{"dx":true}'::jsonb else '{}'::jsonb end;
        v_p := jsonb_set(v_p, array['bracket', v_r::text, v_k::text], v_m);
      else
        return;
      end if;

    else
      return;
    end if;

    update tournaments set payload = v_p, rev = rev + 1 where id = v_t.id;
  exception when others then
    raise warning 't_record_duel: %', sqlerrm;
  end;
end $$;

-- Fill rp for Swiss games already recorded from a tracked match.
do $$
declare
  v_t  record;
  v_p  jsonb;
  v_m  jsonb;
  v_i  int;
  v_rd int;
  v_ch boolean;
begin
  for v_t in
    select x.id, x.payload from tournaments x
     where x.status in ('running','closed') and x.payload->>'fmt' = 'swiss'
       and jsonb_typeof(x.payload->'gm') = 'array'
     for update
  loop
    v_p := v_t.payload;
    v_ch := false;
    for v_i in 0 .. jsonb_array_length(v_p->'gm') - 1 loop
      v_m := v_p->'gm'->v_i;
      if jsonb_typeof(v_m) = 'object' and v_m->>'du' is not null and v_m->>'rp' is null then
        v_rd := null;
        select d.rounds into v_rd from duels d where d.id::text = v_m->>'du' and d.status = 'done';
        if coalesce(v_rd, 0) > 0 then
          v_p := jsonb_set(v_p, array['gm', v_i::text], v_m || jsonb_build_object('rp', v_rd));
          v_ch := true;
        end if;
      end if;
    end loop;
    if v_ch then
      update tournaments set payload = v_p, rev = rev + 1 where id = v_t.id;
    end if;
  end loop;
end $$;

-- ============================================================
--  MULTIPLAYER MATCHES (2026-11-17)
-- ============================================================
-- Run as migration-2026-11-17-multiplayer.sql.
-- What changes:
--   * New tables group_matches and group_match_seats: synced Dominion (3 or
--     4 players, 40), Allegiance (2v2, 50) and Nemesis (2v1, 50) matches
--     between signed-in players. One PIN for everyone; seats and sides go
--     by join order; the match goes live by itself when the last seat fills
--     (a 4-player Dominion host can start with 3). Only the seated players
--     read the rows; every change goes through the gm_* functions.
--   * New functions gm_open, gm_start, gm_set_teams, gm_checkpoint,
--     gm_claim, gm_answer, gm_leave, gm_cancel, gm_get, gm_mine (signed-in
--     players) and player_group_matches (the "Multiplayer" profile list,
--     same visibility as player_matches).
--   * Owner decisions: a player who leaves a live match is frozen (seat and
--     Mastery stay, nobody concedes, the others play on). A claim is
--     confirmed by one player from another side (Dominion: one who did not
--     win), is saved at once when every player on the other sides has left,
--     and is saved as claimed after 48 hours.
--   * The PIN box joins both kinds: duel_join gains a 5-argument version
--     (p_v) that hands a multiplayer PIN to gm_join; the 4-argument version
--     cached pages call answers 'needs_update' for one. PINs are unique
--     across both tables (gen_duel_pin, and the 'duel_pin' lock in duel_open
--     and gm_open). duel_open and duel_join also cancel the caller's waiting
--     multiplayer match. duel_sweep runs gm_sweep (same intervals).
--   * Realtime: private channels 'gm:<id>' (policies on realtime.messages)
--     and a 'status' broadcast when a match changes.
--   * erase_user_data: the account's waiting multiplayer matches are
--     cancelled (or its seat freed) and it is frozen in live ones.
--   * Not changed: 1v1 results, tournaments, meta_duels and player_matches.
--     Multiplayer results never reach the Meta or the 1v1 record.

-- 1. Tables ---------------------------------------------------------------------
-- group_matches: one row per synced multiplayer match. The host opens it
-- (status waiting, with a 4-digit PIN valid 15 minutes, renewed for 15
-- minutes at each join but never past an hour after the open), the others
-- join with the PIN in join order, and the
-- match goes live by itself when the last seat fills. One player claims the
-- result (ending), one player from another side confirms it (done), or it is
-- saved as claimed after 48 hours. rev counts every change except the
-- checkpoint state; each new rev is broadcast on 'gm:<id>'. Sides:
-- Allegiance 0 and 1 (2 players each), Nemesis 0 = the Nemesis (1 player)
-- and 1 = the Union (2 players), Dominion one side per seat (side = seat).
-- claim_scores is the Mastery of every side, {"0":52,"1":41}. ended_how:
-- confirmed (a player from another side said yes), auto (48 hours without an
-- answer), unopposed (nobody could confirm: every player who could had
-- left). join_pin keeps the PIN after the match goes live (pin is then
-- null), so a late joiner hears 'full' instead of a wrong PIN.
create table if not exists public.group_matches (
  id             uuid primary key default gen_random_uuid(),
  pin            text,
  pin_expires_at timestamptz,
  join_pin       text,                   -- the PIN, kept once live ('full' for a late joiner)
  status         text not null default 'waiting'
                 check (status in ('waiting','live','ending','done','cancelled','expired')),
  mode           text not null check (mode in ('dominion','allegiance','nemesis')),
  seats          smallint not null,
  target         int  not null,
  host_id        uuid not null references public.profiles(id),
  min_v          smallint not null default 2,
  rev            int  not null default 0,
  state          jsonb,
  state_at       timestamptz,            -- time of the last checkpoint (the 5 s brake)
  teams_locked   boolean not null default false,
  claim_by       uuid references public.profiles(id),
  claim_kind     text check (claim_kind in ('win','draw')),
  claim_side     smallint,
  claim_scores   jsonb,
  claimed_at     timestamptz,            -- saved as claimed after 48 h
  winner_side    smallint,
  is_draw        boolean not null default false,
  ended_how      text check (ended_how in ('confirmed','auto','unopposed')),
  rounds         int,
  created_at     timestamptz not null default now(),
  started_at     timestamptz,
  ended_at       timestamptz,
  updated_at     timestamptz not null default now(),
  constraint gm_seats_mode check ((mode = 'allegiance' and seats = 4) or (mode = 'nemesis' and seats = 3)
                                  or (mode = 'dominion' and seats in (3, 4))),
  constraint gm_target_mode check (target = case mode when 'dominion' then 40 else 50 end),
  constraint gm_pin_only_waiting check ((pin is not null) = (status = 'waiting')),
  constraint gm_pin_format check (pin is null or pin ~ '^[0-9]{4}$'),
  constraint gm_claim_shape check ((claim_by is null) = (claim_kind is null)
                                   and (claim_kind is distinct from 'win' or claim_side is not null)
                                   and (claim_kind is distinct from 'draw' or claim_side is null)
                                   and ((claim_kind is null) = (claim_scores is null))),
  constraint gm_ending_claimed check (status <> 'ending' or claim_by is not null),
  constraint gm_done_has_result check (status <> 'done'
                                       or (is_draw and winner_side is null and claim_kind = 'draw')
                                       or (not is_draw and winner_side is not null and claim_kind = 'win')),
  constraint gm_draw_done check (not is_draw or status = 'done'),
  constraint gm_side_range check ((claim_side is null or claim_side between 0 and 3)
                                  and (winner_side is null or winner_side between 0 and 3)),
  constraint gm_rounds_range check (rounds is null or rounds between 0 and 999)
);
alter table public.group_matches add column if not exists join_pin text;
create unique index if not exists gm_pin_waiting on public.group_matches(pin) where status = 'waiting';
create index if not exists idx_gm_host on public.group_matches(host_id, created_at);
create index if not exists idx_gm_open on public.group_matches(status, updated_at)
  where status in ('waiting','live','ending');
create index if not exists idx_gm_done on public.group_matches(ended_at) where status = 'done';

-- group_match_seats: one row per player. The host is seat 0; the others take
-- the lowest free seat as they join. A player who leaves while the match is
-- waiting loses the seat (the row goes); a player who leaves once it is live
-- is frozen (left_at): the seat and its Mastery stay and the match goes on.
-- final_mastery (the side's Mastery: the team total in team modes), place
-- (1 = the winner; ties share a place) and result are filled in when the
-- match is done.
create table if not exists public.group_match_seats (
  match_id      uuid not null references public.group_matches(id) on delete cascade,
  seat          smallint not null check (seat between 0 and 3),
  user_id       uuid not null references public.profiles(id),
  side          smallint not null check (side between 0 and 3),
  seeker        text not null,
  terrain       text not null,
  deck_id       uuid references public.decks(id) on delete set null,
  joined_at     timestamptz not null default now(),
  left_at       timestamptz,
  final_mastery int check (final_mastery is null or final_mastery between 0 and 999),
  place         smallint check (place is null or place between 1 and 4),
  result        text check (result is null or result in ('win','loss','draw')),
  constraint group_match_seats_pkey primary key (match_id, seat),
  constraint group_match_seats_one_seat unique (match_id, user_id)
);
create index if not exists idx_gm_seats_user on public.group_match_seats(user_id, match_id);
create index if not exists idx_gm_seats_deck on public.group_match_seats(deck_id);

-- 2. Who reads them ------------------------------------------------------------
-- Only the players seated in a match read its rows (a player who left still
-- does). Nothing is written directly: every change goes through the gm_*
-- functions below. gm_is_seated is a security definer helper, so the seats
-- policy does not recurse into itself.
create or replace function public.gm_is_seated(p_match uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from group_match_seats s
                  where s.match_id = p_match and s.user_id = auth.uid());
$$;

alter table public.group_matches enable row level security;
alter table public.group_match_seats enable row level security;
revoke all on public.group_matches from anon, authenticated;
revoke all on public.group_match_seats from anon, authenticated;
grant select on public.group_matches to authenticated;
grant select on public.group_match_seats to authenticated;
drop policy if exists "group players read" on public.group_matches;
create policy "group players read" on public.group_matches
  for select to authenticated using (public.gm_is_seated(id));
drop policy if exists "group seats read" on public.group_match_seats;
create policy "group seats read" on public.group_match_seats
  for select to authenticated using (public.gm_is_seated(match_id));

-- 3. Helpers (not callable over the API) ------------------------------------------
-- The players who may confirm the pending claim: seated, not left, not the
-- claimer and on a side other than the claimer's. Allegiance and Nemesis:
-- any player of the other side, whichever side the claim names, so one team
-- player cannot end the match for their partner without the other side
-- agreeing. Dominion: any player who did not win and is not the claimer.
-- When nobody is left in this list (every player who could confirm has
-- left) the claim is saved at once (unopposed).
create or replace function public.gm_confirmers(p_id uuid)
returns setof uuid language sql stable security definer set search_path = public as $$
  select s.user_id
    from group_matches g
    join group_match_seats c on c.match_id = g.id and c.user_id = g.claim_by
    join group_match_seats s on s.match_id = g.id
   where g.id = p_id and g.status = 'ending'
     and s.left_at is null and s.user_id <> g.claim_by and s.side <> c.side
     and (g.claim_kind = 'draw' or g.mode <> 'dominion' or s.side <> g.claim_side);
$$;

-- The match as a page sees it: the row, the players (seat order) with their
-- names, the caller's seat and side, who may confirm the claim and the
-- server time. players[]: seat, user_id, name, side, seeker, terrain,
-- deck_id, joined_at, left_at, final_mastery, place, result.
create or replace function public.gm_json(p_id uuid, p_uid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  g    group_matches%rowtype;
  v_me group_match_seats%rowtype;
begin
  select * into g from group_matches x where x.id = p_id;
  if not found then
    return null;
  end if;
  select * into v_me from group_match_seats s where s.match_id = p_id and s.user_id = p_uid;
  return to_jsonb(g) || jsonb_build_object(
    'kind', 'group',
    'host_name', (select p.display_name from profiles p where p.id = g.host_id),
    'players', coalesce((
       select jsonb_agg(jsonb_build_object(
                'seat', s.seat, 'user_id', s.user_id, 'name', p.display_name, 'side', s.side,
                'seeker', s.seeker, 'terrain', s.terrain, 'deck_id', s.deck_id,
                'joined_at', s.joined_at, 'left_at', s.left_at,
                'final_mastery', s.final_mastery, 'place', s.place, 'result', s.result)
              order by s.seat)
         from group_match_seats s
         join profiles p on p.id = s.user_id
        where s.match_id = p_id), '[]'::jsonb),
    'seats_n', (select count(*) from group_match_seats s where s.match_id = p_id),
    'me', v_me.seat,
    'my_side', v_me.side,
    'confirmers', coalesce((
       select jsonb_agg(s.seat order by s.seat)
         from group_match_seats s
        where s.match_id = p_id and s.user_id in (select c.u from gm_confirmers(p_id) c(u))), '[]'::jsonb),
    'can_answer', exists (select 1 from gm_confirmers(p_id) c(u) where c.u = p_uid),
    'server_now', now());
end $$;

-- Saves the pending claim as the result (status done). Per side, from
-- claim_scores: a win puts the winning side 1st and the others after it by
-- Mastery; a draw puts every side with the top Mastery 1st ('draw') and the
-- others after them ('loss'). Ties share a place. The seat rows get their
-- side's Mastery, place and result. Returns false when there is no claim.
create or replace function public.gm_finish(p_id uuid, p_how text)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  g group_matches%rowtype;
begin
  select * into g from group_matches x where x.id = p_id for update;
  if not found or g.status <> 'ending' or g.claim_kind is null then
    return false;
  end if;
  with sc as (
    select e.key::smallint as side, e.value::int as score
      from jsonb_each_text(g.claim_scores) e
  ), pl as (
    select a.side, a.score,
           case when g.claim_kind = 'win'
                then case when a.side = g.claim_side then 1
                          else 2 + (select count(*) from sc b where b.side <> g.claim_side and b.score > a.score) end
                else 1 + (select count(*) from sc b where b.score > a.score) end as place,
           case when g.claim_kind = 'win'
                then case when a.side = g.claim_side then 'win' else 'loss' end
                when a.score = (select max(b.score) from sc b) then 'draw'
                else 'loss' end as result
      from sc a
  )
  update group_match_seats s
     set final_mastery = pl.score, place = least(pl.place, 4), result = pl.result
    from pl
   where s.match_id = p_id and s.side = pl.side;
  update group_matches
     set status = 'done', is_draw = (g.claim_kind = 'draw'),
         winner_side = case when g.claim_kind = 'win' then g.claim_side end,
         ended_how = p_how, ended_at = now(), updated_at = now(), rev = rev + 1
   where id = p_id;
  return true;
end $$;

-- A player leaves a live (or ending) match: their seat is frozen with its
-- Mastery and the match goes on. If a claim is pending and nobody can
-- confirm it any more, it is saved at once (unopposed). If nobody is left
-- playing, the match is cancelled. Returns the match status afterwards.
create or replace function public.gm_freeze(p_id uuid, p_uid uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  g group_matches%rowtype;
begin
  select * into g from group_matches x where x.id = p_id for update;
  if not found then
    return null;
  end if;
  if g.status not in ('live','ending') then
    return g.status;
  end if;
  update group_match_seats set left_at = now()
   where match_id = p_id and user_id = p_uid and left_at is null;
  if not found then
    return g.status;
  end if;
  if g.status = 'ending' and not exists (select 1 from gm_confirmers(p_id)) then
    perform gm_finish(p_id, 'unopposed');
    return 'done';
  end if;
  if not exists (select 1 from group_match_seats s where s.match_id = p_id and s.left_at is null) then
    update group_matches
       set status = 'cancelled', ended_at = now(), updated_at = now(), rev = rev + 1
     where id = p_id;
    return 'cancelled';
  end if;
  update group_matches set updated_at = now(), rev = rev + 1 where id = p_id;
  return g.status;
end $$;

-- The account's waiting multiplayer matches make way for a new match: the
-- ones it hosts are cancelled, and its seat in someone else's waiting match
-- is freed (that PIN stays valid). p_keep is spared.
create or replace function public.gm_drop_waiting(p_uid uuid, p_keep uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  r record;
begin
  update group_matches
     set status = 'cancelled', pin = null, ended_at = now(), updated_at = now(), rev = rev + 1
   where host_id = p_uid and status = 'waiting' and id is distinct from p_keep;
  for r in
    select g.id
      from group_matches g
      join group_match_seats s on s.match_id = g.id
     where s.user_id = p_uid and g.status = 'waiting' and g.host_id <> p_uid
       and g.id is distinct from p_keep
     order by g.id
     for update of g
  loop
    delete from group_match_seats where match_id = r.id and user_id = p_uid;
    update group_matches set updated_at = now(), rev = rev + 1 where id = r.id;
  end loop;
end $$;

-- Has the game started, by the checkpoint state? A Next round tap (round
-- above 1 or nr above 0 in section x) or any seat block pN with Mastery
-- other than 0 (or a relic). Sections are {c: clock, d: data}; anything
-- that is not a number is ignored.
create or replace function public.gm_state_started(p jsonb)
returns boolean language sql immutable security definer set search_path = public as $$
  select coalesce(jsonb_typeof(p) = 'object' and (
           (case when jsonb_typeof(p #> '{x,d,round}') = 'number' then (p #> '{x,d,round}')::numeric > 1 else false end)
        or (case when jsonb_typeof(p #> '{x,d,r}')     = 'number' then (p #> '{x,d,r}')::numeric > 1 else false end)
        or (case when jsonb_typeof(p #> '{x,d,nr}')    = 'number' then (p #> '{x,d,nr}')::numeric > 0 else false end)
        or exists (
             select 1
               from jsonb_each(case when jsonb_typeof(p) = 'object' then p else '{}'::jsonb end) e
              where e.key ~ '^p[0-3]$'
                and (case when jsonb_typeof(e.value #> '{d,m}') = 'number'
                          then (e.value #> '{d,m}')::numeric <> 0 else false end
                  or case when jsonb_typeof(e.value #> '{d,rl}') = 'number'
                          then (e.value #> '{d,rl}')::numeric > 0 else false end))), false);
$$;

-- Housekeeping, with the same intervals as duel_sweep(): a waiting match
-- expires with its PIN, a live match idle for 12 hours is cancelled, and a
-- claim nobody answers for 48 hours is saved as claimed (auto). Matches that
-- never started go after 7 days, cancelled ones after 30 days. Finished
-- matches stay. Run at the end of duel_sweep() (pg_cron sl-duel-sweep).
create or replace function public.gm_sweep()
returns integer language plpgsql security definer set search_path = public as $$
declare
  n int := 0;
  m int;
  r record;
begin
  update group_matches set status = 'expired', pin = null, ended_at = now(), updated_at = now(), rev = rev + 1
   where status = 'waiting' and pin_expires_at <= now();
  get diagnostics m = row_count; n := n + m;
  update group_matches set status = 'cancelled', ended_at = now(), updated_at = now(), rev = rev + 1
   where status = 'live' and updated_at < now() - interval '12 hours';
  get diagnostics m = row_count; n := n + m;
  for r in
    select g.id from group_matches g
     where g.status = 'ending' and coalesce(g.claimed_at, g.updated_at) < now() - interval '48 hours'
     order by g.id
     for update skip locked
  loop
    if gm_finish(r.id, 'auto') then
      n := n + 1;
    end if;
  end loop;
  delete from group_matches where status = 'expired' and created_at < now() - interval '7 days';
  delete from group_matches where status = 'cancelled' and created_at < now() - interval '30 days';
  return n;
end $$;

-- 4. One PIN space for both kinds of match ------------------------------------------
-- gen_duel_pin: as in the MATCH TRACKER section, and the PIN must also be
-- free among the waiting multiplayer matches. duel_open and gm_open take the
-- 'duel_pin' lock around picking the PIN and inserting the row, so two opens
-- at the same moment never take the same PIN in the two tables.
create or replace function public.gen_duel_pin()
returns text language plpgsql volatile security definer set search_path = public as $$
declare
  b bytea;
  o int;
  v int;
  c text;
  n int := 0;
begin
  loop
    b := uuid_send(gen_random_uuid());
    foreach o in array array[0, 2, 4, 10, 12, 14] loop
      v := get_byte(b, o) * 256 + get_byte(b, o + 1);
      if v < 60000 then
        c := lpad((v % 10000)::text, 4, '0');
        if not exists (select 1 from duels d where d.status = 'waiting' and d.pin = c)
           and not exists (select 1 from group_matches g where g.status = 'waiting' and g.pin = c) then
          return c;
        end if;
      end if;
    end loop;
    n := n + 1;
    if n > 50 then
      raise exception 'Could not find a free PIN. Try again in a few minutes.'
        using errcode = 'P0001', hint = 'busy';
    end if;
  end loop;
end $$;

-- duel_open: as in the MATCH TRACKER section, plus: the caller's waiting
-- multiplayer matches make way too (gm_drop_waiting), the 30 new matches an
-- hour per account and the 2000 waiting on the site count both kinds (they
-- share the PINs), and the PIN is picked under the 'duel_pin' lock.
create or replace function public.duel_open(p_mode text, p_seeker text, p_terrain text, p_deck_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid     uuid := duel_caller();
  v_seeker  text := duel_clean(p_seeker);
  v_terrain text := duel_clean(p_terrain);
  v_target  int;
  v_pin     text;
  v_id      uuid;
  v_exp     timestamptz := now() + interval '15 minutes';
  i         int;
begin
  if p_mode = 'clash' then
    v_target := 40;
  elsif p_mode = 'demo' then
    v_target := 25;
  else
    raise exception 'A synced match is Clash or Demo' using errcode = '22023';
  end if;
  if v_seeker is null or v_terrain is null then
    raise exception 'Pick your Seeker and terrain first' using errcode = '22023';
  end if;
  if p_deck_id is not null
     and not exists (select 1 from decks k where k.id = p_deck_id and k.user_id = v_uid) then
    raise exception 'Pick one of your own decks' using errcode = '42501';
  end if;

  perform duel_sweep();
  perform pg_advisory_xact_lock(hashtext('duel_open:' || v_uid::text));
  if (select count(*) from duels d
      where d.host_id = v_uid and d.created_at > now() - interval '1 hour')
     + (select count(*) from group_matches g
        where g.host_id = v_uid and g.created_at > now() - interval '1 hour') >= 30 then
    raise exception 'You started 30 matches in the last hour. Try again later.'
      using errcode = 'P0001', hint = 'rate_limited';
  end if;
  update duels set status = 'cancelled', pin = null, ended_at = now(), updated_at = now()
   where host_id = v_uid and status = 'waiting';
  perform gm_drop_waiting(v_uid, null);
  if (select count(*) from duels d where d.status = 'waiting')
     + (select count(*) from group_matches g where g.status = 'waiting') >= 2000 then
    raise exception 'Too many matches are waiting for an opponent right now. Try again in a few minutes.'
      using errcode = 'P0001', hint = 'busy';
  end if;

  perform pg_advisory_xact_lock(hashtext('duel_pin'));
  i := 0;
  loop
    i := i + 1;
    v_pin := gen_duel_pin();
    begin
      insert into duels (pin, pin_expires_at, status, mode, target, host_id,
                         host_seeker, host_terrain, host_deck_id)
      values (v_pin, v_exp, 'waiting', p_mode, v_target, v_uid,
              v_seeker, v_terrain, p_deck_id)
      returning id into v_id;
      exit;
    exception when unique_violation then
      if i >= 5 then
        raise exception 'Could not find a free PIN. Try again in a few minutes.'
          using errcode = 'P0001', hint = 'busy';
      end if;
    end;
  end loop;

  return jsonb_build_object('id', v_id, 'pin', v_pin, 'pin_expires_at', v_exp, 'server_now', now());
end $$;

-- 5. Joining -----------------------------------------------------------------------
-- gm_join: called only from duel_join (which has checked the Seeker,
-- terrain, deck and the wrong-PIN brakes, and holds the match row). The
-- caller takes the lowest free seat with its default side (Allegiance:
-- seats 0-1 are side 0, seats 2-3 side 1; Nemesis: seat 0 is the Nemesis,
-- the others the Union; Dominion: side = seat), or the other side when the
-- host's team changes have filled that one. The caller's other waiting
-- matches of both kinds are cancelled; moving from a seat in someone else's
-- waiting match counts like a wrong PIN (as gm_leave does), so switching
-- lobbies back and forth stays slow. The last seat makes the match live;
-- an earlier one renews the PIN for 15 minutes. A player already seated gets
-- the match back (again true); the host gets 'own_match'. A table that is
-- already live answers 'full' (the PIN of a full table is never wrong).
-- The PIN is renewed at most to an hour after the open.
create or replace function public.gm_join(p_uid uuid, p_id uuid, p_seeker text, p_terrain text, p_deck_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  g      group_matches%rowtype;
  v_n    int;
  v_seat smallint;
  v_side smallint;
begin
  select * into g from group_matches x where x.id = p_id for update;
  if found and g.status in ('live','ending') then
    if exists (select 1 from group_match_seats s where s.match_id = g.id and s.user_id = p_uid) then
      return gm_json(g.id, p_uid) || jsonb_build_object('ok', true, 'again', true);
    end if;
    return jsonb_build_object('ok', false, 'reason', 'full');
  end if;
  if not found or g.status <> 'waiting' or g.pin_expires_at <= now() then
    return jsonb_build_object('ok', false, 'reason', 'bad_pin');
  end if;
  if g.host_id = p_uid then
    return jsonb_build_object('ok', false, 'reason', 'own_match');
  end if;
  if exists (select 1 from group_match_seats s where s.match_id = g.id and s.user_id = p_uid) then
    return gm_json(g.id, p_uid) || jsonb_build_object('ok', true, 'again', true);
  end if;
  select count(*) into v_n from group_match_seats s where s.match_id = g.id;
  select min(q.n)::smallint into v_seat
    from generate_series(1, g.seats - 1) q(n)
   where not exists (select 1 from group_match_seats s where s.match_id = g.id and s.seat = q.n);
  if v_n >= g.seats or v_seat is null then
    return jsonb_build_object('ok', false, 'reason', 'full');
  end if;
  if g.mode = 'dominion' then
    v_side := v_seat;
  else
    v_side := case when g.mode = 'allegiance' then case when v_seat <= 1 then 0 else 1 end
                   else case when v_seat = 0 then 0 else 1 end end;
    if (select count(*) from group_match_seats s where s.match_id = g.id and s.side = v_side)
       >= (case when g.mode = 'allegiance' or v_side = 1 then 2 else 1 end) then
      v_side := 1 - v_side;
    end if;
  end if;

  update duels set status = 'cancelled', pin = null, ended_at = now(), updated_at = now()
   where host_id = p_uid and status = 'waiting';
  if exists (select 1 from group_match_seats s join group_matches x on x.id = s.match_id
              where s.user_id = p_uid and x.status = 'waiting' and x.host_id <> p_uid and x.id <> g.id) then
    insert into duel_join_attempts (user_id) values (p_uid);
  end if;
  perform gm_drop_waiting(p_uid, g.id);
  insert into group_match_seats (match_id, seat, user_id, side, seeker, terrain, deck_id)
  values (g.id, v_seat, p_uid, v_side, p_seeker, p_terrain, p_deck_id);
  if v_n + 1 >= g.seats then
    update group_matches
       set status = 'live', join_pin = g.pin, pin = null, started_at = now(), updated_at = now(), rev = rev + 1
     where id = g.id;
  else
    update group_matches
       set pin_expires_at = greatest(pin_expires_at,
                                     least(now() + interval '15 minutes', g.created_at + interval '60 minutes')),
           updated_at = now(), rev = rev + 1
     where id = g.id;
  end if;
  return gm_json(g.id, p_uid) || jsonb_build_object('ok', true);
end $$;

-- duel_join with p_v: as in the TOURNAMENT DECKS section, plus: a PIN that
-- belongs to a waiting multiplayer match is handed to gm_join when the page
-- says it knows them (p_v 2 or more), and answers 'needs_update' otherwise
-- (not counted as a wrong PIN). The rows of a multiplayer join are locked in
-- one order (the caller's waiting 1v1 matches, then the multiplayer rows by
-- id), so two players joining each other's lobbies never deadlock; a 1v1
-- join first locks the target and the caller's own waiting 1v1 match by id,
-- so two hosts typing each other's PIN never deadlock either. The PIN
-- of a multiplayer table that filled up in the last 15 minutes answers
-- 'full' (not counted), except to a player still seated there, who gets the
-- match back (again true). A PIN wrong for both kinds counts once. A
-- 1v1 join also frees the caller's waiting multiplayer matches, and its
-- answer says kind 'duel'. p_v has no default, so a call without it reaches
-- the 4-argument duel_join below and never two functions at once.
create or replace function public.duel_join(p_pin text, p_seeker text, p_terrain text, p_deck_id uuid, p_v int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid     uuid := duel_caller();
  v_seeker  text := duel_clean(p_seeker);
  v_terrain text := duel_clean(p_terrain);
  v_pin     text := btrim(coalesce(p_pin, ''));
  d         duels%rowtype;
  v_found   boolean;
  v_gid     uuid;
  v_tid     uuid;
  v_tref    text;
  v_ttitle  text;
  v_tlabel  text;
  v_tskip   text;
begin
  if v_seeker is null or v_terrain is null then
    raise exception 'Pick your Seeker and terrain first' using errcode = '22023';
  end if;
  if p_deck_id is not null
     and not exists (select 1 from decks k where k.id = p_deck_id and k.user_id = v_uid) then
    raise exception 'Pick one of your own decks' using errcode = '42501';
  end if;
  if v_pin !~ '^[0-9]{4}$' then
    return jsonb_build_object('ok', false, 'reason', 'bad_pin');
  end if;

  perform duel_sweep();
  perform pg_advisory_xact_lock(hashtext('duel_join:' || v_uid::text));
  if (select count(*) from duel_join_attempts a
      where a.user_id = v_uid and a.created_at > now() - interval '1 minute') >= 5
     or (select count(*) from duel_join_attempts a
         where a.user_id = v_uid and a.created_at > now() - interval '1 hour') >= 20
     or (select count(*) from duel_join_attempts a
         where a.user_id = v_uid and a.created_at > now() - interval '1 day') >= 60 then
    return jsonb_build_object('ok', false, 'reason', 'rate_limited');
  end if;
  if (select count(*) from duel_join_attempts a
      where a.created_at > now() - interval '10 minutes') >= 600 then
    return jsonb_build_object('ok', false, 'reason', 'busy');
  end if;

  perform 1 from duels x
    where x.status = 'waiting' and (x.pin = v_pin or x.host_id = v_uid)
    order by x.id
    for update;
  select * into d from duels x where x.pin = v_pin and x.status = 'waiting' for update;
  v_found := found;
  if not v_found or d.pin_expires_at <= now() then
    select g.id into v_gid from group_matches g
     where g.pin = v_pin and g.status = 'waiting' and g.pin_expires_at > now();
    if v_gid is not null then
      if coalesce(p_v, 1) < 2 then
        return jsonb_build_object('ok', false, 'reason', 'needs_update');
      end if;
      perform 1 from duels x where x.host_id = v_uid and x.status = 'waiting' order by x.id for update;
      perform 1 from group_matches g
        where g.status = 'waiting'
          and (g.id = v_gid or g.host_id = v_uid
               or exists (select 1 from group_match_seats s where s.match_id = g.id and s.user_id = v_uid))
        order by g.id
        for update of g;
      return gm_join(v_uid, v_gid, v_seeker, v_terrain, p_deck_id);
    end if;
    select g.id into v_gid from group_matches g
     where g.join_pin = v_pin and g.status in ('live','ending')
       and g.started_at > now() - interval '15 minutes'
     order by exists (select 1 from group_match_seats s
                       where s.match_id = g.id and s.user_id = v_uid and s.left_at is null) desc,
              g.started_at desc
     limit 1;
    if v_gid is not null and coalesce(p_v, 1) >= 2
       and exists (select 1 from group_match_seats s
                    where s.match_id = v_gid and s.user_id = v_uid and s.left_at is null) then
      return gm_json(v_gid, v_uid) || jsonb_build_object('ok', true, 'again', true);
    end if;
    if v_gid is not null then
      return jsonb_build_object('ok', false, 'reason',
                                case when coalesce(p_v, 1) < 2 then 'needs_update' else 'full' end);
    end if;
    insert into duel_join_attempts (user_id) values (v_uid);
    return jsonb_build_object('ok', false, 'reason', 'bad_pin');
  end if;
  if d.host_id = v_uid then
    return jsonb_build_object('ok', false, 'reason', 'own_match');
  end if;

  update duels set status = 'cancelled', pin = null, ended_at = now(), updated_at = now()
   where host_id = v_uid and status = 'waiting';
  perform gm_drop_waiting(v_uid, null);
  begin
    select g.tournament_id, g.t_ref, g.title, g.label, g.skip
      into v_tid, v_tref, v_ttitle, v_tlabel, v_tskip
      from t_game_for(d.host_id, v_uid, d.mode) g
     limit 1;
  exception when others then
    v_tid := null; v_tref := null; v_ttitle := null; v_tlabel := null; v_tskip := null;
  end;
  -- A tournament game counts only when both players picked a deck.
  if v_tid is not null and (d.host_deck_id is null or p_deck_id is null) then
    v_tid := null; v_tref := null; v_tskip := 'deck';
  end if;
  update duels
     set status = 'live', pin = null, guest_id = v_uid,
         guest_seeker = v_seeker, guest_terrain = v_terrain, guest_deck_id = p_deck_id,
         tournament_id = v_tid, t_ref = case when v_tid is not null then v_tref end,
         started_at = now(), updated_at = now()
   where id = d.id;

  return jsonb_build_object(
    'ok', true, 'kind', 'duel', 'id', d.id, 'host_id', d.host_id,
    'host_name', (select p.display_name from profiles p where p.id = d.host_id),
    'mode', d.mode, 'target', d.target,
    'host_seeker', d.host_seeker, 'host_terrain', d.host_terrain,
    'server_now', now(),
    't', case when v_tid is not null or v_tskip is not null
              then jsonb_build_object('id', v_tid, 'title', v_ttitle, 'label', v_tlabel, 'skip', v_tskip) end);
end $$;

-- duel_join, the 4-argument version that cached pages call: the same as
-- the version above with p_v 1, so a multiplayer PIN answers 'needs_update'.
create or replace function public.duel_join(p_pin text, p_seeker text, p_terrain text, p_deck_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  return public.duel_join(p_pin, p_seeker, p_terrain, p_deck_id, 1);
end $$;

-- 6. Opening a match and the lobby ----------------------------------------------------
-- gm_open: the host picks the mode (dominion 40 for 3 or 4 players, default
-- 4; allegiance 50 for 4; nemesis 50 for 3), their Seeker, terrain and
-- optionally one of their own decks, takes seat 0 (side 0: in Nemesis the
-- host plays the Nemesis) and gets one PIN for everyone. The caller's
-- waiting matches of both kinds are cancelled. The 1v1 limits apply to both
-- kinds together: 30 new matches an hour per account and 2000 waiting on the
-- site. Refusals raise, with hint 'rate_limited' or 'busy'.
create or replace function public.gm_open(p_mode text, p_seats int, p_seeker text, p_terrain text, p_deck_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid     uuid := duel_caller();
  v_seeker  text := duel_clean(p_seeker);
  v_terrain text := duel_clean(p_terrain);
  v_target  int;
  v_seats   int;
  v_pin     text;
  v_id      uuid;
  v_exp     timestamptz := now() + interval '15 minutes';
  i         int;
begin
  if p_mode = 'dominion' then
    v_target := 40;
    v_seats := coalesce(p_seats, 4);
    if v_seats not in (3, 4) then
      raise exception 'Dominion is for 3 or 4 players' using errcode = '22023';
    end if;
  elsif p_mode = 'allegiance' then
    v_target := 50;
    v_seats := 4;
  elsif p_mode = 'nemesis' then
    v_target := 50;
    v_seats := 3;
  else
    raise exception 'A multiplayer match is Dominion, Allegiance or Nemesis' using errcode = '22023';
  end if;
  if p_seats is not null and p_seats <> v_seats then
    raise exception 'Allegiance is for 4 players and Nemesis for 3' using errcode = '22023';
  end if;
  if v_seeker is null or v_terrain is null then
    raise exception 'Pick your Seeker and terrain first' using errcode = '22023';
  end if;
  if p_deck_id is not null
     and not exists (select 1 from decks k where k.id = p_deck_id and k.user_id = v_uid) then
    raise exception 'Pick one of your own decks' using errcode = '42501';
  end if;

  perform duel_sweep();
  perform pg_advisory_xact_lock(hashtext('duel_open:' || v_uid::text));
  if (select count(*) from duels d
      where d.host_id = v_uid and d.created_at > now() - interval '1 hour')
     + (select count(*) from group_matches g
        where g.host_id = v_uid and g.created_at > now() - interval '1 hour') >= 30 then
    raise exception 'You started 30 matches in the last hour. Try again later.'
      using errcode = 'P0001', hint = 'rate_limited';
  end if;
  update duels set status = 'cancelled', pin = null, ended_at = now(), updated_at = now()
   where host_id = v_uid and status = 'waiting';
  perform gm_drop_waiting(v_uid, null);
  if (select count(*) from duels d where d.status = 'waiting')
     + (select count(*) from group_matches g where g.status = 'waiting') >= 2000 then
    raise exception 'Too many matches are waiting for players right now. Try again in a few minutes.'
      using errcode = 'P0001', hint = 'busy';
  end if;

  perform pg_advisory_xact_lock(hashtext('duel_pin'));
  i := 0;
  loop
    i := i + 1;
    v_pin := gen_duel_pin();
    begin
      insert into group_matches (pin, pin_expires_at, status, mode, seats, target, host_id)
      values (v_pin, v_exp, 'waiting', p_mode, v_seats, v_target, v_uid)
      returning id into v_id;
      exit;
    exception when unique_violation then
      if i >= 5 then
        raise exception 'Could not find a free PIN. Try again in a few minutes.'
          using errcode = 'P0001', hint = 'busy';
      end if;
    end;
  end loop;
  insert into group_match_seats (match_id, seat, user_id, side, seeker, terrain, deck_id)
  values (v_id, 0, v_uid, 0, v_seeker, v_terrain, p_deck_id);

  return gm_json(v_id, v_uid) || jsonb_build_object('ok', true);
end $$;

-- gm_start: the host of a 4-player Dominion match with 3 players seated
-- starts it now as a 3-player match. The seats close up in join order (side
-- = seat). Answers ok false with need_3 when the table does not have 3.
create or replace function public.gm_start(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  g     group_matches%rowtype;
  r     record;
  k     int := 0;
begin
  select * into g from group_matches x where x.id = p_id for update;
  if not found or not exists (select 1 from group_match_seats s where s.match_id = g.id and s.user_id = v_uid) then
    raise exception 'This is not one of your matches' using errcode = '42501';
  end if;
  if g.host_id <> v_uid then
    raise exception 'Only the host can start the match' using errcode = '42501';
  end if;
  if g.status <> 'waiting' then
    return jsonb_build_object('ok', false, 'status', g.status);
  end if;
  if g.mode <> 'dominion' or g.seats <> 4 then
    raise exception 'Only a 4-player Dominion match can start with 3 players' using errcode = '22023';
  end if;
  if (select count(*) from group_match_seats s where s.match_id = g.id) <> 3 then
    return jsonb_build_object('ok', false, 'status', g.status, 'reason', 'need_3');
  end if;
  for r in select s.seat from group_match_seats s where s.match_id = g.id order by s.seat loop
    update group_match_seats set seat = k, side = k where match_id = g.id and seat = r.seat;
    k := k + 1;
  end loop;
  update group_matches
     set seats = 3, status = 'live', join_pin = g.pin, pin = null, started_at = now(), updated_at = now(), rev = rev + 1
   where id = g.id;
  return gm_json(g.id, v_uid) || jsonb_build_object('ok', true);
end $$;

-- gm_set_teams: the host changes the sides (Allegiance: Swap / Shuffle
-- teams; Nemesis: who plays the Nemesis) while the match is waiting or live
-- and teams are not locked (they lock at the first Next round, the first
-- Mastery or relic, or the claim). p_sides maps every seated seat to a side,
-- {"0":0,"1":1,"2":0,"3":1}; Allegiance has at most 2 per side, Nemesis 1
-- Nemesis (side 0) and 2 in the Union (side 1). Answers ok false with
-- 'locked' once the teams are locked.
create or replace function public.gm_set_teams(p_id uuid, p_sides jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  g     group_matches%rowtype;
  v_q0  int;
begin
  select * into g from group_matches x where x.id = p_id for update;
  if not found or not exists (select 1 from group_match_seats s where s.match_id = g.id and s.user_id = v_uid) then
    raise exception 'This is not one of your matches' using errcode = '42501';
  end if;
  if g.host_id <> v_uid then
    raise exception 'Only the host can change the teams' using errcode = '42501';
  end if;
  if exists (select 1 from group_match_seats s where s.match_id = g.id and s.user_id = v_uid and s.left_at is not null) then
    raise exception 'You left this match' using errcode = '42501', hint = 'left';
  end if;
  if g.status not in ('waiting','live') then
    return jsonb_build_object('ok', false, 'status', g.status);
  end if;
  if g.teams_locked then
    return jsonb_build_object('ok', false, 'status', g.status, 'reason', 'locked');
  end if;
  if g.mode = 'dominion' then
    raise exception 'Dominion has no teams' using errcode = '22023';
  end if;
  if p_sides is null or jsonb_typeof(p_sides) <> 'object'
     or exists (select 1 from jsonb_each(p_sides) e
                 where e.key !~ '^[0-3]$' or jsonb_typeof(e.value) <> 'number' or e.value::text not in ('0','1'))
     or (select count(*) from jsonb_object_keys(p_sides)) <> (select count(*) from group_match_seats s where s.match_id = g.id)
     or exists (select 1 from group_match_seats s where s.match_id = g.id and not p_sides ? s.seat::text) then
    raise exception 'Give side 0 or 1 for every seated player' using errcode = '22023';
  end if;
  v_q0 := case when g.mode = 'allegiance' then 2 else 1 end;
  if (select count(*) from jsonb_each_text(p_sides) e where e.value = '0') > v_q0
     or (select count(*) from jsonb_each_text(p_sides) e where e.value = '1') > 2 then
    raise exception '%', case when g.mode = 'allegiance' then 'Allegiance is 2 players against 2'
                              else 'Nemesis is one Nemesis against a Union of two' end
      using errcode = '22023', hint = 'bad_teams';
  end if;
  update group_match_seats s set side = (p_sides->>s.seat::text)::smallint where s.match_id = g.id;
  update group_matches set updated_at = now(), rev = rev + 1 where id = g.id;
  return gm_json(g.id, v_uid) || jsonb_build_object('ok', true);
end $$;

-- 7. Playing and ending ---------------------------------------------------------------
-- gm_checkpoint: the last tracker state from any player still in the match,
-- for reconnecting. A JSON object of at most 16 KB (seat blocks may hold a
-- negative share of a team's Mastery), one write per 5 seconds per match
-- (extra calls answer ok with skipped). It locks the teams once the state
-- shows the game has started (gm_state_started), even on a skipped call.
-- Every answer carries the status, so a phone that missed a change re-reads
-- the match. A match that is no longer live or ending, or a player who left,
-- answers ok false.
create or replace function public.gm_checkpoint(p_id uuid, p_state jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := duel_caller();
  g      group_matches%rowtype;
  s      group_match_seats%rowtype;
  v_lock boolean;
begin
  if p_state is null or jsonb_typeof(p_state) <> 'object' then
    raise exception 'The match state must be a JSON object' using errcode = '22023';
  end if;
  if octet_length(p_state::text) > 16384 then
    raise exception 'The match state is too large' using errcode = '22023', hint = 'too_large';
  end if;
  select * into g from group_matches x where x.id = p_id for update;
  if found then
    select * into s from group_match_seats z where z.match_id = g.id and z.user_id = v_uid;
  end if;
  if g.id is null or s.match_id is null then
    raise exception 'This is not one of your matches' using errcode = '42501';
  end if;
  if g.status not in ('live','ending') then
    return jsonb_build_object('ok', false, 'status', g.status);
  end if;
  if s.left_at is not null then
    return jsonb_build_object('ok', false, 'status', g.status, 'left', true);
  end if;
  v_lock := not g.teams_locked and gm_state_started(p_state);
  if g.state_at is not null and g.state_at > now() - interval '5 seconds' then
    if v_lock then
      update group_matches set teams_locked = true, updated_at = now(), rev = rev + 1 where id = g.id;
    end if;
    return jsonb_build_object('ok', true, 'skipped', true, 'status', g.status,
                              'locked', g.teams_locked or v_lock);
  end if;
  update group_matches
     set state = p_state, state_at = now(), updated_at = now(),
         teams_locked = teams_locked or v_lock,
         rev = rev + case when v_lock then 1 else 0 end
   where id = g.id;
  return jsonb_build_object('ok', true, 'status', g.status, 'locked', g.teams_locked or v_lock);
end $$;

-- gm_claim: a player still in a live match claims the result: p_kind 'win'
-- with the winning side p_side (it may be the claimer's own side or
-- another), or 'draw' (p_side ignored; send null) when two or more sides
-- share the top Mastery. p_scores is the Mastery of every side,
-- {"0":52,"1":41}, each 0 to 999; p_rounds 0 to 999 or null; p_state the
-- final state (optional, 16 KB at most). The teams lock. The match waits for
-- one player from another side (gm_confirmers), or is saved at once when
-- nobody can confirm (unopposed).
create or replace function public.gm_claim(p_id uuid, p_kind text, p_side int, p_scores jsonb,
                                           p_rounds int, p_state jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := duel_caller();
  g        group_matches%rowtype;
  s        group_match_seats%rowtype;
  v_sides  int[];
  v_scores jsonb;
  v_top    int;
begin
  if p_kind is null or p_kind not in ('win','draw') then
    raise exception 'A claim is a win or a draw' using errcode = '22023';
  end if;
  if p_rounds is not null and p_rounds not between 0 and 999 then
    raise exception 'Rounds must be between 0 and 999' using errcode = '22023';
  end if;
  if p_state is not null and (jsonb_typeof(p_state) <> 'object' or octet_length(p_state::text) > 16384) then
    raise exception 'The match state must be a JSON object of at most 16 KB' using errcode = '22023', hint = 'too_large';
  end if;
  select * into g from group_matches x where x.id = p_id for update;
  if found then
    select * into s from group_match_seats z where z.match_id = g.id and z.user_id = v_uid;
  end if;
  if g.id is null or s.match_id is null then
    raise exception 'This is not one of your matches' using errcode = '42501';
  end if;
  if g.status <> 'live' then
    return jsonb_build_object('ok', false, 'status', g.status);
  end if;
  if s.left_at is not null then
    raise exception 'You left this match' using errcode = '42501', hint = 'left';
  end if;

  select array_agg(distinct z.side::int order by z.side::int) into v_sides
    from group_match_seats z where z.match_id = g.id;
  if p_scores is null or jsonb_typeof(p_scores) <> 'object'
     or (select count(*) from jsonb_object_keys(p_scores)) <> cardinality(v_sides)
     or exists (select 1 from unnest(v_sides) q(side) where not p_scores ? q.side::text) then
    raise exception 'Give the Mastery of every side' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_each(p_scores) e
              where jsonb_typeof(e.value) <> 'number' or e.value::text !~ '^[0-9]{1,3}$') then
    raise exception 'Mastery must be between 0 and 999' using errcode = '22023';
  end if;
  select jsonb_object_agg(e.key, e.value::int), max(e.value::int) into v_scores, v_top
    from jsonb_each_text(p_scores) e;

  if p_kind = 'win' then
    if p_side is null or not (p_side = any(v_sides)) then
      raise exception 'The winner must be one of the sides' using errcode = '22023';
    end if;
  elsif (select count(*) from jsonb_each_text(v_scores) e where e.value::int = v_top) < 2 then
    raise exception 'A draw needs the same top Mastery for two sides or more' using errcode = '22023', hint = 'draw_unequal';
  end if;

  update group_matches
     set status = 'ending', claim_by = v_uid, claim_kind = p_kind,
         claim_side = case when p_kind = 'win' then p_side end,
         claim_scores = v_scores, claimed_at = now(), rounds = p_rounds,
         state = coalesce(p_state, state), state_at = case when p_state is null then state_at else now() end,
         teams_locked = true, updated_at = now(), rev = rev + 1
   where id = g.id;
  if not exists (select 1 from gm_confirmers(g.id)) then
    perform gm_finish(g.id, 'unopposed');
    return jsonb_build_object('ok', true, 'status', 'done');
  end if;
  return jsonb_build_object('ok', true, 'status', 'ending');
end $$;

-- gm_answer: a player who may confirm the claim (gm_confirmers) accepts it
-- (done, as claimed) or rejects it (back to live, claim cleared). The first
-- answer decides. Anyone else is refused.
create or replace function public.gm_answer(p_id uuid, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  g     group_matches%rowtype;
begin
  select * into g from group_matches x where x.id = p_id for update;
  if not found or not exists (select 1 from group_match_seats s where s.match_id = g.id and s.user_id = v_uid) then
    raise exception 'This is not one of your matches' using errcode = '42501';
  end if;
  if g.status <> 'ending' then
    return jsonb_build_object('ok', false, 'status', g.status);
  end if;
  if not exists (select 1 from gm_confirmers(g.id) c(u) where c.u = v_uid) then
    raise exception 'A player from another side confirms this result' using errcode = '42501', hint = 'not_eligible';
  end if;
  if coalesce(p_accept, false) then
    perform gm_finish(g.id, 'confirmed');
    return jsonb_build_object('ok', true, 'status', 'done');
  end if;
  update group_matches
     set status = 'live', claim_by = null, claim_kind = null, claim_side = null, claim_scores = null,
         claimed_at = null, rounds = null, updated_at = now(), rev = rev + 1
   where id = g.id;
  return jsonb_build_object('ok', true, 'status', 'live');
end $$;

-- gm_leave: "Leave match". While waiting, the host's leave cancels the match
-- and anyone else's frees their seat (the PIN stays valid; status 'left').
-- Leaving a waiting match counts like a wrong PIN toward the join brakes
-- of duel_join (5 a minute, 20 an hour), so a join-and-leave loop stays slow.
-- Once live (or ending) the player is frozen (gm_freeze): seat and Mastery
-- stay, nobody concedes and the others play on. Losing the connection is
-- not leaving.
create or replace function public.gm_leave(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  g     group_matches%rowtype;
  v_st  text;
begin
  select * into g from group_matches x where x.id = p_id for update;
  if not found or not exists (select 1 from group_match_seats s where s.match_id = g.id and s.user_id = v_uid) then
    raise exception 'This is not one of your matches' using errcode = '42501';
  end if;
  if g.status = 'waiting' then
    if g.host_id = v_uid then
      update group_matches
         set status = 'cancelled', pin = null, ended_at = now(), updated_at = now(), rev = rev + 1
       where id = g.id;
      return jsonb_build_object('ok', true, 'status', 'cancelled');
    end if;
    delete from group_match_seats where match_id = g.id and user_id = v_uid;
    insert into duel_join_attempts (user_id) values (v_uid);
    update group_matches set updated_at = now(), rev = rev + 1 where id = g.id;
    return jsonb_build_object('ok', true, 'status', 'left');
  end if;
  if g.status in ('live','ending') then
    v_st := gm_freeze(g.id, v_uid);
    return jsonb_build_object('ok', true, 'status', v_st, 'left', true);
  end if;
  return jsonb_build_object('ok', false, 'status', g.status);
end $$;

-- gm_cancel: no result. While waiting, the host only; while live, any player
-- still in the match, but only until the teams lock. Answers ok false with
-- 'locked' after that (players can only leave).
create or replace function public.gm_cancel(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  g     group_matches%rowtype;
  s     group_match_seats%rowtype;
begin
  select * into g from group_matches x where x.id = p_id for update;
  if found then
    select * into s from group_match_seats z where z.match_id = g.id and z.user_id = v_uid;
  end if;
  if g.id is null or s.match_id is null then
    raise exception 'This is not one of your matches' using errcode = '42501';
  end if;
  if g.status = 'waiting' then
    if g.host_id <> v_uid then
      raise exception 'Only the host can cancel. Tap Leave to free your seat.' using errcode = '42501';
    end if;
  elsif g.status = 'live' then
    if s.left_at is not null then
      raise exception 'You left this match' using errcode = '42501', hint = 'left';
    end if;
    if g.teams_locked then
      return jsonb_build_object('ok', false, 'status', g.status, 'reason', 'locked');
    end if;
  else
    return jsonb_build_object('ok', false, 'status', g.status);
  end if;
  update group_matches
     set status = 'cancelled', pin = null, ended_at = now(), updated_at = now(), rev = rev + 1
   where id = g.id;
  return jsonb_build_object('ok', true, 'status', 'cancelled');
end $$;

-- gm_get: the match (gm_json) for (re)loading it. Null when it does not
-- exist or the caller is not seated in it.
create or replace function public.gm_get(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
begin
  if not exists (select 1 from group_match_seats s where s.match_id = p_id and s.user_id = v_uid) then
    return null;
  end if;
  return gm_json(p_id, v_uid);
end $$;

-- gm_mine: the caller's open multiplayer match (waiting, live or ending, and
-- not left), the newest one, or null.
create or replace function public.gm_mine()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  v_id  uuid;
begin
  select g.id into v_id
    from group_matches g
    join group_match_seats s on s.match_id = g.id
   where s.user_id = v_uid and s.left_at is null and g.status in ('waiting','live','ending')
   order by g.created_at desc
   limit 1;
  if v_id is null then
    return null;
  end if;
  return gm_json(v_id, v_uid);
end $$;

-- 8. Housekeeping ------------------------------------------------------------------
-- duel_sweep: as in the SWISS TOURNAMENTS section, and then gm_sweep() for
-- the multiplayer matches (a failure there never stops the 1v1 sweep).
create or replace function public.duel_sweep()
returns integer language plpgsql security definer set search_path = public as $$
declare
  n int := 0;
  m int;
begin
  if not pg_try_advisory_xact_lock(hashtext('duel_sweep')) then
    return 0;
  end if;
  update duels set status = 'expired', pin = null, ended_at = now(), updated_at = now()
   where status = 'waiting' and pin_expires_at <= now();
  get diagnostics m = row_count; n := n + m;
  update duels set status = 'cancelled', ended_at = now(), updated_at = now()
   where status = 'live' and updated_at < now() - interval '12 hours';
  get diagnostics m = row_count; n := n + m;
  update duels set status = 'done',
         winner_id = case when is_draw then null else claim_winner end,
         loser_id = case when is_draw then null
                         when claim_winner = host_id then guest_id else host_id end,
         ended_at = now(), updated_at = now()
   where status = 'ending' and (claim_winner is not null or is_draw)
     and coalesce(claimed_at, updated_at) < now() - interval '48 hours';
  get diagnostics m = row_count; n := n + m;
  delete from duels where status = 'expired' and created_at < now() - interval '7 days';
  delete from duels where status = 'cancelled' and created_at < now() - interval '30 days';
  delete from duel_join_attempts where created_at < now() - interval '2 days';
  begin
    n := n + gm_sweep();
  exception when others then
    raise warning 'gm_sweep: %', sqlerrm;
  end;
  return n;
end $$;

-- 9. Realtime: private channels 'gm:<id>' ----------------------------------------------
-- Every seated player may join a match channel and receive on it; only a
-- player still in the match (not left) may send (tracker taps, presence).
-- Realtime checks this when a channel is joined (and when the token
-- refreshes), not on every message, so the phones also ignore what a player
-- who left sends, and any change to a frozen seat, on the channel.
-- gm_topic_ok checks the topic shape before reading the id, so a topic that
-- is not 'gm:<uuid>' is simply refused.
create or replace function public.gm_topic_ok(p_topic text, p_send boolean)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
    exists (select 1 from group_match_seats s
             where s.match_id = case when p_topic ~* '^gm:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                                     then substr(p_topic, 4)::uuid end
               and s.user_id = auth.uid()
               and (not coalesce(p_send, false) or s.left_at is null)), false);
$$;

do $outer$
begin
  if to_regclass('realtime.messages') is null then
    raise warning 'realtime.messages does not exist: the group channel policies were not created.';
    return;
  end if;
  begin
    execute 'drop policy if exists "group players receive" on realtime.messages';
    execute $p$
      create policy "group players receive" on realtime.messages
        for select to authenticated
        using (realtime.topic() like 'gm:%' and public.gm_topic_ok(realtime.topic(), false))$p$;
    execute 'drop policy if exists "group players send" on realtime.messages';
    execute $p$
      create policy "group players send" on realtime.messages
        for insert to authenticated
        with check (realtime.topic() like 'gm:%' and public.gm_topic_ok(realtime.topic(), true))$p$;
  exception when others then
    raise warning 'The group channel policies were not created (%).', sqlerrm;
  end;
end $outer$;

-- Each change of status or rev (joins, leaves, team changes, the lock, a
-- claim and its answer, the end) is pushed to the match channel as a
-- 'status' broadcast {status, seats_n, seats, locked, claim, v: rev}; the
-- phones then call gm_get. Checkpoints alone are not broadcast. A Realtime
-- failure never blocks the write.
create or replace function public.gm_notify()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status or new.rev is distinct from old.rev then
    begin
      perform realtime.send(
        jsonb_build_object('status', new.status,
                           'seats_n', (select count(*) from group_match_seats s where s.match_id = new.id),
                           'seats', new.seats,
                           'locked', new.teams_locked,
                           'claim', case when new.claim_by is not null
                                         then jsonb_build_object('by', new.claim_by, 'kind', new.claim_kind,
                                                                 'side', new.claim_side) end,
                           'v', new.rev),
        'status', 'gm:' || new.id::text, true);
    exception when others then
      null;
    end;
  end if;
  return null;
end $$;
drop trigger if exists gm_notify on public.group_matches;
create trigger gm_notify after update on public.group_matches
  for each row execute function public.gm_notify();

-- 10. Profile history ---------------------------------------------------------------
-- player_group_matches: the finished multiplayer matches of one player,
-- newest first, for the "Multiplayer" filter of the Matches list (never in
-- the 1v1 record or win rate, never in the Meta). Shown as p_user's
-- matches_visibility allows, exactly like player_matches; a viewer always
-- sees the matches they played. In players[] every other player keeps their
-- own setting: when it does not let this viewer see them, the entry stays
-- but with no id, Seeker or terrain and the name 'Private player' (or
-- 'Deleted player' for a deleted account). players[]: seat, side, id, name,
-- seeker, terrain, mastery (the side's), place, result, left, me.
create or replace function public.player_group_matches(p_user uuid)
returns table (id uuid, played_at timestamptz, mode text, seats smallint,
               my_seat smallint, my_side smallint, my_seeker text, my_terrain text,
               my_mastery int, place smallint, result text,
               is_draw boolean, winner_side smallint, rounds int, players jsonb)
language sql stable security definer set search_path = public as $$
  with v as (
    select auth.uid() as viewer,
           auth.uid() is not null
             and not coalesce((auth.jwt()->>'is_anonymous')::boolean, false)
             and exists (select 1 from profiles vp where vp.id = auth.uid() and vp.deleted_at is null) as signed_in,
           (select p.matches_visibility from profiles p where p.id = p_user) as vis
  )
  select g.id,
         g.ended_at,
         g.mode,
         g.seats,
         me.seat,
         me.side,
         me.seeker,
         me.terrain,
         me.final_mastery,
         me.place,
         me.result,
         g.is_draw,
         g.winner_side,
         g.rounds,
         (select jsonb_agg(jsonb_build_object(
                   'seat', s.seat, 'side', s.side,
                   'id', case when x.shown then s.user_id end,
                   'name', case when x.shown then op.display_name
                                when op.deleted_at is not null then 'Deleted player'
                                else 'Private player' end,
                   'seeker', case when x.shown then s.seeker end,
                   'terrain', case when x.shown then s.terrain end,
                   'mastery', s.final_mastery, 'place', s.place, 'result', s.result,
                   'left', s.left_at is not null, 'me', s.user_id = p_user)
                 order by s.seat)
            from group_match_seats s
            join profiles op on op.id = s.user_id
           cross join lateral (
             select s.user_id = p_user
                    or vs.seated
                    or op.matches_visibility = 'public'
                    or (op.matches_visibility = 'players' and v.signed_in) as shown
           ) x
           where s.match_id = g.id)
    from group_matches g
    cross join v
    join group_match_seats me on me.match_id = g.id and me.user_id = p_user
    cross join lateral (
      select coalesce(exists (select 1 from group_match_seats z
                               where z.match_id = g.id and z.user_id = v.viewer), false) as seated
    ) vs
   where g.status = 'done'
     and (v.viewer = p_user
          or vs.seated
          or v.vis = 'public'
          or (v.vis = 'players' and v.signed_in))
   order by g.ended_at desc;
$$;

-- 11. erase_user_data(): as in the TOURNAMENT AUTOMATION section, and the
-- account's multiplayer matches: its waiting ones are cancelled (or its
-- seat freed), and in a live one it is frozen like a player who left, so
-- the others play on. Finished matches keep its seat rows, shown as
-- "Deleted player".
create or replace function erase_user_data(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  l record;
  v_t record;
  v_e jsonb;
  v_k text;
  v_g record;
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
  delete from feedback       where user_id = p_user;
  delete from site_admins    where user_id = p_user;
  delete from member_discord where user_id = p_user;
  delete from duel_join_attempts where user_id = p_user;
  delete from t_auto_log     where user_id = p_user;

  update duels
     set status = 'cancelled', pin = null, ended_at = coalesce(ended_at, now()), updated_at = now()
   where status in ('waiting','live','ending') and (host_id = p_user or guest_id = p_user);

  begin
    perform gm_drop_waiting(p_user, null);
    for v_g in
      select g.id
        from group_matches g
        join group_match_seats s on s.match_id = g.id
       where s.user_id = p_user and s.left_at is null and g.status in ('live','ending')
       order by g.id
    loop
      perform gm_freeze(v_g.id, p_user);
    end loop;
  exception when others then
    raise warning 'erase_user_data group matches: %', sqlerrm;
  end;

  update tournaments set organizer_id = null where organizer_id = p_user;
  begin
    for v_t in
      select x.id, x.payload
        from tournaments x
       where x.status is not null
         and x.payload->'entrants' @> jsonb_build_array(jsonb_build_object('id', p_user::text))
       order by x.created_at
       for update
    loop
      select q.x into v_e
        from jsonb_array_elements(v_t.payload->'entrants') q(x)
       where q.x->>'id' = p_user::text
       limit 1;
      v_k := case when coalesce(v_e->>'pid', '') ~ '^[A-Za-z0-9]{6,32}$'
                       and not (v_t.payload->'entrants' @> jsonb_build_array(jsonb_build_object('id', 'pn:' || (v_e->>'pid'))))
                  then 'pn:' || (v_e->>'pid') else t_rand_key(v_t.payload) end;
      update tournaments set payload = t_rekey(payload, p_user::text, v_k), rev = rev + 1 where id = v_t.id;
    end loop;
  exception when others then
    raise warning 'erase_user_data tournaments: %', sqlerrm;
  end;
  delete from decks            where user_id = p_user and not is_public;
  delete from tournament_decks where user_id = p_user;

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
         matches_visibility = 'private',
         deleted_at = coalesce(deleted_at, now())
   where id = p_user;
end $$;

-- 12. Who may call what ----------------------------------------------------------------
revoke all on function public.gm_confirmers(uuid)                        from public, anon, authenticated;
revoke all on function public.gm_json(uuid, uuid)                        from public, anon, authenticated;
revoke all on function public.gm_finish(uuid, text)                      from public, anon, authenticated;
revoke all on function public.gm_freeze(uuid, uuid)                      from public, anon, authenticated;
revoke all on function public.gm_drop_waiting(uuid, uuid)                from public, anon, authenticated;
revoke all on function public.gm_state_started(jsonb)                    from public, anon, authenticated;
revoke all on function public.gm_sweep()                                 from public, anon, authenticated;
revoke all on function public.gm_join(uuid, uuid, text, text, uuid)      from public, anon, authenticated;
revoke all on function public.gm_notify()                                from public, anon, authenticated;
revoke all on function public.gen_duel_pin()                             from public, anon, authenticated;
revoke all on function public.duel_sweep()                               from public, anon, authenticated;
revoke all on function erase_user_data(uuid)                             from public, anon, authenticated;
revoke all on function public.gm_is_seated(uuid)                         from public, anon;
revoke all on function public.gm_topic_ok(text, boolean)                 from public, anon;
revoke all on function public.duel_open(text, text, text, uuid)          from public, anon;
revoke all on function public.duel_join(text, text, text, uuid)          from public, anon;
revoke all on function public.duel_join(text, text, text, uuid, int)     from public, anon;
revoke all on function public.gm_open(text, int, text, text, uuid)       from public, anon;
revoke all on function public.gm_start(uuid)                             from public, anon;
revoke all on function public.gm_set_teams(uuid, jsonb)                  from public, anon;
revoke all on function public.gm_checkpoint(uuid, jsonb)                 from public, anon;
revoke all on function public.gm_claim(uuid, text, int, jsonb, int, jsonb) from public, anon;
revoke all on function public.gm_answer(uuid, boolean)                   from public, anon;
revoke all on function public.gm_leave(uuid)                             from public, anon;
revoke all on function public.gm_cancel(uuid)                            from public, anon;
revoke all on function public.gm_get(uuid)                               from public, anon;
revoke all on function public.gm_mine()                                  from public, anon;
revoke all on function public.player_group_matches(uuid)                 from public;
grant execute on function public.gm_is_seated(uuid)                      to authenticated;
grant execute on function public.gm_topic_ok(text, boolean)              to authenticated;
grant execute on function public.duel_open(text, text, text, uuid)       to authenticated;
grant execute on function public.duel_join(text, text, text, uuid)       to authenticated;
grant execute on function public.duel_join(text, text, text, uuid, int)  to authenticated;
grant execute on function public.gm_open(text, int, text, text, uuid)    to authenticated;
grant execute on function public.gm_start(uuid)                          to authenticated;
grant execute on function public.gm_set_teams(uuid, jsonb)               to authenticated;
grant execute on function public.gm_checkpoint(uuid, jsonb)              to authenticated;
grant execute on function public.gm_claim(uuid, text, int, jsonb, int, jsonb) to authenticated;
grant execute on function public.gm_answer(uuid, boolean)                to authenticated;
grant execute on function public.gm_leave(uuid)                          to authenticated;
grant execute on function public.gm_cancel(uuid)                         to authenticated;
grant execute on function public.gm_get(uuid)                            to authenticated;
grant execute on function public.gm_mine()                               to authenticated;
grant execute on function public.player_group_matches(uuid)              to anon, authenticated;

-- ============================================================
--  COMMUNITY BOARD AND ADDRESS (2026-11-18)
-- ============================================================
-- Run as migration-2026-11-18-community-board.sql.
-- What changes:
--   * New table community_messages: the members' message board of a
--     community. Active members (and the creator) write and read; the
--     organizers (creator and co-organizers) and the site admin read too.
--     Visitors, players who left or were retired, and signed-out visitors
--     read nothing, even in a public community; a player who left still
--     sees (and can delete) their own old messages there, nothing else.
--     Each author deletes their own messages, the organizers delete any
--     message of their community, the site admin deletes any message.
--     Nobody edits a message.
--   * Writing needs a full account: not signed in, a guest (anonymous)
--     sign-in and a deleted account are refused, and so is an archived
--     community (deleting still works there, as for notices). A trigger
--     stamps the author and the time, trims the text (1 to 1000
--     characters; every kind of blank is trimmed, so a message of only
--     newlines or invisible spaces is refused) and applies the brake:
--     5 messages a minute and 60 an hour per author (hint 'rate_limited').
--     The brake counts writes in community_message_writes (one row per
--     message sent, kept for an hour, no access from the site), so deleting
--     messages does not reset it.
--   * The organizer notices (announcements) are not changed.
--   * New column leagues.address (up to 200 characters, trimmed, empty
--     means none): set by whoever already edits the community details (the
--     creator and the co-organizers); read by whoever reads the community.
--     guard_league_fields trims it; guard_league_update already refuses it
--     for anybody else (the site admin only archives or reopens).
--   * New function trim_blank(text): trims spaces, tabs, newlines and the
--     invisible Unicode spaces (btrim only trims the plain space).
--   * erase_user_data: a deleted account's board messages and brake log are
--     deleted, like its feedback (the notices it wrote stay, as before).
--   * Unread counts are kept on the device: nothing in the database.

-- 0. trim_blank(): like btrim, but for every kind of blank: \s (space, tab,
-- newline, carriage return, form feed), no-break spaces, the Unicode spaces
-- U+2000..U+200A, zero-width space and joiners, line and paragraph
-- separators, word joiner, ideographic space and the byte order mark.
create or replace function public.trim_blank(p text)
returns text language sql immutable parallel safe as $$
  select regexp_replace(p,
    '^[\s\u00a0\u1680\u180e\u2000-\u200d\u2028\u2029\u202f\u205f\u2060\u3000\ufeff]+|[\s\u00a0\u1680\u180e\u2000-\u200d\u2028\u2029\u202f\u205f\u2060\u3000\ufeff]+$',
    '', 'g')
$$;

-- 1. Community address -----------------------------------------------------------
alter table public.leagues add column if not exists address text;
alter table public.leagues drop constraint if exists leagues_address_len;
alter table public.leagues add constraint leagues_address_len
  check (address is null or char_length(address) between 1 and 200);

-- guard_league_fields(): as in ONLINE LEAGUES AND WINDOW EVENTS, plus the
-- address line (trimmed with trim_blank; empty means none). The update policy and
-- guard_league_update are not changed: the creator and the co-organizers
-- edit every detail, the site admin only archives or reopens, and nobody
-- else reaches the row.
create or replace function guard_league_fields()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.region      := nullif(btrim(new.region), '');
  new.timezone    := nullif(btrim(new.timezone), '');
  new.discord_url := nullif(btrim(new.discord_url), '');
  new.address     := nullif(trim_blank(new.address), '');
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

-- 2. The message board -----------------------------------------------------------
-- One row per message. author_id is stamped by the trigger below; it turns
-- null only if a profile row is ever removed by hand (a deleted account's
-- messages are deleted by erase_user_data).
create table if not exists public.community_messages (
  id         uuid primary key default gen_random_uuid(),
  league_id  uuid not null references public.leagues(id) on delete cascade,
  author_id  uuid references public.profiles(id) on delete set null,
  body       text not null,
  created_at timestamptz not null default now()
);
-- 1 to 1000 characters once every kind of blank is trimmed.
alter table public.community_messages drop constraint if exists community_messages_body_len;
alter table public.community_messages add constraint community_messages_body_len
  check (char_length(public.trim_blank(body)) between 1 and 1000);
create index if not exists idx_community_messages_league
  on public.community_messages(league_id, created_at desc);
create index if not exists idx_community_messages_author
  on public.community_messages(author_id, created_at);

-- The brake's log: one row per message sent from the site, kept for an hour.
-- Deleting a message does not touch it, so writing and deleting in a loop
-- is braked too. Only check_board_write (security definer) reads and writes
-- it; the site has no access.
create table if not exists public.community_message_writes (
  id        bigint generated always as identity primary key,
  author_id uuid not null references public.profiles(id) on delete cascade,
  at        timestamptz not null default now()
);
create index if not exists idx_community_message_writes_author
  on public.community_message_writes(author_id, at);
alter table public.community_message_writes enable row level security;
revoke all on public.community_message_writes from anon, authenticated;
grant select, insert, update, delete on public.community_message_writes to service_role;

-- Who may write, and the brake. Security definer, so the brake sees the
-- log above (every write of the author, in any community). Called by the
-- trigger below it also logs the write; called directly (an RPC) it only
-- checks, so it cannot be used to fill the log.
create or replace function public.check_board_write(p_league uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null or coalesce((auth.jwt()->>'is_anonymous')::boolean, false) then
    raise exception 'Sign in with an account to write on the board'
      using errcode = '42501', hint = 'sign_in';
  end if;
  if not exists (select 1 from profiles p where p.id = v_uid and p.deleted_at is null) then
    raise exception 'This account was deleted' using errcode = '42501', hint = 'deleted';
  end if;
  if not (is_active_member(p_league) or is_league_owner(p_league)) then
    raise exception 'Only the members of this community can write on its board'
      using errcode = '42501', hint = 'not_member';
  end if;
  if exists (select 1 from leagues l where l.id = p_league and l.archived_at is not null) then
    raise exception 'This community is archived' using errcode = '42501', hint = 'archived';
  end if;
  -- One writer at a time per author, so two quick sends cannot both slip
  -- under the brake.
  perform pg_advisory_xact_lock(hashtext('community_board'), hashtext(v_uid::text));
  delete from community_message_writes w
   where w.author_id = v_uid and w.at <= now() - interval '1 hour';
  if (select count(*) from community_message_writes w
       where w.author_id = v_uid and w.at > now() - interval '1 minute') >= 5 then
    raise exception 'You wrote 5 messages in the last minute. Wait a moment and try again.'
      using errcode = 'P0001', hint = 'rate_limited';
  end if;
  if (select count(*) from community_message_writes w
       where w.author_id = v_uid and w.at > now() - interval '1 hour') >= 60 then
    raise exception 'You wrote 60 messages in the last hour. Try again later.'
      using errcode = 'P0001', hint = 'rate_limited';
  end if;
  if pg_trigger_depth() > 0 then
    insert into community_message_writes(author_id, at) values (v_uid, now());
  end if;
end $$;

-- Requests from the site (current_user authenticated or anon) get the
-- author, the checks and the brake; the SQL editor only gets the trimmed
-- text and the time. Not security definer, like stamp_announcement.
create or replace function public.stamp_community_message()
returns trigger language plpgsql set search_path = public as $$
begin
  new.body := trim_blank(new.body);
  new.created_at := now();
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  new.author_id := auth.uid();
  perform check_board_write(new.league_id);
  return new;
end $$;
drop trigger if exists community_message_stamp on public.community_messages;
create trigger community_message_stamp before insert on public.community_messages
  for each row execute function public.stamp_community_message();

alter table public.community_messages enable row level security;
drop policy if exists "board members read" on public.community_messages;
drop policy if exists "board members write" on public.community_messages;
drop policy if exists "board delete" on public.community_messages;
-- Active members, the organizers (the creator included) and the site admin;
-- an author always sees their own messages, so a player who left can still
-- delete them (a delete with a filter needs the row to be readable).
create policy "board members read" on public.community_messages
  for select to authenticated
  using (is_active_member(league_id) or is_league_admin(league_id) or is_site_admin()
         or author_id = auth.uid());
-- The trigger gives the clear refusals; this is the backstop.
create policy "board members write" on public.community_messages
  for insert to authenticated
  with check (author_id = auth.uid()
              and (is_active_member(league_id) or is_league_owner(league_id))
              and not coalesce((auth.jwt()->>'is_anonymous')::boolean, false));
-- The author, the community's organizers, the site admin.
create policy "board delete" on public.community_messages
  for delete to authenticated
  using (author_id = auth.uid() or is_league_admin(league_id) or is_site_admin());

revoke all on public.community_messages from anon, authenticated;
grant select, delete on public.community_messages to authenticated;
grant insert (league_id, body) on public.community_messages to authenticated;
grant select, insert, update, delete on public.community_messages to service_role;

-- 3. erase_user_data(): as in the MULTIPLAYER MATCHES section, plus the
-- account's board messages and brake log.
create or replace function erase_user_data(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  l record;
  v_t record;
  v_e jsonb;
  v_k text;
  v_g record;
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
  delete from feedback       where user_id = p_user;
  delete from site_admins    where user_id = p_user;
  delete from member_discord where user_id = p_user;
  delete from duel_join_attempts where user_id = p_user;
  delete from t_auto_log     where user_id = p_user;
  delete from community_messages where author_id = p_user;
  delete from community_message_writes where author_id = p_user;

  update duels
     set status = 'cancelled', pin = null, ended_at = coalesce(ended_at, now()), updated_at = now()
   where status in ('waiting','live','ending') and (host_id = p_user or guest_id = p_user);

  begin
    perform gm_drop_waiting(p_user, null);
    for v_g in
      select g.id
        from group_matches g
        join group_match_seats s on s.match_id = g.id
       where s.user_id = p_user and s.left_at is null and g.status in ('live','ending')
       order by g.id
    loop
      perform gm_freeze(v_g.id, p_user);
    end loop;
  exception when others then
    raise warning 'erase_user_data group matches: %', sqlerrm;
  end;

  update tournaments set organizer_id = null where organizer_id = p_user;
  begin
    for v_t in
      select x.id, x.payload
        from tournaments x
       where x.status is not null
         and x.payload->'entrants' @> jsonb_build_array(jsonb_build_object('id', p_user::text))
       order by x.created_at
       for update
    loop
      select q.x into v_e
        from jsonb_array_elements(v_t.payload->'entrants') q(x)
       where q.x->>'id' = p_user::text
       limit 1;
      v_k := case when coalesce(v_e->>'pid', '') ~ '^[A-Za-z0-9]{6,32}$'
                       and not (v_t.payload->'entrants' @> jsonb_build_array(jsonb_build_object('id', 'pn:' || (v_e->>'pid'))))
                  then 'pn:' || (v_e->>'pid') else t_rand_key(v_t.payload) end;
      update tournaments set payload = t_rekey(payload, p_user::text, v_k), rev = rev + 1 where id = v_t.id;
    end loop;
  exception when others then
    raise warning 'erase_user_data tournaments: %', sqlerrm;
  end;
  delete from decks            where user_id = p_user and not is_public;
  delete from tournament_decks where user_id = p_user;

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
         matches_visibility = 'private',
         deleted_at = coalesce(deleted_at, now())
   where id = p_user;
end $$;

revoke all on function erase_user_data(uuid)                        from public, anon, authenticated;
revoke all on function public.check_board_write(uuid)               from public, anon;
grant execute on function public.check_board_write(uuid)            to authenticated;

-- ============================================================
--  PLAY NETWORK DECKLISTS (2026-11-19)
-- ============================================================
-- Run as migration-2026-11-19-pn-decklists.sql.
-- What changes:
--   * Decks from the Play Network. When the organizer updates the players
--     of a tournament in registration from its Play Network event, the
--     edge function play-network-event also reads each registrant's deck
--     (the one locked for the event, checked against Play Network's own
--     hashes), avatar and Discord handle, and hands them to t_import.
--     Play Network shows decks only once the event has started there; until
--     then decks already imported are kept as they are.
--   * New table tournament_pn: one row per Play Network registrant of a
--     tournament (by profile id): Discord handle, deck name and link,
--     Seeker, terrain, legacy, card list (our names), status ('locked',
--     'linked' or 'partial': read in part, Seeker and terrain still exact),
--     the lock key (sha256 of the locked main and side check hashes), and
--     the names of cards the site does not know (at most 20, with their
--     number). RLS on and no policies: nobody reads it
--     directly, card lists never reach a page. Rows go with the tournament,
--     and with the player when they leave the list or are forgotten.
--   * tournament_decks gains src ('mine' or 'pn') and pn_pid. The deck of a
--     player whose seat has an account is copied from tournament_pn into
--     tournament_decks (src 'pn', no deck_id) by the new helper t_pn_sync,
--     called by the trigger t_auto_before whenever the players change (and
--     at the start, before the lock). So t_duel_start, t_duel_accept and the
--     start-time lock work unchanged. Before the start a Play Network deck
--     replaces a deck registered by hand; once running, a deck already
--     there stays and a new copy (a seat linked to its account) is locked
--     at once. A player whose Play Network deck goes away (decks shown and
--     none linked) goes back to registering one by hand.
--   * t_import: as in the SWISS TOURNAMENTS section, plus av, dc and dk on
--     each registrant and p_meta.decks / p_meta.pre (see the function).
--     Avatars (https://malediction.gg/wp-content/uploads/... only) go on
--     the players of the payload as av, shown next to the name. The Discord
--     handle never goes in the payload. Import counts go in payload.pn.dk.
--   * t_deck_set refuses ('pn') a player whose deck comes from the Play
--     Network. t_deck_get: mine gains src, url, st, main and side (card
--     counts); org gains src, st, url, unk_n, unk and dc per player, and
--     covers players without an account; the new opp gives a player the
--     Discord handle of their opponent in the current round. t_deck_pub
--     (at close) also writes the Seeker and terrain of players without an
--     account from tournament_pn.
--   * Visibility (unchanged rules, new data): card lists never leave the
--     server. Seeker and terrain: the organizer and the player while in
--     registration or running, everyone after the close. Unknown card
--     names: the organizer. Discord handles: the organizer (all) and each
--     player (only the opponent of their current game). Avatars: everyone
--     who sees the tournament.
--   * A tournament in registration has no fmt yet (t_start sets it), so
--     t_auto_before now also runs t_pn_sync for draft updates; its other
--     steps still look only at Swiss tournaments.
--   * New t_pn_save_deck(p_tid), for signed-in players: a player copies
--     their own imported deck into My decks (private, with the Play Network
--     link; a deck of theirs with the same Seeker and cards is the answer
--     instead of a new copy). Only their own list, into their own decks.
--   * Not changed: t_fetch_allow (imports end at the start), t_duel_start,
--     t_duel_accept, t_rekey, t_entrant, t_start, erase_user_data.

-- 1. tournament_pn: what the Play Network page says about each registrant ------
-- One row per registrant (profile id) of a tournament, written by t_import
-- (service role) only. Deck fields are all set or all null (no deck).
-- cards holds the main deck plus the terrain and the legacy (as My decks),
-- side the side deck, both {name: copies} with the site's card names.
create table if not exists public.tournament_pn (
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  pid        text not null check (pid ~ '^[A-Za-z0-9]{6,32}$'),
  discord    text check (discord is null or char_length(discord) between 2 and 40),
  deck_name  text check (deck_name is null or char_length(deck_name) between 1 and 80),
  deck_url   text check (deck_url is null or (char_length(deck_url) <= 300 and deck_url ~ '^https://(www\.)?malediction\.gg/play-network/decks/(view|snapshot)/[A-Za-z0-9/-]{1,250}/$')),
  seeker     text check (seeker is null or char_length(seeker) between 1 and 80),
  terrain    text check (terrain is null or char_length(terrain) between 1 and 80),
  legacy     text check (legacy is null or char_length(legacy) between 1 and 80),
  cards      jsonb check (cards is null or jsonb_typeof(cards) = 'object'),
  side       jsonb check (side is null or jsonb_typeof(side) = 'object'),
  deck_st    text check (deck_st is null or deck_st in ('locked','linked','partial')),
  lock_h     text check (lock_h is null or lock_h ~ '^[0-9a-f]{64}$'),
  unk        jsonb check (unk is null or (jsonb_typeof(unk) = 'array' and jsonb_array_length(unk) <= 20)),
  unk_n      int not null default 0 check (unk_n between 0 and 200),
  fetched_at timestamptz not null default now(),
  primary key (tournament_id, pid),
  constraint tournament_pn_deck_whole
    check ((seeker is null) = (terrain is null) and (seeker is null) = (cards is null)
           and (seeker is null) = (deck_st is null))
);
alter table public.tournament_pn enable row level security;
revoke all on public.tournament_pn from anon, authenticated;
grant select on public.tournament_pn to service_role;

-- tournament_decks: where a registration comes from. 'mine' (the player
-- picked one of their decks: t_deck_set) or 'pn' (copied from
-- tournament_pn by t_pn_sync: pn_pid is that registrant, deck_id is null).
alter table public.tournament_decks add column if not exists src text not null default 'mine';
alter table public.tournament_decks add column if not exists pn_pid text;
alter table public.tournament_decks drop constraint if exists tournament_decks_src;
alter table public.tournament_decks add constraint tournament_decks_src
  check (src in ('mine','pn') and (src = 'pn') = (pn_pid is not null) and (src = 'mine' or deck_id is null));

-- 2. Helpers (not callable over the API) ---------------------------------------
-- An avatar link: http(s)://(www.)malediction.gg/wp-content/uploads/...
-- .jpg/.jpeg/.png/.webp/.gif, at most 200 characters, no "..", stored as
-- https; anything else is null. The page checks the same rule again.
create or replace function public.t_pn_av(p text)
returns text language sql immutable security definer set search_path = public as $$
  select case when char_length(p) <= 200
               and p ~ '^https?://(www\.)?malediction\.gg/wp-content/uploads/[A-Za-z0-9/._-]{1,180}\.(jpe?g|png|webp|gif|JPE?G|PNG|WEBP|GIF)$'
               and position('..' in p) = 0
               and position('//' in regexp_replace(p, '^https?://', '')) = 0
              then regexp_replace(p, '^http://', 'https://') end;
$$;

-- A card list {name: copies}: an object of at most 64 names (each a clean
-- name of 1 to 80 characters), copies 1 to 9 each, at most p_max in all.
create or replace function public.t_pn_cards(p jsonb, p_max int)
returns boolean language plpgsql immutable security definer set search_path = public as $$
declare
  v_k text;
  v_v jsonb;
  v_n int := 0;
  v_c int := 0;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    return false;
  end if;
  for v_k, v_v in select e.key, e.value from jsonb_each(p) e loop
    v_c := v_c + 1;
    if v_c > 64 or duel_clean(v_k) is distinct from v_k or jsonb_typeof(v_v) <> 'number'
       or v_v::text !~ '^[1-9]$' then
      return false;
    end if;
    v_n := v_n + (v_v::text)::int;
  end loop;
  return v_n <= p_max;
end $$;

-- A registrant's deck as the edge function sends it (dk), checked again:
-- {n: deck name, u: link, s: Seeker, t: terrain, l: legacy or null,
--  c: main deck + terrain + legacy, sd: side deck, st: 'locked' | 'linked' |
--  'partial', h: the lock key (main and side hashes), k: unknown cards, unk: up to
--  20 of their names}. The normalised deck, or null when anything is off.
-- Limits: main 60 (c 62 with terrain and legacy), side 15, 9 copies.
create or replace function public.t_pn_deck(p jsonb)
returns jsonb language plpgsql immutable security definer set search_path = public as $$
declare
  v_s   text;
  v_t   text;
  v_l   text;
  v_n   text;
  v_u   text;
  v_h   text;
  v_k   int := 0;
  v_sd  jsonb;
  v_unk jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    return null;
  end if;
  if jsonb_typeof(p->'s') is distinct from 'string' or jsonb_typeof(p->'t') is distinct from 'string' then
    return null;
  end if;
  v_s := duel_clean(p->>'s');
  v_t := duel_clean(p->>'t');
  if v_s is null or v_t is null or v_s <> p->>'s' or v_t <> p->>'t' then
    return null;
  end if;
  if jsonb_typeof(p->'l') = 'string' then
    v_l := duel_clean(p->>'l');
    if v_l is null or v_l <> p->>'l' then
      return null;
    end if;
  elsif p ? 'l' and jsonb_typeof(p->'l') <> 'null' then
    return null;
  end if;
  if jsonb_typeof(p->'st') is distinct from 'string' or p->>'st' not in ('locked','linked','partial') then
    return null;
  end if;
  if not t_pn_cards(p->'c', 62) or not (p->'c' ? v_t) or (v_l is not null and not (p->'c' ? v_l)) then
    return null;
  end if;
  v_sd := case when jsonb_typeof(p->'sd') is null or jsonb_typeof(p->'sd') = 'null' then '{}'::jsonb else p->'sd' end;
  if not t_pn_cards(v_sd, 15) then
    return null;
  end if;
  if jsonb_typeof(p->'h') = 'string' and p->>'h' ~ '^[0-9a-f]{64}$' then
    v_h := p->>'h';
  elsif p ? 'h' and jsonb_typeof(p->'h') <> 'null' then
    return null;
  end if;
  if jsonb_typeof(p->'k') = 'number' and p->>'k' ~ '^[0-9]{1,3}$' and (p->>'k')::int <= 200 then
    v_k := (p->>'k')::int;
  elsif p ? 'k' and jsonb_typeof(p->'k') <> 'null' then
    return null;
  end if;
  if jsonb_typeof(p->'unk') = 'array' then
    if jsonb_array_length(p->'unk') > 20 or exists (
         select 1 from jsonb_array_elements(p->'unk') q(x)
          where jsonb_typeof(q.x) <> 'string' or duel_clean(q.x #>> '{}') is distinct from q.x #>> '{}') then
      return null;
    end if;
    v_unk := case when jsonb_array_length(p->'unk') > 0 then p->'unk' end;
  elsif p ? 'unk' and jsonb_typeof(p->'unk') <> 'null' then
    return null;
  end if;
  if v_unk is not null and v_k < jsonb_array_length(v_unk) then
    return null;
  end if;
  if jsonb_typeof(p->'n') = 'string' then
    v_n := duel_clean(p->>'n');
  end if;
  if jsonb_typeof(p->'u') = 'string' and char_length(p->>'u') <= 300
     and p->>'u' ~ '^https://(www\.)?malediction\.gg/play-network/decks/(view|snapshot)/[A-Za-z0-9/-]{1,250}/$' then
    v_u := p->>'u';
  end if;
  return jsonb_build_object('n', v_n, 'u', v_u, 's', v_s, 't', v_t, 'l', v_l, 'c', p->'c',
                            'sd', case when v_sd = '{}'::jsonb then null else v_sd end,
                            'st', p->>'st', 'h', v_h, 'k', v_k, 'unk', v_unk);
end $$;

-- t_pn_sync: tournament_pn and the Play Network copies in tournament_decks
-- follow the players of payload p (status p_status), in this order:
--   * the rows of registrants no longer in the list (removed on a full
--     import, forgotten, removed by hand) go;
--   * a copy held by an account that no longer has that seat (unlinked,
--     moved, or the registrant has no deck any more) goes;
--   * each seat held by an account (not deleted) whose registrant has a
--     deck gets it: in draft it replaces a deck registered by hand (or an
--     older copy); once running a row already there stays, and a new one
--     is locked at once.
-- Called by t_auto_before only.
create or replace function public.t_pn_sync(p_tid uuid, p jsonb, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_e jsonb := case when jsonb_typeof(p->'entrants') = 'array' then p->'entrants' else '[]'::jsonb end;
begin
  if p_tid is null then
    return;
  end if;
  delete from tournament_pn n
   where n.tournament_id = p_tid
     and not exists (select 1 from jsonb_array_elements(v_e) q(x)
                      where jsonb_typeof(q.x) = 'object' and q.x->>'pid' = n.pid);
  delete from tournament_decks k
   where k.tournament_id = p_tid and k.src = 'pn'
     and not exists (select 1
                       from jsonb_array_elements(v_e) q(x)
                       join tournament_pn n on n.tournament_id = p_tid and n.pid = q.x->>'pid' and n.seeker is not null
                      where jsonb_typeof(q.x) = 'object' and q.x->>'id' = k.user_id::text and n.pid = k.pn_pid);
  insert into tournament_decks (tournament_id, user_id, deck_id, name, seeker, terrain, cards, side,
                                registered_at, locked_at, src, pn_pid)
  select p_tid, pr.id, null, coalesce(n.deck_name, ''), n.seeker, n.terrain, n.cards, n.side,
         now(), case when p_status is distinct from 'draft' then now() end, 'pn', n.pid
    from (select distinct on (s.uid) s.uid, s.pid
            from (select case when t_acct(q.x->>'id') then (q.x->>'id')::uuid end as uid, q.x->>'pid' as pid
                    from jsonb_array_elements(v_e) q(x)
                   where jsonb_typeof(q.x) = 'object' and q.x->>'pid' is not null) s
           where s.uid is not null
           order by s.uid) e
    join tournament_pn n on n.tournament_id = p_tid and n.pid = e.pid and n.seeker is not null
    join profiles pr on pr.id = e.uid and pr.deleted_at is null
  on conflict (tournament_id, user_id) do update
     set deck_id = null, name = excluded.name, seeker = excluded.seeker, terrain = excluded.terrain,
         cards = excluded.cards, side = excluded.side, registered_at = excluded.registered_at,
         src = 'pn', pn_pid = excluded.pn_pid
   where p_status = 'draft'
     and (tournament_decks.src <> 'pn' or tournament_decks.pn_pid is distinct from excluded.pn_pid
          or (tournament_decks.name, tournament_decks.seeker, tournament_decks.terrain,
              tournament_decks.cards, tournament_decks.side)
             is distinct from (excluded.name, excluded.seeker, excluded.terrain, excluded.cards, excluded.side));
end $$;

-- 3. t_import -------------------------------------------------------------------
-- t_import: as in the SWISS TOURNAMENTS section, plus, when p_meta.decks is
-- 'shown' or 'hidden' (the edge function read the members list; without it,
-- an older function, nothing below happens and avatars stay as they are):
--   * each p_regs item may carry av (avatar link, checked by t_pn_av, else
--     none), dc (Discord handle, 2 to 40 characters, else none) and dk (the
--     deck: {keep:true}, optionally with n and u, or the deck checked by
--     t_pn_deck; a deck that fails the checks counts as bad and as no
--     deck);
--   * the players of the list get av (or lose it) by profile id, new ones
--     with it, and the payload stays within 1 MB;
--   * for each registrant who is in the list, its tournament_pn row is
--     written: the Discord handle always; with 'shown' also the deck (keep
--     leaves the stored cards and, with n and u, updates only the deck's
--     name and link; no dk means no deck: that player registers one by
--     hand); with 'hidden' (Play Network does not show decks yet)
--     the deck stored earlier stays. Rows of players not on a partial list
--     are left alone; the trigger (t_pn_sync) removes those of players who
--     left the list;
--   * payload.pn.dk = {n (registrants with a deck), miss (without one), unk
--     (cards not known, in all), part (decks read in part), hid (decks
--     hidden), pre (p_meta.pre: registrants who linked a deck on Play
--     Network)}, and the answer gains decks {n, miss, unk, part, bad}.
-- Only service_role can call it (grants unchanged).
create or replace function public.t_import(p_tid uuid, p_regs jsonb, p_count int, p_meta jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_t       tournaments%rowtype;
  v_p       jsonb;
  v_reg     jsonb;
  v_regs    jsonb := '[]'::jsonb;
  v_seen    text[] := '{}';
  v_pid     text;
  v_name    text;
  v_full    boolean;
  v_ents    jsonb := '[]'::jsonb;
  v_e       jsonb;
  v_added   int := 0;
  v_removed int := 0;
  v_linked  int;
  v_warn    text;
  v_meta    jsonb := '{}'::jsonb;
  v_gmode   text;
  v_rev     int;
  v_new     boolean := jsonb_typeof(p_meta) = 'object' and coalesce(p_meta->>'decks' in ('shown','hidden'), false);
  v_shown   boolean := jsonb_typeof(p_meta) = 'object' and coalesce(p_meta->>'decks' = 'shown', false);
  v_av      text;
  v_dc      text;
  v_dk      jsonb;
  v_bad     int := 0;
  v_pre     int;
  v_dkc     jsonb;
begin
  if p_tid is null or p_regs is null or jsonb_typeof(p_regs) is distinct from 'array' then
    return t_no('bad_input', 'The list of players is not valid.');
  end if;
  select * into v_t from tournaments x where x.id = p_tid for update;
  if not found or v_t.status is null then
    return t_no('not_allowed', 'This tournament was not found.');
  end if;
  if v_t.status <> 'draft' then
    return t_no('started', 'The tournament has started, so its list of players is fixed.');
  end if;
  if exists (select 1 from leagues l where l.id = v_t.league_id and l.archived_at is not null) then
    return t_no('archived', 'This community is archived.');
  end if;
  v_p := v_t.payload - 'nx';

  -- the event settings
  if jsonb_typeof(p_meta) = 'object' then
    v_gmode := coalesce(p_meta->>'game_mode', p_meta->>'gmode');
    v_meta := jsonb_build_object(
      'rounds', case when coalesce(p_meta->>'rounds', '') ~ '^[0-9]{1,3}$'
                          and (p_meta->>'rounds')::int between 1 and 100 then (p_meta->>'rounds')::int end,
      'system', case when p_meta->>'system' in ('Swiss','League') then p_meta->>'system' end,
      'minutes', case when coalesce(p_meta->>'minutes', '') ~ '^[0-9]{1,4}$'
                           and (p_meta->>'minutes')::int between 1 and 1440 then (p_meta->>'minutes')::int end,
      'gmode', case when v_gmode in ('1x1','2x2') then v_gmode end);
    v_pre := case when jsonb_typeof(p_meta->'pre') = 'number' and p_meta->>'pre' ~ '^[0-9]{1,5}$'
                  then (p_meta->>'pre')::int end;
  end if;

  -- the registrants: valid public ids, each once; with their avatar,
  -- Discord handle and deck when the function sent them
  for v_reg in select q.x from jsonb_array_elements(p_regs) with ordinality q(x, o) order by q.o limit 1000 loop
    if jsonb_typeof(v_reg) is distinct from 'object' then
      continue;
    end if;
    v_pid := v_reg->>'pid';
    if v_pid is null or v_pid !~ '^[A-Za-z0-9]{6,32}$' or v_pid = any(v_seen) then
      continue;
    end if;
    v_seen := v_seen || v_pid;
    v_name := coalesce(t_clean_name(v_reg->>'name'), 'Player');
    if v_new then
      v_av := case when jsonb_typeof(v_reg->'av') = 'string' then t_pn_av(v_reg->>'av') end;
      v_dc := case when jsonb_typeof(v_reg->'dc') = 'string' then t_clean_name(v_reg->>'dc') end;
      if char_length(v_dc) < 2 or char_length(v_reg->>'dc') > 40 then
        v_dc := null;
      end if;
      v_dk := null;
      if jsonb_typeof(v_reg->'dk') = 'object' and (v_reg->'dk'->'keep') = 'true'::jsonb then
        v_dk := '{"keep":true}'::jsonb;
        -- keep with the deck's current name and link (n, u): the cards stay,
        -- the name and the link are updated (checked as in t_pn_deck)
        if (v_reg->'dk') ? 'n' or (v_reg->'dk') ? 'u' then
          v_dk := v_dk || jsonb_build_object('ren', true,
                    'n', case when jsonb_typeof(v_reg->'dk'->'n') = 'string' then duel_clean(v_reg->'dk'->>'n') end,
                    'u', case when jsonb_typeof(v_reg->'dk'->'u') = 'string' and char_length(v_reg->'dk'->>'u') <= 300
                                   and v_reg->'dk'->>'u' ~ '^https://(www\.)?malediction\.gg/play-network/decks/(view|snapshot)/[A-Za-z0-9/-]{1,250}/$'
                              then v_reg->'dk'->>'u' end);
        end if;
      elsif v_reg ? 'dk' and jsonb_typeof(v_reg->'dk') is distinct from 'null' then
        v_dk := t_pn_deck(v_reg->'dk');
        if v_dk is null then
          v_bad := v_bad + 1;
        end if;
      end if;
      v_regs := v_regs || jsonb_build_array(jsonb_build_object('pid', v_pid, 'name', v_name,
                                                               'av', v_av, 'dc', v_dc, 'dk', v_dk));
    else
      v_regs := v_regs || jsonb_build_array(jsonb_build_object('pid', v_pid, 'name', v_name));
    end if;
  end loop;
  v_full := p_count is not null and p_count = cardinality(v_seen);

  -- the players already in the list
  for v_e in select q.x from jsonb_array_elements(coalesce(v_p->'entrants', '[]'::jsonb)) with ordinality q(x, o) order by q.o loop
    if v_e->>'src' = 'pn' and v_e->>'pid' is not null then
      if not (v_e->>'pid' = any(v_seen)) then
        if not v_full then
          v_ents := v_ents || jsonb_build_array(v_e);
          continue;
        end if;
        if (v_e->>'lock') = 'true' then
          insert into tournament_marks (tournament_id, pid_hash, kind)
          values (p_tid, t_pid_hash(p_tid, v_e->>'pid'), 'lock')
          on conflict do nothing;
        end if;
        v_removed := v_removed + 1;
        continue;
      end if;
      v_e := v_e || jsonb_build_object('name', (select z.x->>'name' from jsonb_array_elements(v_regs) z(x)
                                                 where z.x->>'pid' = v_e->>'pid' limit 1));
    end if;
    if v_new and v_e->>'pid' is not null and v_e->>'pid' = any(v_seen) then
      v_av := (select z.x->>'av' from jsonb_array_elements(v_regs) z(x) where z.x->>'pid' = v_e->>'pid' limit 1);
      v_e := case when v_av is not null then v_e || jsonb_build_object('av', v_av) else v_e - 'av' end;
    end if;
    v_ents := v_ents || jsonb_build_array(v_e);
  end loop;

  -- the new registrants
  for v_reg in select q.x from jsonb_array_elements(v_regs) with ordinality q(x, o) order by q.o loop
    if v_ents @> jsonb_build_array(jsonb_build_object('pid', v_reg->>'pid')) then
      continue;
    end if;
    if exists (select 1 from tournament_marks k
                where k.tournament_id = p_tid and k.kind = 'forget'
                  and k.pid_hash = t_pid_hash(p_tid, v_reg->>'pid')) then
      continue;
    end if;
    if jsonb_array_length(v_ents) >= 256 then
      v_warn := 'too_many';
      exit;
    end if;
    v_ents := v_ents || jsonb_build_array(jsonb_build_object(
                'id', 'pn:' || (v_reg->>'pid'), 'name', v_reg->>'name', 'pid', v_reg->>'pid',
                'src', 'pn', 'st', 'in', 'seeker', '', 'terrain', '', 'deck', '', 'deckId', '')
                || case when exists (select 1 from tournament_marks k
                                      where k.tournament_id = p_tid and k.kind = 'lock'
                                        and k.pid_hash = t_pid_hash(p_tid, v_reg->>'pid'))
                        then '{"lock":true}'::jsonb else '{}'::jsonb end
                || case when v_reg->>'av' is not null then jsonb_build_object('av', v_reg->>'av')
                        else '{}'::jsonb end);
    v_added := v_added + 1;
  end loop;

  v_p := jsonb_set(v_p, '{entrants}', v_ents);
  select q.r, q.linked into v_p, v_linked from t_link_all(v_p) q;
  if octet_length(v_p::text) > 1048576 - 4096 then
    return t_no('bad_input', 'This tournament is too large.');
  end if;

  -- what the Play Network says about each registrant in the list
  if v_new then
    for v_reg in select z.x from jsonb_array_elements(v_regs) z(x)
                  where v_p->'entrants' @> jsonb_build_array(jsonb_build_object('pid', z.x->>'pid')) loop
      insert into tournament_pn (tournament_id, pid, discord, fetched_at)
      values (p_tid, v_reg->>'pid', v_reg->>'dc', now())
      on conflict (tournament_id, pid) do update
         set discord = excluded.discord, fetched_at = excluded.fetched_at;
      v_dk := case when jsonb_typeof(v_reg->'dk') = 'object' then v_reg->'dk' end;
      if v_shown and v_dk ? 'keep' and (v_dk->>'ren') = 'true' then
        update tournament_pn
           set deck_name = v_dk->>'n', deck_url = v_dk->>'u'
         where tournament_id = p_tid and pid = v_reg->>'pid' and seeker is not null;
      elsif v_shown and (v_dk is null or not (v_dk ? 'keep')) then
        update tournament_pn
           set deck_name = v_dk->>'n', deck_url = v_dk->>'u', seeker = v_dk->>'s', terrain = v_dk->>'t',
               legacy = v_dk->>'l', cards = v_dk->'c',
               side = case when jsonb_typeof(v_dk->'sd') = 'object' then v_dk->'sd' end,
               deck_st = v_dk->>'st', lock_h = v_dk->>'h',
               unk = case when jsonb_typeof(v_dk->'unk') = 'array' then v_dk->'unk' end,
               unk_n = coalesce((v_dk->>'k')::int, 0)
         where tournament_id = p_tid and pid = v_reg->>'pid';
      end if;
    end loop;
    select jsonb_build_object('n', count(*) filter (where n.seeker is not null),
                              'miss', count(*) filter (where n.seeker is null),
                              'unk', coalesce(sum(n.unk_n) filter (where n.seeker is not null), 0),
                              'part', count(*) filter (where n.deck_st = 'partial'))
      into v_dkc
      from tournament_pn n
     where n.tournament_id = p_tid
       and n.pid in (select z.x->>'pid' from jsonb_array_elements(v_regs) z(x));
  end if;

  v_p := jsonb_set(v_p, '{pn}', coalesce(v_p->'pn', '{}'::jsonb)
                                || jsonb_build_object('at', now(),
                                                      'n', case when p_count between 0 and 100000 then p_count end)
                                || v_meta
                                || case when v_new then jsonb_build_object('dk', v_dkc || jsonb_build_object(
                                                          'hid', not v_shown, 'pre', v_pre))
                                        else '{}'::jsonb end);
  update tournaments set payload = v_p, rev = rev + 1 where id = p_tid returning rev into v_rev;
  return jsonb_build_object('ok', true, 'rev', v_rev, 'total', cardinality(v_seen),
                            'added', v_added, 'removed', v_removed, 'linked', v_linked)
         || case when v_warn is not null then jsonb_build_object('warning', v_warn) else '{}'::jsonb end
         || case when v_new then jsonb_build_object('decks', v_dkc || jsonb_build_object('bad', v_bad))
                 else '{}'::jsonb end;
end $$;

-- 4. t_auto_before ---------------------------------------------------------------
-- t_auto_before: as in the TOURNAMENT AUTOMATION section (its steps still
-- look only at Swiss tournaments), plus the Play Network decks:
--   draft -> running    t_pn_sync (as in draft) first, so the lock that
--                       follows covers the Play Network copies too
--   any other update of a Swiss tournament, or of a tournament in draft
--   (which has no fmt yet), that changes the players or payload.pn
--   (t_import, unlink, relink, forget, remove, drop, a profile link):
--                       the avatar of a player who has no profile id any
--                       more (forgotten) goes, then t_pn_sync
-- A failure in either part never stops the change (a warning only).
create or replace function public.t_auto_before()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_oc int;
  v_nc int;
  v_h  jsonb;
  v_sw boolean;
begin
  if new.status is null then
    return new;
  end if;
  v_sw := coalesce(coalesce(new.payload->>'fmt', old.payload->>'fmt') = 'swiss', false);
  if not v_sw and new.status is distinct from 'draft' then
    return new;
  end if;
  if v_sw and old.status = 'draft' and new.status = 'running' then
    begin
      perform t_pn_sync(new.id, new.payload, 'draft');
    exception when others then
      raise warning 't_auto_before (play network decks): %', sqlerrm;
    end;
  end if;
  if v_sw then
    begin
      if old.status = 'draft' and new.status = 'running' then
        update tournament_decks k
           set name = coalesce(d.name, ''), seeker = duel_clean(d.seeker), cards = d.cards, side = d.side
          from decks d
         where k.tournament_id = new.id and d.id = k.deck_id and d.user_id = k.user_id
           and duel_clean(d.seeker) is not null and jsonb_typeof(d.cards) = 'object'
           and coalesce(d.cards->>k.terrain, '') ~ '^[1-9][0-9]{0,3}$';
        update tournament_decks set locked_at = now() where tournament_id = new.id;
        new.payload := t_deck_hide(new.payload) - 'hold' - 'auto' - 'ac';
      elsif old.status = 'running' and new.status = 'draft' then
        update tournament_decks set locked_at = null where tournament_id = new.id;
        new.payload := t_deck_hide(new.payload) - 'hold' - 'auto' - 'ac';
      elsif old.status = 'running' and new.status = 'running' then
        v_oc := t_sw_cur(old.payload);
        v_nc := t_sw_cur(new.payload);
        v_h := case when jsonb_typeof(new.payload->'hold') = 'object' then new.payload->'hold' else '{}'::jsonb end;
        if v_nc < v_oc then
          new.payload := new.payload || jsonb_build_object('hold', v_h || jsonb_build_object('pair', v_oc));
          if (new.payload #>> '{auto,r}') = v_oc::text then
            new.payload := new.payload - 'auto';
          end if;
        elsif v_nc > v_oc and (new.payload #>> '{auto,r}') is distinct from v_nc::text and v_h ? 'pair' then
          v_h := v_h - 'pair';
          new.payload := case when v_h = '{}'::jsonb then new.payload - 'hold'
                              else new.payload || jsonb_build_object('hold', v_h) end;
        end if;
      elsif old.status = 'running' and new.status = 'closed' then
        new.payload := t_deck_pub(new.payload, new.id);
      elsif old.status = 'closed' and new.status = 'running' then
        v_h := case when jsonb_typeof(new.payload->'hold') = 'object' then new.payload->'hold' else '{}'::jsonb end;
        v_nc := t_sw_cur(new.payload);
        if v_nc < (case when new.payload->>'rounds' ~ '^[0-9]{1,3}$' then (new.payload->>'rounds')::int else 0 end) then
          v_h := v_h || jsonb_build_object('pair', v_nc + 1);
        end if;
        new.payload := t_deck_hide(new.payload) - 'ac'
                       || jsonb_build_object('hold', v_h || '{"close":true}'::jsonb);
      end if;
    exception when others then
      raise warning 't_auto_before: %', sqlerrm;
    end;
  end if;
  if not (old.status = 'draft' and new.status = 'running')
     and (old.payload->'entrants' is distinct from new.payload->'entrants'
          or old.payload->'pn' is distinct from new.payload->'pn') then
    begin
      if jsonb_typeof(new.payload->'entrants') = 'array'
         and exists (select 1 from jsonb_array_elements(new.payload->'entrants') q(x)
                      where jsonb_typeof(q.x) = 'object' and q.x ? 'av' and q.x->>'pid' is null) then
        new.payload := new.payload || jsonb_build_object('entrants', (
          select jsonb_agg(case when jsonb_typeof(q.x) = 'object' and q.x ? 'av' and q.x->>'pid' is null
                                then q.x - 'av' else q.x end order by q.o)
            from jsonb_array_elements(new.payload->'entrants') with ordinality q(x, o)));
      end if;
      perform t_pn_sync(new.id, new.payload, new.status);
    exception when others then
      raise warning 't_auto_before (play network decks): %', sqlerrm;
    end;
  end if;
  return new;
end $$;

-- 5. Players: the registered deck ------------------------------------------------
-- t_deck_set: as in the TOURNAMENT AUTOMATION section, plus: a player whose
-- registration comes from the Play Network (src 'pn') is refused ('pn'),
-- before the start and while running; a deck set here is src 'mine'.
create or replace function public.t_deck_set(p_tid uuid, p_deck_id uuid, p_terrain text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_t   tournaments%rowtype;
  v_e   jsonb;
  v_k   decks%rowtype;
  v_has boolean;
  v_ter text := btrim(coalesce(p_terrain, ''));
  v_row tournament_decks%rowtype;
begin
  if v_uid is null or coalesce((auth.jwt()->>'is_anonymous')::boolean, false)
     or not exists (select 1 from profiles pr where pr.id = v_uid and pr.deleted_at is null) then
    return t_no('not_allowed', 'Sign in first.');
  end if;
  select * into v_t from tournaments x where x.id = p_tid for update;
  if not found or v_t.status is null then
    return t_no('not_allowed', 'This tournament was not found.');
  end if;
  if not (v_t.status = 'draft' or (v_t.status = 'running' and v_t.payload->>'fmt' = 'swiss')) then
    return t_no('status', 'Decks are registered before the start, or during a Swiss tournament before your first game.');
  end if;
  select q.x into v_e
    from jsonb_array_elements(coalesce(v_t.payload->'entrants', '[]'::jsonb)) q(x)
   where q.x->>'id' = v_uid::text
   limit 1;
  if v_e is null then
    return t_no('not_entrant', 'Link your malediction.gg profile in Account › Profile, then ask the organizer to add you.');
  end if;
  if v_e->>'st' = 'drop' then
    return t_no('dropped', 'You have dropped from this tournament.');
  end if;
  select * into v_row from tournament_decks k where k.tournament_id = p_tid and k.user_id = v_uid;
  v_has := found;
  if v_has and v_row.src = 'pn' then
    return t_no('pn', 'Your deck comes from your Play Network registration.');
  end if;
  if v_t.status = 'running' and v_has then
    return t_no('locked', 'Your deck is locked for this tournament.');
  end if;
  if v_t.status = 'draft' and p_deck_id is null then
    delete from tournament_decks where tournament_id = p_tid and user_id = v_uid;
    return jsonb_build_object('ok', true, 'deck', null);
  end if;
  select * into v_k from decks k where k.id = p_deck_id and k.user_id = v_uid;
  if not found then
    return t_no('not_yours', 'Pick one of your own decks.');
  end if;
  if duel_clean(v_k.seeker) is null then
    return t_no('no_seeker', 'This deck has no Seeker.');
  end if;
  if duel_clean(v_ter) is null or jsonb_typeof(v_k.cards) is distinct from 'object'
     or coalesce(v_k.cards->>v_ter, '') !~ '^[1-9][0-9]{0,3}$' then
    return t_no('no_terrain', 'This deck has no terrain.');
  end if;
  insert into tournament_decks (tournament_id, user_id, deck_id, name, seeker, terrain, cards, side,
                                registered_at, locked_at, src, pn_pid)
  values (p_tid, v_uid, v_k.id, coalesce(v_k.name, ''), duel_clean(v_k.seeker), duel_clean(v_ter), v_k.cards, v_k.side,
          now(), case when v_t.status = 'running' then now() end, 'mine', null)
  on conflict (tournament_id, user_id) do update
     set deck_id = excluded.deck_id, name = excluded.name, seeker = excluded.seeker,
         terrain = excluded.terrain, cards = excluded.cards, side = excluded.side,
         registered_at = excluded.registered_at, locked_at = excluded.locked_at,
         src = 'mine', pn_pid = null
  returning * into v_row;
  return jsonb_build_object('ok', true, 'deck', jsonb_build_object(
           'deck_id', v_row.deck_id, 'name', v_row.name, 'seeker', v_row.seeker,
           'terrain', v_row.terrain, 'locked', v_row.locked_at is not null));
end $$;

-- t_deck_get: as in the TOURNAMENT AUTOMATION section, plus:
--   mine  also src ('mine' or 'pn'), url (the deck's Play Network link),
--         st ('locked', 'linked' or 'partial'), main and side (card
--         counts, main without Seeker, terrain and legacy, as My decks counts it)
--         for a Play Network deck;
--         changed is false for a Play Network deck;
--   can   'pn' when the caller's deck comes from the Play Network;
--   org   (organizer only) each player also has src, st, url, unk_n, unk
--         (names of cards the site does not know, at most 20) and dc (the
--         Discord handle); a player without an account is registered when
--         their Play Network registration has a deck (Seeker and terrain
--         from it);
--   opp   while a Swiss tournament runs, for a player with an account: the
--         opponent of their current game, {id, dc}, when that opponent's
--         Play Network registration has a Discord handle; else null.
-- Never a card list.
create or replace function public.t_deck_get(p_tid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid  uuid := auth.uid();
  v_t    tournaments%rowtype;
  v_e    jsonb;
  v_org  boolean;
  v_row  tournament_decks%rowtype;
  v_n    tournament_pn%rowtype;
  v_has  boolean := false;
  v_can  text;
  v_mine jsonb;
  v_list jsonb;
  v_opp  jsonb;
  v_ok   text;
  v_dc   text;
begin
  select * into v_t from tournaments x where x.id = p_tid;
  if not found or v_t.status is null then
    return t_no('not_allowed', 'This tournament was not found.');
  end if;
  v_org := coalesce(t_is_org(v_t), false);
  if v_uid is not null then
    select q.x into v_e
      from jsonb_array_elements(coalesce(v_t.payload->'entrants', '[]'::jsonb)) q(x)
     where q.x->>'id' = v_uid::text
     limit 1;
  end if;
  if not v_org and v_e is null
     and not coalesce(is_league_member(v_t.league_id) or league_is_public(v_t.league_id), false) then
    return t_no('not_allowed', 'This tournament was not found.');
  end if;
  if v_e is not null then
    select * into v_row from tournament_decks k where k.tournament_id = p_tid and k.user_id = v_uid;
    v_has := found;
  end if;
  v_can := case when not (v_t.status = 'draft' or (v_t.status = 'running' and v_t.payload->>'fmt' = 'swiss')) then 'status'
                when v_e is null or coalesce((auth.jwt()->>'is_anonymous')::boolean, false) then 'not_entrant'
                when v_e->>'st' = 'drop' then 'dropped'
                when v_has and v_row.src = 'pn' then 'pn'
                when v_t.status = 'running' and v_has then 'locked'
                else 'ok' end;
  if v_has then
    if v_row.src = 'pn' then
      select * into v_n from tournament_pn n where n.tournament_id = p_tid and n.pid = v_row.pn_pid;
    end if;
    v_mine := jsonb_build_object(
      'deck_id', v_row.deck_id, 'name', v_row.name, 'seeker', v_row.seeker, 'terrain', v_row.terrain,
      'locked', v_row.locked_at is not null,
      'changed', v_row.src = 'mine'
                 and (v_row.deck_id is null
                      or exists (select 1 from decks k
                                  where k.id = v_row.deck_id
                                    and (k.cards is distinct from v_row.cards or k.side is distinct from v_row.side
                                         or duel_clean(k.seeker) is distinct from v_row.seeker))),
      'src', v_row.src,
      'url', case when v_row.src = 'pn' then v_n.deck_url end,
      'st', case when v_row.src = 'pn' then v_n.deck_st end,
      'main', case when v_row.src = 'pn' then
                (select coalesce(sum((e.value #>> '{}')::int), 0) from jsonb_each(v_row.cards) e
                  where (e.value #>> '{}') ~ '^[0-9]{1,4}$')
                - case when v_row.cards ? v_row.terrain then 1 else 0 end
                - case when v_row.seeker is distinct from v_row.terrain and v_row.seeker is distinct from v_n.legacy
                        and (v_row.cards->>v_row.seeker) ~ '^[0-9]{1,4}$'
                       then (v_row.cards->>v_row.seeker)::int else 0 end
                - case when v_n.legacy is not null and v_row.cards ? v_n.legacy then 1 else 0 end end,
      'side', case when v_row.src = 'pn' then
                (select coalesce(sum((e.value #>> '{}')::int), 0)
                   from jsonb_each(case when jsonb_typeof(v_row.side) = 'object' then v_row.side else '{}'::jsonb end) e
                  where (e.value #>> '{}') ~ '^[0-9]{1,4}$') end);
  end if;
  if v_org then
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', q.x->>'id',
             'registered', k.user_id is not null or (not t_acct(q.x->>'id') and n.seeker is not null),
             'seeker', case when k.user_id is not null then k.seeker when not t_acct(q.x->>'id') then n.seeker end,
             'terrain', case when k.user_id is not null then k.terrain when not t_acct(q.x->>'id') then n.terrain end,
             'src', case when k.user_id is not null then k.src
                         when not t_acct(q.x->>'id') and n.seeker is not null then 'pn' end,
             'st', case when (k.user_id is not null and k.src = 'pn') or (k.user_id is null and not t_acct(q.x->>'id'))
                        then n.deck_st end,
             'url', case when (k.user_id is not null and k.src = 'pn') or (k.user_id is null and not t_acct(q.x->>'id'))
                         then n.deck_url end,
             'unk_n', case when (k.user_id is not null and k.src = 'pn') or (k.user_id is null and not t_acct(q.x->>'id'))
                           then coalesce(n.unk_n, 0) else 0 end,
             'unk', case when (k.user_id is not null and k.src = 'pn') or (k.user_id is null and not t_acct(q.x->>'id'))
                         then n.unk end,
             'dc', n.discord) order by q.o), '[]'::jsonb)
      into v_list
      from jsonb_array_elements(coalesce(v_t.payload->'entrants', '[]'::jsonb)) with ordinality q(x, o)
      left join tournament_decks k on k.tournament_id = p_tid and k.user_id::text = q.x->>'id'
      left join tournament_pn n on n.tournament_id = p_tid and n.pid = q.x->>'pid';
  end if;
  if v_e is not null and v_t.status = 'running' and v_t.payload->>'fmt' = 'swiss'
     and not coalesce((auth.jwt()->>'is_anonymous')::boolean, false) then
    select g.opp into v_ok from t_my_game(v_t.payload, v_uid::text) g;
    if v_ok is not null then
      select n.discord into v_dc
        from jsonb_array_elements(coalesce(v_t.payload->'entrants', '[]'::jsonb)) q(x)
        join tournament_pn n on n.tournament_id = p_tid and n.pid = q.x->>'pid'
       where q.x->>'id' = v_ok
       limit 1;
      if v_dc is not null then
        v_opp := jsonb_build_object('id', v_ok, 'dc', v_dc);
      end if;
    end if;
  end if;
  return jsonb_build_object('ok', true, 'status', v_t.status, 'mine', v_mine, 'can', v_can, 'org', v_list,
                            'opp', v_opp);
end $$;

-- t_deck_pub: as in the TOURNAMENT AUTOMATION section; a player without a
-- registration in tournament_decks (no account) gets the Seeker and terrain
-- of their Play Network deck, if any.
create or replace function public.t_deck_pub(p jsonb, p_tid uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when jsonb_typeof(p->'entrants') is distinct from 'array' then p else
    p || jsonb_build_object('entrants', coalesce((
           select jsonb_agg(case when jsonb_typeof(q.x) = 'object'
                                 then q.x || jsonb_build_object('seeker', coalesce(k.seeker, n.seeker, ''),
                                                                'terrain', coalesce(k.terrain, n.terrain, ''))
                                 else q.x end
                            order by q.o)
             from jsonb_array_elements(p->'entrants') with ordinality q(x, o)
             left join tournament_decks k
               on k.tournament_id = p_tid and k.user_id::text = q.x->>'id'
             left join tournament_pn n
               on n.tournament_id = p_tid and n.pid = q.x->>'pid' and k.user_id is null), '[]'::jsonb))
  end;
$$;

-- 5b. t_pn_save_deck: a player keeps their Play Network deck in My decks --------
-- The caller's own imported deck in tournament p_tid (their row in
-- tournament_decks with src 'pn', on a seat that is still theirs) is copied
-- into decks for them: private, named after the Play Network deck (else
-- "<Seeker> (Play Network)", at most 60 characters like the builder), with
-- the Play Network deck link as the deck's link. The card list is the one
-- stored for the tournament, main deck with terrain and legacy, and side
-- deck, in the site's card names; cards the site does not know keep their
-- Play Network names (the deck pages and the builder show such names as
-- text). A deck read only in part gets a line saying so in its description.
-- If the caller already has a deck with the same Seeker, cards and side deck,
-- nothing is added and that deck is the answer (existing true).
-- Only the caller's own list is copied, into their own private decks: no
-- card list leaves the database for anyone else, and the answer holds none.
-- Answer: {ok, deck_id, existing, partial, unk (cards the site does not
-- know)}, or t_no with reason
--   not_allowed   signed out, a guest, a deleted account, no such tournament
--   no_deck       the caller has no imported deck in this tournament (no
--                 seat, the seat is no longer theirs, or a deck registered
--                 from My decks, which is there already)
--   rate_limited  a limit on decks refused the insert (none today)
--   error         anything else (the deck is not saved)
-- Any status: the deck is the player's own, also after the start or close.
create or replace function public.t_pn_save_deck(p_tid uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := auth.uid();
  v_t    tournaments%rowtype;
  v_row  tournament_decks%rowtype;
  v_n    tournament_pn%rowtype;
  v_id   uuid;
  v_name text;
  v_desc text;
  v_side jsonb;
  v_hint text;
begin
  if v_uid is null or coalesce((auth.jwt()->>'is_anonymous')::boolean, false) or p_tid is null
     or not exists (select 1 from profiles pr where pr.id = v_uid and pr.deleted_at is null) then
    return t_no('not_allowed', 'Sign in first, then reload the page.');
  end if;
  select * into v_t from tournaments x where x.id = p_tid;
  if not found or v_t.status is null then
    return t_no('not_allowed', 'This tournament was not found.');
  end if;
  select * into v_row from tournament_decks k
   where k.tournament_id = p_tid and k.user_id = v_uid and k.src = 'pn';
  if not found or v_row.cards is null or jsonb_typeof(v_row.cards) <> 'object'
     or not exists (select 1 from jsonb_array_elements(coalesce(v_t.payload->'entrants', '[]'::jsonb)) q(x)
                     where jsonb_typeof(q.x) = 'object' and q.x->>'id' = v_uid::text and q.x->>'pid' = v_row.pn_pid) then
    return t_no('no_deck', 'You have no deck from the Play Network in this tournament.');
  end if;
  select * into v_n from tournament_pn n
   where n.tournament_id = p_tid and n.pid = v_row.pn_pid and n.seeker is not null;
  if not found then
    return t_no('no_deck', 'You have no deck from the Play Network in this tournament.');
  end if;
  v_side := case when jsonb_typeof(v_row.side) = 'object' and v_row.side <> '{}'::jsonb then v_row.side end;
  -- one save at a time per player, so two taps cannot add the deck twice
  perform pg_advisory_xact_lock(hashtext('t_pn_save_deck'), hashtext(v_uid::text));
  select d.id into v_id
    from decks d
   where d.user_id = v_uid
     and duel_clean(d.seeker) is not distinct from v_row.seeker
     and coalesce(d.cards, '{}'::jsonb) = v_row.cards
     and coalesce(d.side, '{}'::jsonb) = coalesce(v_side, '{}'::jsonb)
   order by d.created_at, d.id
   limit 1;
  if v_id is not null then
    return jsonb_build_object('ok', true, 'deck_id', v_id, 'existing', true,
                              'partial', v_n.deck_st = 'partial', 'unk', coalesce(v_n.unk_n, 0));
  end if;
  v_name := left(coalesce(nullif(btrim(v_row.name), ''), v_row.seeker || ' (Play Network)'), 60);
  v_desc := case when v_n.deck_st = 'partial'
                 then 'Only part of the card list could be read from the Play Network. Check it against the link.' end;
  begin
    insert into decks (user_id, name, seeker, faction, url, description, cards, side, tag, is_public)
    values (v_uid, v_name, v_row.seeker, null, v_n.deck_url, v_desc, v_row.cards, v_side, null, false)
    returning id into v_id;
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint;
    if v_hint = 'rate_limited' then
      return t_no('rate_limited', 'Too many decks saved in a short time. Wait a minute, then try again.');
    end if;
    return t_no('error', 'Could not save the deck. Try again.');
  end;
  return jsonb_build_object('ok', true, 'deck_id', v_id, 'existing', false,
                            'partial', v_n.deck_st = 'partial', 'unk', coalesce(v_n.unk_n, 0));
end $$;

-- 6. Who may call what -----------------------------------------------------------
revoke all on function public.t_pn_av(text)                               from public, anon, authenticated;
revoke all on function public.t_pn_cards(jsonb, int)                      from public, anon, authenticated;
revoke all on function public.t_pn_deck(jsonb)                            from public, anon, authenticated;
revoke all on function public.t_pn_sync(uuid, jsonb, text)                from public, anon, authenticated;
revoke all on function public.t_import(uuid, jsonb, int, jsonb)           from public, anon, authenticated;
revoke all on function public.t_auto_before()                             from public, anon, authenticated;
revoke all on function public.t_deck_pub(jsonb, uuid)                     from public, anon, authenticated;
revoke all on function public.t_deck_set(uuid, uuid, text)                from public, anon, authenticated;
revoke all on function public.t_deck_get(uuid)                            from public, anon, authenticated;
revoke all on function public.t_pn_save_deck(uuid)                       from public, anon, authenticated;
grant execute on function public.t_import(uuid, jsonb, int, jsonb)        to service_role;
grant execute on function public.t_deck_set(uuid, uuid, text)             to authenticated;
grant execute on function public.t_deck_get(uuid)                         to authenticated;
grant execute on function public.t_pn_save_deck(uuid)                    to authenticated;

-- ============================================================
--  ORGANIZER SEATS A MEMBER (2026-11-20)
-- ============================================================
-- Run as migration-2026-11-20-pn-seat.sql.
-- What changes:
--   * New t_seat(p_tid, p_rev, p_key, p_user), for signed-in organizers:
--     the organizer of a tournament (or the site admin) seats a member's
--     account on a player of the list who has no account yet ('pn:<pid>'
--     or 'h:<8>'), for a player who never pasted their Play Network profile
--     link or registered there under another profile. Same lock, rev check
--     and answer as t_entrant ({ok, rev}, refusals {ok:false, reason,
--     message}). Reasons: not_found (no such player), linked (the player
--     already has an account), no_account (the account is missing or
--     deleted), not_member (not an active member of the tournament's
--     community), seated (the account already has a seat), closed (the
--     tournament is closed), and t_lock's not_allowed, archived and stale.
--     Works in registration and while running (the account takes over the
--     player's games, as "Link the account" does).
--   * The seat keeps the player's pid and name and is marked org:true;
--     wait and lock go; its pid gets a lock mark instead, so if the
--     registrant leaves the Play Network list and comes back, the new
--     'pn:<pid>' comes back locked, not linked to the profile owner.
--   * t_link_all never moves an org:true seat back to 'pn:<pid>' because
--     of the account's profile link (changed, removed, or another pid): a
--     profile save, a Play Network refresh and a relink leave it alone. It
--     goes back only when its account is deleted or gone, and then it is
--     locked (as unlink does), so it is not linked to the profile owner
--     the organizer passed over. A player without an account loses a
--     leftover org flag and gets that lock.
--   * t_entrant: unlink of an org:true seat gives it back as usual
--     ('pn:<pid>', or a new 'h:' key) and drops org; forget drops org too.
--   * Not changed: t_import (a refresh keeps the seat: it still carries its
--     pid, so the registrant is never added twice), t_rekey, t_profile_link,
--     erase_user_data, t_lock.

-- 1. t_link_all: seats chosen by the organizer stay -------------------------------
-- t_link_all: as in the PLAY NETWORK TOURNAMENTS section, plus the seats
-- the organizer chose (org:true, t_seat): such a seat stays with its
-- account whatever pid that account's profile link gives, or none, so a
-- profile save, a Play Network refresh or a relink never moves it. It goes
-- back to 'pn:<pid>' (or a new 'h:' key) only when its account is deleted
-- or gone. A player without an account loses a leftover org (a seat moved
-- back here or by erase_user_data keeps it) and is locked instead, as
-- unlink does, so the profile owner the organizer passed over is not
-- linked to it (2026-11-09).
create or replace function public.t_link_all(p jsonb, p_new text default '*', out r jsonb, out linked int)
language plpgsql volatile security definer set search_path = public as $$
declare
  v_e  jsonb;
  v_o  int;
  v_id uuid;
begin
  r := p;
  for v_e in select q.x from jsonb_array_elements(coalesce(p->'entrants', '[]'::jsonb)) q(x) loop
    if t_acct(v_e->>'id') and not exists (
         select 1 from profiles pr
          where pr.id = (v_e->>'id')::uuid and pr.deleted_at is null
            and ((v_e->>'org') = 'true'
                 or (v_e->>'pid' is not null and pr.mg_public_id = v_e->>'pid'))) then
      r := t_rekey(r, v_e->>'id',
                   case when coalesce(v_e->>'pid', '') ~ '^[A-Za-z0-9]{6,32}$' then 'pn:' || (v_e->>'pid')
                        else t_rand_key(r) end);
    end if;
  end loop;
  for v_e, v_o in select q.x, q.o - 1 from jsonb_array_elements(coalesce(r->'entrants', '[]'::jsonb)) with ordinality q(x, o) loop
    if t_acct(v_e->>'id') then
      continue;
    end if;
    if v_e ? 'org' then
      r := jsonb_set(r, array['entrants', v_o::text], ((r->'entrants'->v_o) - 'org')
                  || case when (v_e->>'org') = 'true' then '{"lock":true}'::jsonb else '{}'::jsonb end);
      if (v_e->>'org') = 'true' then
        v_e := v_e || '{"lock":true}'::jsonb;
      end if;
    end if;
    v_id := null;
    if v_e->>'pid' is not null and (v_e->>'lock') is distinct from 'true' then
      select pr.id into v_id from profiles pr
       where pr.mg_public_id = v_e->>'pid' and pr.deleted_at is null
       limit 1;
      if v_id is not null and r->'entrants' @> jsonb_build_array(jsonb_build_object('id', v_id::text)) then
        v_id := null;
      end if;
    end if;
    if v_id is not null and (p_new = '*' or p_new = v_e->>'id') then
      r := jsonb_set(r, array['entrants', v_o::text], (r->'entrants'->v_o) - 'wait');
      r := t_rekey(r, v_e->>'id', v_id::text);
    elsif v_id is not null then
      if (v_e->>'wait') is distinct from 'true' then
        r := jsonb_set(r, array['entrants', v_o::text, 'wait'], 'true'::jsonb);
      end if;
    elsif v_e ? 'wait' then
      r := jsonb_set(r, array['entrants', v_o::text], (r->'entrants'->v_o) - 'wait');
    end if;
  end loop;
  select count(*) into linked
    from jsonb_array_elements(coalesce(r->'entrants', '[]'::jsonb)) q(x)
   where t_acct(q.x->>'id');
end $$;

-- 2. t_entrant: unlink and forget drop org -------------------------------------------
-- t_entrant: as in the SWISS TOURNAMENTS section, plus the seats the
-- organizer chose (t_seat): unlink gives such a seat back as any other
-- ('pn:<pid>', or a new 'h:' key when it has no pid, with lock) and drops
-- org; forget drops org too.
create or replace function public.t_entrant(p_tid uuid, p_rev int, p_op text, p_key text default null,
                                            p_name text default null, p_link text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := duel_caller();
  v_no   jsonb;
  v_t    tournaments%rowtype;
  v_p    jsonb;
  v_e    jsonb;
  v_i    int;
  v_raw  text;
  v_pid  text;
  v_key  text;
  v_n    int;
  v_rev  int;
begin
  if p_op is null or p_op not in ('drop','undrop','add','remove','unlink','relink','forget') then
    return t_no('bad_input', 'This change is not known.');
  end if;
  v_no := t_lock(p_tid, p_rev, p_op = 'forget');
  if v_no is not null then
    return v_no;
  end if;
  select * into v_t from tournaments x where x.id = p_tid;
  v_p := v_t.payload;

  if p_op <> 'add' then
    select q.o - 1, q.x into v_i, v_e
      from jsonb_array_elements(coalesce(v_p->'entrants', '[]'::jsonb)) with ordinality q(x, o)
     where q.x->>'id' = p_key
     limit 1;
    if v_e is null then
      return t_no('bad_input', 'This player is not in the list.');
    end if;
  end if;
  if p_op in ('drop','undrop','unlink','relink') and v_t.status = 'closed' then
    return t_no('status', 'The tournament is closed. Reopen it first.');
  end if;
  if p_op in ('add','remove') and v_t.status <> 'draft' then
    return t_no('status', 'The tournament has started, so its list of players is fixed.');
  end if;

  if p_op = 'drop' then
    if v_e->>'st' = 'drop' then
      return jsonb_build_object('ok', true, 'rev', v_t.rev);
    end if;
    v_p := jsonb_set(v_p, array['entrants', v_i::text, 'st'], '"drop"'::jsonb);
    if v_t.status = 'draft' or v_p->>'fmt' = 'swiss' then
      v_p := jsonb_set(v_p, array['entrants', v_i::text, 'dr'], to_jsonb(t_sw_cur(v_p)));
    end if;
    if v_t.status = 'running' then
      v_p := t_forfeits(v_p);
      if not t_r0_empty(v_p) then
        v_p := t_propagate(v_p);
      end if;
    end if;

  elsif p_op = 'undrop' then
    if v_e->>'st' is distinct from 'drop' then
      return jsonb_build_object('ok', true, 'rev', v_t.rev);
    end if;
    if v_t.status = 'running' then
      if not t_r0_empty(v_p) then
        return t_no('finals_drawn', 'The finals are drawn; this player stays dropped.');
      end if;
      if not (p_key = any(t_grouped(v_p))) then
        return t_no('status', 'This player was dropped before the start, so they are not in the draw.');
      end if;
      if v_p->>'fmt' = 'swiss'
         and coalesce(case when v_e->>'dr' ~ '^[0-9]{1,3}$' then (v_e->>'dr')::int end, 0) < t_sw_cur(v_p) then
        return t_no('status', 'Round ' || t_sw_cur(v_p) || ' is already paired without this player, so they stay dropped.');
      end if;
    end if;
    v_p := jsonb_set(v_p, array['entrants', v_i::text], ((v_p->'entrants'->v_i) - 'dr') || '{"st":"in"}'::jsonb);
    if v_t.status = 'running' then
      v_p := t_forfeits(v_p);
    end if;

  elsif p_op = 'add' then
    v_raw := btrim(regexp_replace(coalesce(p_name, ''), '[[:cntrl:]]', '', 'g'));
    if char_length(v_raw) not between 1 and 40 then
      return t_no('bad_input', 'A name has 1 to 40 characters.');
    end if;
    if jsonb_array_length(coalesce(v_p->'entrants', '[]'::jsonb)) >= 256 then
      return t_no('bad_input', 'A tournament has at most 256 players.');
    end if;
    if nullif(btrim(coalesce(p_link, '')), '') is not null then
      v_pid := mg_public_id(p_link);
      if v_pid is null then
        return t_no('bad_input', 'Paste the address of a malediction.gg profile, like https://malediction.gg/app/profile/AbC123xYz0/');
      end if;
      if coalesce(v_p->'entrants' @> jsonb_build_array(jsonb_build_object('pid', v_pid)), false)
         or coalesce(v_p->'entrants' @> jsonb_build_array(jsonb_build_object('id', 'pn:' || v_pid)), false) then
        return t_no('duplicate', 'This player is already in the list.');
      end if;
      v_key := 'pn:' || v_pid;
    else
      v_key := t_rand_key(v_p);
    end if;
    v_p := jsonb_set(v_p, '{entrants}', coalesce(v_p->'entrants', '[]'::jsonb) || jsonb_build_array(
             jsonb_build_object('id', v_key, 'name', v_raw, 'pid', v_pid, 'src', 'hand', 'st', 'in',
                                'seeker', '', 'terrain', '', 'deck', '', 'deckId', '')));
    if v_pid is not null then
      select q.r into v_p from t_link_all(v_p) q;
    end if;

  elsif p_op = 'remove' then
    if v_e->>'src' is distinct from 'hand' then
      return t_no('bad_input', 'Only players you added can be removed. Drop a registered player instead.');
    end if;
    v_p := jsonb_set(v_p, '{entrants}', (v_p->'entrants') - v_i);

  elsif p_op = 'unlink' then
    v_p := jsonb_set(v_p, array['entrants', v_i::text], ((v_p->'entrants'->v_i) - 'org') || '{"lock":true}'::jsonb);
    if t_acct(v_e->>'id') then
      v_key := case when coalesce(v_e->>'pid', '') ~ '^[A-Za-z0-9]{6,32}$' then 'pn:' || (v_e->>'pid')
                    else t_rand_key(v_p) end;
      v_p := t_rekey(v_p, v_e->>'id', v_key);
    end if;

  elsif p_op = 'relink' then
    v_p := jsonb_set(v_p, array['entrants', v_i::text], (v_p->'entrants'->v_i) - 'lock');
    if v_e->>'pid' is not null then
      delete from tournament_marks
       where tournament_id = p_tid and kind = 'lock' and pid_hash = t_pid_hash(p_tid, v_e->>'pid');
    end if;
    select q.r into v_p from t_link_all(v_p, case when v_t.status = 'draft' then '*' else p_key end) q;

  elsif p_op = 'forget' then
    -- The entrant moves to the end of the list, so its place no longer
    -- matches the official page, and is named after a counter (fx).
    v_pid := v_e->>'pid';
    v_n := coalesce(case when v_p->>'fx' ~ '^[0-9]{1,4}$' then (v_p->>'fx')::int end, 0) + 1;
    v_e := (v_e - 'wait' - 'org') || jsonb_build_object('name', 'Player ' || v_n, 'pid', null, 'lock', true);
    v_p := jsonb_set(v_p - 'nx', '{entrants}', ((v_p->'entrants') - v_i) || jsonb_build_array(v_e))
           || jsonb_build_object('fx', v_n);
    if v_pid is not null then
      insert into tournament_marks (tournament_id, pid_hash, kind)
      values (p_tid, t_pid_hash(p_tid, v_pid), 'forget')
      on conflict do nothing;
    end if;
    if p_key !~ '^h:' then
      v_p := t_rekey(v_p, p_key, t_rand_key(v_p));
    end if;
  end if;

  update tournaments set payload = v_p, rev = rev + 1 where id = p_tid returning rev into v_rev;
  return jsonb_build_object('ok', true, 'rev', v_rev);
end $$;

-- 3. t_seat: the organizer seats a member ------------------------------------------
-- The organizer (or the site admin) puts a member's account on a player of
-- the list who has no account yet ('pn:<pid>' or 'h:<8>'): a player who
-- never pasted their Play Network profile link, or registered there under
-- a profile that is not the one on their account. Before and after the
-- start, never once closed. p_user must be an account that is not deleted,
-- an active member (not dropped) of the tournament's community, and not in
-- the list yet (one seat per account). The seat keeps the player's pid and
-- name and gets org:true, so a profile save, a Play Network refresh or a
-- relink never moves it (t_link_all); wait and lock go (the organizer chose
-- this account). Its pid gets a lock mark: should a Play Network refresh
-- drop the registrant and a later one add them back, the new 'pn:<pid>'
-- is locked (2026-11-09). Unlink (t_entrant)
-- gives the seat back. Refusals: as t_lock, then closed, not_found,
-- linked, no_account, not_member, seated. Answer as t_entrant: {ok, rev}.
create or replace function public.t_seat(p_tid uuid, p_rev int, p_key text, p_user uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := duel_caller();
  v_no  jsonb;
  v_t   tournaments%rowtype;
  v_p   jsonb;
  v_e   jsonb;
  v_i   int;
  v_rev int;
begin
  v_no := t_lock(p_tid, p_rev);
  if v_no is not null then
    return v_no;
  end if;
  select * into v_t from tournaments x where x.id = p_tid;
  if v_t.status = 'closed' then
    return t_no('closed', 'The tournament is closed. Reopen it first.');
  end if;
  v_p := v_t.payload;
  select q.o - 1, q.x into v_i, v_e
    from jsonb_array_elements(coalesce(v_p->'entrants', '[]'::jsonb)) with ordinality q(x, o)
   where q.x->>'id' = p_key
   limit 1;
  if v_e is null then
    return t_no('not_found', 'This player is not in the list.');
  end if;
  if t_acct(v_e->>'id') then
    return t_no('linked', 'This player already has an account. Unlink it first.');
  end if;
  if p_user is null or not exists (select 1 from profiles pr where pr.id = p_user and pr.deleted_at is null) then
    return t_no('no_account', 'This account was not found.');
  end if;
  if v_t.league_id is null or not exists (
       select 1 from memberships m
        where m.league_id = v_t.league_id and m.user_id = p_user and m.dropped_at is null) then
    return t_no('not_member', 'Only an active member of this community can take a seat.');
  end if;
  if coalesce(v_p->'entrants' @> jsonb_build_array(jsonb_build_object('id', p_user::text)), false) then
    return t_no('seated', 'This account already has a seat in this tournament.');
  end if;
  v_p := jsonb_set(v_p, array['entrants', v_i::text],
                   ((v_p->'entrants'->v_i) - 'wait' - 'lock') || '{"org":true}'::jsonb);
  v_p := t_rekey(v_p, p_key, p_user::text);
  if v_e->>'pid' is not null then
    insert into tournament_marks (tournament_id, pid_hash, kind)
    values (p_tid, t_pid_hash(p_tid, v_e->>'pid'), 'lock')
    on conflict do nothing;
  end if;
  -- the other players: a wait for this account (it is seated now) goes
  select q.r into v_p from t_link_all(v_p, case when v_t.status = 'draft' then '*' end) q;
  update tournaments set payload = v_p, rev = rev + 1 where id = p_tid returning rev into v_rev;
  return jsonb_build_object('ok', true, 'rev', v_rev);
end $$;

-- 4. Who may call what -------------------------------------------------------------
revoke all on function public.t_link_all(jsonb, text)                             from public, anon, authenticated;
revoke all on function public.t_entrant(uuid, int, text, text, text, text)        from public, anon;
revoke all on function public.t_seat(uuid, int, text, uuid)                       from public, anon;
grant execute on function public.t_entrant(uuid, int, text, text, text, text)     to authenticated;
grant execute on function public.t_seat(uuid, int, text, uuid)                    to authenticated;

-- ============================================================
--  PLAY NETWORK DECK DEDUPE (2026-11-21)
-- ============================================================
-- Run as migration-2026-11-21-pn-deck-dedupe.sql.
-- What changes:
--   * New deck_sig(p_seeker, p_cards, p_side): the same text for two decks
--     with the same Seeker, main deck and side deck, whatever the spelling
--     (case, apostrophes, spaces), the Seeker card inside the main deck (the
--     builder adds it since 2026-09-29, the Play Network list never has
--     it), the Seeker's own Legacy inside the main deck (the builder always
--     adds it, a Play Network list may lack it), entries with 0 copies, or
--     an empty side deck against none. The rules are written so the page
--     can compute the same text (see the comment on deck_sig). Helpers
--     deck_sig_name, deck_sig_legacy, deck_sig_items and deck_sig_in go
--     with it. None of them is callable over the API.
--   * t_pn_save_deck finds the caller's deck with the same list by deck_sig
--     instead of an exact jsonb match, so a deck made in the builder (Seeker
--     card and Legacy in the list), a deck re-saved after picking the Seeker
--     again, or one with a different apostrophe is found and no copy is
--     added. When several match, the one with the same Play Network link
--     comes first. A matched deck with no link gets the Play Network deck
--     link (a link already set is never changed), so My decks shows its
--     Play Network badge.
--   * A deck read only in part: if the caller already has a deck from the
--     same Play Network link that holds every card of the part read, that
--     deck is the answer (no incomplete copy is added). If this read is
--     full and the caller has the copy saved from a part read of the same
--     link, still with its "Only part of the card list..." note and with no
--     card that the full list lacks, that copy gets the full list and loses
--     the note, and it is the answer (existing true), instead of a second
--     deck.
--   * Not changed: the per-player lock, the answer {ok, deck_id, existing,
--     partial, unk}, the refusals (not_allowed, no_deck, rate_limited,
--     error) and who may call it.

-- 1. Deck signature helpers (not callable over the API) -------------------------
-- deck_sig_name: a card or Seeker name for comparing. Every character other
-- than A-Z, a-z and 0-9 is removed, then the rest is lowercased.
-- In JavaScript: (s||"").replace(/[^A-Za-z0-9]/g,"").toLowerCase(). That is
-- the page's normName for every name (normName lowercases first; the two
-- differ only for the characters U+0130 and U+212A, in no card name).
create or replace function public.deck_sig_name(p text)
returns text language sql immutable set search_path = public as $$
  select lower(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g'));
$$;

-- deck_sig_legacy: the deck_sig_name of the Legacy bound to a Seeker, given
-- the Seeker's deck_sig_name; null for a Seeker not listed. Each Legacy card
-- of the page's card list names its Seeker (legacyOf in index.html); this is
-- that list as of this migration (10 Seekers). A Seeker added to the page
-- later and not here only means its Legacy still counts in deck_sig, as
-- before.
create or replace function public.deck_sig_legacy(p text)
returns text language sql immutable set search_path = public as $$
  select '{"auricevenhand":"willoftheforge","countessmorridaumberland":"soulstitcher",
           "grizalingeringwound":"ihreniv","ingorthespiritbound":"effigyofchaos",
           "karmamok":"lienawhodreams","londrielspellwarden":"arkoflamentation",
           "polinoreprimearchivist":"runefoldgauntlet","sigrithandravos":"andravon",
           "thundersteps":"stormseye","vorendalthedreadheart":"heartlock"}'::jsonb ->> nullif(p, '');
$$;

-- deck_sig_items: a card list (jsonb object name -> copies) as rows (k, q):
--   * a value that is not a jsonb object counts as an empty list (null,
--     {}, an array, a string: no rows, never an error);
--   * only entries whose value is a JSON number of at least 1 count (0,
--     negative, a string such as "3", true, null are dropped); the copies
--     are rounded down and at most 999 per entry;
--   * k is deck_sig_name of the name; an empty k is dropped, and so is k
--     equal to p_skip (the Seeker's own name, for the main deck) or to
--     deck_sig_legacy(p_skip) (that Seeker's own Legacy: the builder always
--     adds it, a Play Network list may lack it);
--   * entries whose names give the same k are added together.
create or replace function public.deck_sig_items(p jsonb, p_skip text default null)
returns table (k text, q int) language sql immutable set search_path = public as $$
  select x.k, sum(x.q)::int
    from (select deck_sig_name(e.key) as k,
                 case when jsonb_typeof(e.value) is distinct from 'number' then null
                      when (e.value #>> '{}')::numeric >= 1
                      then least(floor((e.value #>> '{}')::numeric), 999)::int end as q
            from jsonb_each(case when jsonb_typeof(p) = 'object' then p else '{}'::jsonb end) e) x
   where x.q is not null and x.k <> '' and x.k is distinct from nullif(p_skip, '')
     and x.k is distinct from deck_sig_legacy(p_skip)
   group by x.k;
$$;

-- deck_sig: one text for a deck's Seeker, main deck (terrain and legacy
-- included) and side deck:
--   S + "#" + list(p_cards, skip S and its Legacy) + "#" + list(p_side)
-- where S is deck_sig_name of the Seeker after duel_clean (control
-- characters removed, spaces trimmed, first 80 characters: real Seeker
-- names are far shorter, so in JavaScript normName-style S is enough), and
-- list() is the rows of deck_sig_items as "k:q", sorted by k in byte order
-- (k holds only a-z and 0-9; JavaScript's default sort() gives the same
-- order) and joined with ",". An empty list is "". A null side deck and {}
-- give the same text. Example: Seeker "Polinore, Prime Archivist", cards
-- {"Spellbound Bahig'udjin":3,"Polinore, Prime Archivist":1,"Starcast
-- Halls":1,"Runefold Gauntlet":1}, no side deck ->
--   "polinoreprimearchivist#spellboundbahigudjin:3,starcasthalls:1#"
-- In JavaScript (legacyOf is the page's Seeker -> Legacy name):
--   const nn=s=>(s||"").replace(/[^A-Za-z0-9]/g,"").toLowerCase(),
--   L=(o,x,y)=>{const m={};if(o&&typeof o=="object"&&!Array.isArray(o))for(const n in o){
--     const v=o[n];if(typeof v!="number"||!(v>=1))continue;const k=nn(n);if(!k||k===x||k===y)continue;
--     m[k]=(m[k]||0)+Math.min(Math.floor(v),999)}
--     return Object.keys(m).sort().map(k=>k+":"+m[k]).join(",")},
--   deckSig=(s,c,sd)=>{const S=nn(s);return S+"#"+L(c,S,nn(legacyOf(s))||null)+"#"+L(sd,null,null)};
create or replace function public.deck_sig(p_seeker text, p_cards jsonb, p_side jsonb)
returns text language sql immutable set search_path = public as $$
  select z.s
      || '#' || coalesce((select string_agg(i.k || ':' || i.q, ',' order by i.k collate "C")
                            from deck_sig_items(p_cards, z.s) i), '')
      || '#' || coalesce((select string_agg(i.k || ':' || i.q, ',' order by i.k collate "C")
                            from deck_sig_items(p_side, null) i), '')
    from (select deck_sig_name(duel_clean(p_seeker)) as s) z;
$$;

-- deck_sig_in: true when every card of the first list is in the second at
-- least as many times, main deck against main deck and side deck against
-- side deck, by the rules of deck_sig (the Seeker card and its Legacy in a
-- main deck do not count). The Seeker itself is not compared: the caller does that.
create or replace function public.deck_sig_in(p_seeker text, p_cards jsonb, p_side jsonb,
                                              p_in_cards jsonb, p_in_side jsonb)
returns boolean language sql immutable set search_path = public as $$
  select not exists (select 1 from deck_sig_items(p_cards, z.s) a
                       left join deck_sig_items(p_in_cards, z.s) b on b.k = a.k
                      where b.q is null or b.q < a.q)
     and not exists (select 1 from deck_sig_items(p_side, null) a
                       left join deck_sig_items(p_in_side, null) b on b.k = a.k
                      where b.q is null or b.q < a.q)
    from (select deck_sig_name(duel_clean(p_seeker)) as s) z;
$$;

-- 2. t_pn_save_deck: a player keeps their Play Network deck in My decks ----------
-- As in the PLAY NETWORK DECKLISTS section, except how an existing deck is
-- found (2026-11-21):
--   * a deck of the caller with the same deck_sig (Seeker, main deck, side
--     deck) is the answer (existing true): one with the Play Network deck
--     link first, then the oldest; so a deck made in the builder, which
--     holds the Seeker card and its Legacy in its list, matches the Play
--     Network list, which never has the Seeker card and may lack the Legacy.
--     If that deck has no link and the Play Network deck has one, it gets
--     that link (a link already set is never changed; if the update fails
--     the deck is still the answer), so My decks shows its Play Network
--     badge;
--   * else, when the Play Network deck has a link: if this read is partial,
--     a deck of the caller with the same link and Seeker that holds every
--     card read is the answer; if this read is full, a deck of the caller
--     with the same link and Seeker that still has the partial-read note as
--     its description and no card beyond the full list gets the full list,
--     loses the note, and is the answer (existing true).
-- Everything else is unchanged: the copy is private, named after the Play
-- Network deck (else "<Seeker> (Play Network)", at most 60 characters),
-- with the Play Network deck link as its link; only the caller's own list
-- is copied, into their own decks, and the answer holds no card list.
-- Answer: {ok, deck_id, existing, partial, unk (cards the site does not
-- know)}, or t_no with reason
--   not_allowed   signed out, a guest, a deleted account, no such tournament
--   no_deck       the caller has no imported deck in this tournament (no
--                 seat, the seat is no longer theirs, or a deck registered
--                 from My decks, which is there already)
--   rate_limited  a limit on decks refused the insert (none today)
--   error         anything else (the deck is not saved)
-- Any status: the deck is the player's own, also after the start or close.
create or replace function public.t_pn_save_deck(p_tid uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := auth.uid();
  v_t    tournaments%rowtype;
  v_row  tournament_decks%rowtype;
  v_n    tournament_pn%rowtype;
  v_id   uuid;
  v_name text;
  v_desc text;
  v_side jsonb;
  v_hint text;
  v_sig  text;
  v_sk   text;
  v_note constant text := 'Only part of the card list could be read from the Play Network. Check it against the link.';
begin
  if v_uid is null or coalesce((auth.jwt()->>'is_anonymous')::boolean, false) or p_tid is null
     or not exists (select 1 from profiles pr where pr.id = v_uid and pr.deleted_at is null) then
    return t_no('not_allowed', 'Sign in first, then reload the page.');
  end if;
  select * into v_t from tournaments x where x.id = p_tid;
  if not found or v_t.status is null then
    return t_no('not_allowed', 'This tournament was not found.');
  end if;
  select * into v_row from tournament_decks k
   where k.tournament_id = p_tid and k.user_id = v_uid and k.src = 'pn';
  if not found or v_row.cards is null or jsonb_typeof(v_row.cards) <> 'object'
     or not exists (select 1 from jsonb_array_elements(coalesce(v_t.payload->'entrants', '[]'::jsonb)) q(x)
                     where jsonb_typeof(q.x) = 'object' and q.x->>'id' = v_uid::text and q.x->>'pid' = v_row.pn_pid) then
    return t_no('no_deck', 'You have no deck from the Play Network in this tournament.');
  end if;
  select * into v_n from tournament_pn n
   where n.tournament_id = p_tid and n.pid = v_row.pn_pid and n.seeker is not null;
  if not found then
    return t_no('no_deck', 'You have no deck from the Play Network in this tournament.');
  end if;
  v_side := case when jsonb_typeof(v_row.side) = 'object' and v_row.side <> '{}'::jsonb then v_row.side end;
  v_sig  := deck_sig(v_row.seeker, v_row.cards, v_side);
  v_sk   := deck_sig_name(duel_clean(v_row.seeker));
  -- one save at a time per player, so two taps cannot add the deck twice
  perform pg_advisory_xact_lock(hashtext('t_pn_save_deck'), hashtext(v_uid::text));
  -- the same list, however it is spelled or was made
  select d.id into v_id
    from decks d
   where d.user_id = v_uid
     and deck_sig(d.seeker, d.cards, d.side) = v_sig
   order by coalesce(d.url = v_n.deck_url, false) desc, d.created_at, d.id
   limit 1;
  -- a matched deck with no link keeps the Play Network link from now on
  if v_id is not null and v_n.deck_url is not null then
    begin
      update decks set url = v_n.deck_url
       where id = v_id and coalesce(btrim(url), '') = '';
    exception when others then
      null;
    end;
  end if;
  -- the same Play Network deck, read in full one time and in part another
  if v_id is null and v_n.deck_url is not null then
    if v_n.deck_st = 'partial' then
      select d.id into v_id
        from decks d
       where d.user_id = v_uid and d.url = v_n.deck_url
         and deck_sig_name(duel_clean(d.seeker)) = v_sk
         and deck_sig_in(v_row.seeker, v_row.cards, v_side, d.cards, d.side)
       order by d.created_at, d.id
       limit 1;
    else
      select d.id into v_id
        from decks d
       where d.user_id = v_uid and d.url = v_n.deck_url
         and d.description = v_note
         and deck_sig_name(duel_clean(d.seeker)) = v_sk
         and deck_sig_in(v_row.seeker, d.cards, d.side, v_row.cards, v_side)
       order by d.created_at, d.id
       limit 1;
      if v_id is not null then
        begin
          update decks set cards = v_row.cards, side = v_side, description = null
           where id = v_id;
        exception when others then
          return t_no('error', 'Could not save the deck. Try again.');
        end;
      end if;
    end if;
  end if;
  if v_id is not null then
    return jsonb_build_object('ok', true, 'deck_id', v_id, 'existing', true,
                              'partial', v_n.deck_st = 'partial', 'unk', coalesce(v_n.unk_n, 0));
  end if;
  v_name := left(coalesce(nullif(btrim(v_row.name), ''), v_row.seeker || ' (Play Network)'), 60);
  v_desc := case when v_n.deck_st = 'partial' then v_note end;
  begin
    insert into decks (user_id, name, seeker, faction, url, description, cards, side, tag, is_public)
    values (v_uid, v_name, v_row.seeker, null, v_n.deck_url, v_desc, v_row.cards, v_side, null, false)
    returning id into v_id;
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint;
    if v_hint = 'rate_limited' then
      return t_no('rate_limited', 'Too many decks saved in a short time. Wait a minute, then try again.');
    end if;
    return t_no('error', 'Could not save the deck. Try again.');
  end;
  return jsonb_build_object('ok', true, 'deck_id', v_id, 'existing', false,
                            'partial', v_n.deck_st = 'partial', 'unk', coalesce(v_n.unk_n, 0));
end $$;

-- 3. Who may call what -------------------------------------------------------------
revoke all on function public.deck_sig_name(text)                               from public, anon, authenticated;
revoke all on function public.deck_sig_legacy(text)                             from public, anon, authenticated;
revoke all on function public.deck_sig_items(jsonb, text)                       from public, anon, authenticated;
revoke all on function public.deck_sig(text, jsonb, jsonb)                      from public, anon, authenticated;
revoke all on function public.deck_sig_in(text, jsonb, jsonb, jsonb, jsonb)     from public, anon, authenticated;
revoke all on function public.t_pn_save_deck(uuid)                              from public, anon, authenticated;
grant execute on function public.t_pn_save_deck(uuid)                           to authenticated;

-- ============================================================
--  WEB PUSH NOTIFICATIONS (2026-11-22)
-- ============================================================
-- Run as migration-2026-11-22-push.sql. Turn on pg_net first (Dashboard >
-- Database > Extensions, schema extensions): without it this section stops
-- with an error. Then store the shared secret in Vault as 'sl_push_secret'.
-- What changes:
--   * Web Push notifications. New tables push_subscriptions (each browser that
--     turned notifications on, at most 10 per player), notify_prefs (four
--     switches per player: tournaments, matches, events, notices; no row means
--     all on), push_outbox (the messages waiting to be sent), push_event_sent
--     (which event reminders went out, so none repeats) and push_config (local
--     fallback for the shared secret). RLS on and no policies: only the
--     functions below read or write them.
--   * Triggers queue a message, never for the player who did the thing (on any
--     of their devices), only for players with a subscription and the family
--     switched on. A push problem never fails the write.
--       - Swiss tournaments: a new round (your opponent and table, or a bye);
--         the organizer when only games without a tracked result are left, and
--         when a round is complete and nothing paired it within 3 minutes
--         ("pair round N+1", or "close it" after the last round); a tracked
--         tournament game invitation ("X is waiting for you").
--       - Matches: a player joins your match; the other player ends it and
--         waits for you to confirm; multiplayer: a player sits down, the match
--         is on, a claim to confirm.
--       - Community events: a new listing (several within 2 minutes become
--         one message), reminders the day before and one hour before (every
--         minute through pg_cron job sl-push), "Event removed" after a
--         reminder. An event listed in two communities is reminded once.
--       - Board notices: a new notice, 60 s late, so a notice deleted within
--         the undo window is never pushed.
--   * New RPCs for the page (signed-in players): push_subscribe,
--     push_unsubscribe, push_set_pref, push_state, push_test. For the
--     push-send edge function (service role only): push_claim, push_done.
--     Every other new function is not callable over the API.
--   * Each message is checked again when push-send takes it (push_stale): a
--     family switched off, a community left, a notice deleted, a round
--     unpaired, a match answered or an event moved drops it.
--   * push-send is asked to run through pg_net (net.http_post) after commit,
--     with the shared secret from Vault ('sl_push_secret'). pg_net must be on
--     first: without it this file stops and changes nothing.
--   * purge_old_rows also clears old push rows and pg_cron's run log (7 days).
--   * Deleting an account removes its push rows.

-- 0. pg_net (the owner turns it on first) -----------------------------------------
-- push_kick calls net.http_post. Without pg_net nothing can be delivered, so
-- the migration stops here and changes nothing.
do $$
begin
  begin
    create extension if not exists pg_net with schema extensions;
  exception when others then
    raise notice 'pg_net could not be created here (%).', sqlerrm;
  end;
  if not exists (select 1 from pg_proc p where p.proname = 'http_post'
                  and p.pronamespace = to_regnamespace('net')) then
    raise exception 'pg_net is not installed: turn it on in Dashboard > Database > Extensions (pg_net, schema extensions), then run this file again. Nothing was changed.';
  end if;
end $$;

-- 1. Tables (RLS on, no policies: only the functions below read or write them) ----
create table if not exists public.push_subscriptions (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id) on delete cascade,
  endpoint     text not null unique check (endpoint ~ '^https://' and char_length(endpoint) <= 1024),
  p256dh       text not null check (p256dh ~ '^[A-Za-z0-9_-]{86,88}$'),
  auth         text not null check (auth ~ '^[A-Za-z0-9_-]{21,24}$'),
  ua           text check (char_length(ua) <= 200),
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz,
  last_ok_at   timestamptz,
  fails        int not null default 0
);
create index if not exists idx_push_subs_user on public.push_subscriptions(user_id);

create table if not exists public.notify_prefs (
  user_id     uuid primary key references public.profiles(id) on delete cascade,
  tournaments boolean not null default true,
  matches     boolean not null default true,
  events      boolean not null default true,
  notices     boolean not null default true,
  updated_at  timestamptz not null default now()
);

create table if not exists public.push_outbox (
  id            bigint generated always as identity primary key,
  user_id       uuid not null references public.profiles(id) on delete cascade,
  family        text not null check (family in ('tournaments','matches','events','notices','test')),
  kind          text not null check (kind ~ '^[a-z_]{2,24}$'),
  title         text not null check (char_length(title) between 1 and 120),
  body          text not null default '' check (char_length(body) <= 300),
  url           text not null check (url ~ '^#/' and char_length(url) <= 300),
  tag           text not null check (char_length(tag) between 1 and 80),
  data          jsonb not null default '{}'::jsonb,
  urgency       text not null default 'normal' check (urgency in ('very-low','low','normal','high')),
  dedupe_key    text not null unique,
  merge_key     text,
  not_before    timestamptz not null default now(),
  expires_at    timestamptz not null,
  created_at    timestamptz not null default now(),
  claimed_until timestamptz,
  sent_at       timestamptz,
  attempts      int not null default 0,
  last_error    text
);
create index if not exists idx_push_outbox_due on public.push_outbox(not_before, id) where sent_at is null;
create index if not exists idx_push_outbox_user on public.push_outbox(user_id);
create index if not exists idx_pn_events_start on public.pn_events(starts_at);
create unique index if not exists uq_push_outbox_merge on public.push_outbox(merge_key)
  where sent_at is null and merge_key is not null;

-- Event reminders sent-log. Keyed on pn_id (not pn_events.id), so an event
-- listed in two communities reminds a member of both only once. No foreign
-- key to pn_events, so it survives the listing being removed.
create table if not exists public.push_event_sent (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  pn_id       int  not null,
  kind        text not null check (kind in ('new','day','hour','removed')),
  slot        timestamptz not null,           -- starts_at the message was about; 'epoch' when none
  league_id   uuid,
  pn_event_id uuid,
  sent_at     timestamptz not null default now(),
  primary key (user_id, pn_id, kind, slot)
);

-- Fallback for the shared secret (local tests). Production keeps it in Vault.
create table if not exists public.push_config (k text primary key, v text not null);

alter table public.push_subscriptions enable row level security;
alter table public.notify_prefs       enable row level security;
alter table public.push_outbox        enable row level security;
alter table public.push_event_sent    enable row level security;
alter table public.push_config        enable row level security;
revoke all on table public.push_subscriptions, public.notify_prefs, public.push_outbox,
                    public.push_event_sent, public.push_config from public, anon, authenticated;
do $$
begin
  execute format('revoke all on sequence %s from public, anon, authenticated',
                 pg_get_serial_sequence('public.push_outbox', 'id'));
end $$;

-- 2. Helpers (none is callable over the API) ---------------------------------------
-- push_cfg: a setting of the push sender. Vault secret 'sl_push_<k>' first,
-- then push_config. Keys: 'secret' (required), 'url' (optional). Spaces, tabs
-- and line breaks around a pasted value are dropped, as push-send does.
create or replace function public.push_cfg(p_k text)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  v text;
begin
  if to_regclass('vault.decrypted_secrets') is not null then
    begin
      execute 'select decrypted_secret from vault.decrypted_secrets where name = $1 limit 1'
        into v using 'sl_push_' || p_k;
    exception when others then
      v := null;
    end;
  end if;
  if nullif(btrim(v, E' \t\r\n'), '') is null then
    select c.v into v from push_config c where c.k = p_k;
  end if;
  return nullif(btrim(v, E' \t\r\n'), '');
end $$;

-- push_kick: asks push-send to run, once per transaction. pg_net sends the
-- request only after commit, so a rolled-back write sends nothing.
create or replace function public.push_kick()
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_secret text;
begin
  if current_setting('sl.push_kick', true) = '1' then
    return true;
  end if;
  perform set_config('sl.push_kick', '1', true);
  if to_regnamespace('net') is null then
    return false;
  end if;
  v_secret := push_cfg('secret');
  if v_secret is null then
    return false;
  end if;
  execute 'select net.http_post(url := $1, body := $2, headers := $3, timeout_milliseconds := 8000)'
    using coalesce(push_cfg('url'), 'https://mrcciuwekqijitngvojc.supabase.co/functions/v1/push-send'),
          '{"src":"db"}'::jsonb,
          jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret);
  return true;
exception when others then
  raise warning 'push_kick: %', sqlerrm;
  return false;
end $$;

-- push_on: the family switch of a player (no row: everything on).
create or replace function public.push_on(p_user uuid, p_fam text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select case p_fam when 'tournaments' then n.tournaments
                                     when 'matches'     then n.matches
                                     when 'events'      then n.events
                                     when 'notices'     then n.notices
                                     else true end
                     from notify_prefs n where n.user_id = p_user), true);
$$;

create or replace function public.push_prefs(p_user uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('tournaments', coalesce(n.tournaments, true), 'matches', coalesce(n.matches, true),
                            'events', coalesce(n.events, true), 'notices', coalesce(n.notices, true))
    from (select 1) z left join notify_prefs n on n.user_id = p_user;
$$;

-- push_name: a player's name in a message.
create or replace function public.push_name(p_user uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select nullif(btrim(p.display_name), '') from profiles p
                    where p.id = p_user and p.deleted_at is null), 'A player');
$$;

-- push_t_name: a tournament key's name (account, else the entrant's name).
create or replace function public.push_t_name(p jsonb, p_key text)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    case when t_acct(p_key) then (select nullif(btrim(pr.display_name), '') from profiles pr
                                   where pr.id = p_key::uuid and pr.deleted_at is null) end,
    (select nullif(btrim(q.x->>'name'), '')
       from jsonb_array_elements(case when jsonb_typeof(p->'entrants') = 'array' then p->'entrants'
                                      else '[]'::jsonb end) q(x)
      where q.x->>'id' = p_key limit 1),
    'your opponent');
$$;

-- push_t_drop: the entrant with this key has dropped.
create or replace function public.push_t_drop(p jsonb, p_key text)
returns boolean language sql immutable security definer set search_path = public as $$
  select coalesce(p->'entrants' @> jsonb_build_array(jsonb_build_object('id', p_key, 'st', 'drop')), false);
$$;

-- push_t_open: round p_r's games without a result, both players with an
-- account (o_t) or not (o_h). Games of two dropped players do not count.
create or replace function public.push_t_open(p jsonb, p_r int, out o_t int, out o_h int)
language sql immutable security definer set search_path = public as $$
  select (count(*) filter (where t_acct(q.x->>'a') and t_acct(q.x->>'b')))::int,
         (count(*) filter (where not (t_acct(q.x->>'a') and t_acct(q.x->>'b'))))::int
    from jsonb_array_elements(case when jsonb_typeof(p->'gm') = 'array' then p->'gm' else '[]'::jsonb end) q(x)
   where q.x->>'r' = p_r::text and q.x->>'b' is not null and q.x->>'w' is null
     and not (push_t_drop(p, q.x->>'a') and push_t_drop(p, q.x->>'b'));
$$;

-- push_members: who in a community can get its pushes: active members and
-- the owner, not deleted, with a subscription; nobody when archived.
create or replace function public.push_members(p_league uuid)
returns setof uuid language sql stable security definer set search_path = public as $$
  select m.user_id from memberships m join profiles p on p.id = m.user_id
   where m.league_id = p_league and m.dropped_at is null and p.deleted_at is null
     and exists (select 1 from leagues l where l.id = p_league and l.archived_at is null)
     and exists (select 1 from push_subscriptions s where s.user_id = m.user_id)
  union
  select l.owner_id from leagues l join profiles p on p.id = l.owner_id
   where l.id = p_league and l.archived_at is null and p.deleted_at is null
     and exists (select 1 from push_subscriptions s where s.user_id = l.owner_id);
$$;

-- push_enqueue: the single way into the outbox. Skips the actor (not for
-- 'test'), deleted or unknown profiles, players without a subscription and
-- switched-off families. p_merge (ev_new only) folds messages into one row.
create or replace function public.push_enqueue(
  p_user uuid, p_fam text, p_kind text, p_title text, p_body text, p_url text, p_tag text,
  p_data jsonb, p_dedupe text, p_ttl_s int, p_urgency text default 'normal',
  p_not_before timestamptz default now(), p_merge text default null)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_id    bigint;
  v_merge text := p_merge;
  v_nb    timestamptz := coalesce(p_not_before, now());
  v_ttl   int := coalesce(p_ttl_s, 3600);
  v_again boolean := false;
begin
  if p_user is null or p_dedupe is null then
    return false;
  end if;
  if p_fam <> 'test' and p_user is not distinct from auth.uid() then
    return false;
  end if;
  if not exists (select 1 from profiles where id = p_user and deleted_at is null) then
    return false;
  end if;
  if not exists (select 1 from push_subscriptions where user_id = p_user) then
    return false;
  end if;
  if p_fam <> 'test' and not push_on(p_user, p_fam) then
    return false;
  end if;
  if v_merge is not null and exists (select 1 from push_outbox o where o.dedupe_key = p_dedupe) then
    return false;
  end if;
  loop
    if v_merge is not null then
      update push_outbox o
         set data = o.data || jsonb_build_object('n', coalesce((o.data->>'n')::int, 1) + 1, 'last', p_data->>'last'),
             title = left(format('%s new events in %s', coalesce((o.data->>'n')::int, 1) + 1, p_data->>'league'), 120),
             body  = left(format('%s and %s more', p_data->>'last', coalesce((o.data->>'n')::int, 1)), 300),
             expires_at = greatest(o.expires_at, now() + make_interval(secs => greatest(3600, least(v_ttl, 604800))))
       where o.merge_key = v_merge and o.sent_at is null and o.claimed_until is null
      returning o.id into v_id;
      if v_id is not null then
        return true;
      end if;
      -- The pending row is being sent right now: this event gets its own row,
      -- without a merge key (the insert would hit uq_push_outbox_merge).
      if exists (select 1 from push_outbox o where o.merge_key = v_merge and o.sent_at is null) then
        v_merge := null;
      end if;
    end if;
    insert into push_outbox (user_id, family, kind, title, body, url, tag, data, urgency,
                             dedupe_key, merge_key, not_before, expires_at)
    values (p_user, p_fam, p_kind, left(p_title, 120), left(coalesce(p_body, ''), 300), p_url, p_tag,
            coalesce(p_data, '{}'::jsonb) || jsonb_build_object('n', 1), coalesce(p_urgency, 'normal'),
            p_dedupe, v_merge, v_nb, v_nb + make_interval(secs => greatest(60, least(v_ttl, 604800))))
    on conflict do nothing
    returning id into v_id;
    -- 2026-11-09: a merge row that another transaction inserted and had not
    -- committed was invisible to the update above; the insert waited for it
    -- and skipped. It is committed now: merge into it, once.
    exit when v_id is not null or v_merge is null or v_again
           or exists (select 1 from push_outbox o where o.dedupe_key = p_dedupe);
    v_again := true;
  end loop;
  if v_id is not null and v_nb <= now() then
    perform push_kick();
  end if;
  return v_id is not null;
end $$;

-- 3. Enqueue points (each trigger swallows its own errors: a push problem never
--    fails the write) ---------------------------------------------------------------
-- (1) Swiss tournaments: a new round (players), results left to enter by hand
-- (organizer), a round complete that nothing paired (organizer).
create or replace function public.push_t_after()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_or     int;
  v_nr     int;
  v_tid    text;
  v_url    text;
  v_title  text;
  v_x      jsonb;
  v_s      int;
  v_k      text;
  v_o      text;
  v_tb     text;
  v_nt     int;
  v_nh     int;
  v_ot     int := 0;
  v_oh     int := 0;
  v_sig    text;
  v_rounds int;
begin
  begin
    if new.status is distinct from 'running' or coalesce(new.payload->>'fmt', '') <> 'swiss' then
      return null;
    end if;
    v_or := t_sw_cur(old.payload);
    v_nr := t_sw_cur(new.payload);
    v_tid := new.id::text;
    v_url := '#/tournaments/' || v_tid;
    v_title := coalesce(nullif(btrim(new.payload #>> '{pn,title}'), ''), 'Tournament');

    -- players of the new round (t_start, t_pair, t_auto_pair)
    if v_nr > v_or then
      for v_x in select q.x from jsonb_array_elements(new.payload->'gm') q(x) where q.x->>'r' = v_nr::text loop
        if v_x->>'src' = 'bye' or v_x->>'b' is null then
          v_k := v_x->>'a';
          if t_acct(v_k) and not push_t_drop(new.payload, v_k) then
            perform push_enqueue(v_k::uuid, 'tournaments', 't_bye', format('Round %s: you have a bye', v_nr),
                                 '3 points and 20 mastery differential · ' || v_title, v_url, 'sl-next-t' || v_tid,
                                 jsonb_build_object('tid', v_tid, 'r', v_nr),
                                 format('t_bye:%s:%s:%s:%s', v_tid, v_nr, new.rev, v_k), 43200, 'normal');
          end if;
        else
          v_tb := case when v_x->>'tb' ~ '^[0-9]{1,4}$' then v_x->>'tb' end;
          for v_s in 0..1 loop
            v_k := case when v_s = 0 then v_x->>'a' else v_x->>'b' end;
            v_o := case when v_s = 0 then v_x->>'b' else v_x->>'a' end;
            if t_acct(v_k) and not push_t_drop(new.payload, v_k) then
              perform push_enqueue(v_k::uuid, 'tournaments', 't_round',
                                   format('Round %s: you play %s', v_nr, push_t_name(new.payload, v_o)),
                                   concat_ws(' · ', 'Table ' || v_tb, v_title), v_url, 'sl-next-t' || v_tid,
                                   jsonb_build_object('tid', v_tid, 'r', v_nr),
                                   format('t_round:%s:%s:%s:%s', v_tid, v_nr, new.rev, v_k), 43200, 'high');
            end if;
          end loop;
        end if;
      end loop;
    end if;

    if new.organizer_id is not null and v_nr >= 1 then
      -- organizer: only games without a tracked result are left
      select q.o_t, q.o_h into v_nt, v_nh from push_t_open(new.payload, v_nr) q;
      if v_nh > 0 and v_nt = 0 then
        if v_or >= v_nr then
          select q.o_t, q.o_h into v_ot, v_oh from push_t_open(old.payload, v_nr) q;
        end if;
        if not (v_oh > 0 and v_ot = 0) then
          select md5(coalesce(string_agg(coalesce(q.x->>'a', '') || '-' || coalesce(q.x->>'b', ''), ','
                                         order by case when q.x->>'tb' ~ '^[0-9]{1,4}$' then (q.x->>'tb')::int end
                                                  nulls last, q.x->>'a'), ''))
            into v_sig
            from jsonb_array_elements(new.payload->'gm') q(x) where q.x->>'r' = v_nr::text;
          perform push_enqueue(new.organizer_id, 'tournaments', 't_org_hand',
                               format('Round %s: results to enter by hand', v_nr),
                               case when v_nh = 1 then '1 game has a player without an account · '
                                    else v_nh || ' games have a player without an account · ' end || v_title,
                               v_url, 'sl-org-t' || v_tid, jsonb_build_object('tid', v_tid, 'r', v_nr),
                               format('t_org_hand:%s:%s:%s', v_tid, v_nr, v_sig), 86400, 'normal');
        end if;
      end if;

      -- organizer: the round just became complete (checked again when sent)
      if v_nr = v_or and t_gm_done(new.payload) and not t_gm_done(old.payload) then
        v_rounds := case when new.payload->>'rounds' ~ '^[0-9]{1,3}$' then (new.payload->>'rounds')::int else 0 end;
        perform push_enqueue(new.organizer_id, 'tournaments', 't_org_pair', format('Round %s is complete', v_nr),
                             case when v_nr < v_rounds then format('Pair round %s · %s', v_nr + 1, v_title)
                                  else 'Open the tournament to close it · ' || v_title end,
                             v_url, 'sl-org-t' || v_tid, jsonb_build_object('tid', v_tid, 'r', v_nr),
                             format('t_org_pair:%s:%s:%s', v_tid, v_nr, new.rev), 86400, 'normal',
                             now() + interval '3 minutes');
      end if;
    end if;
  exception when others then
    raise warning 'push_t_after: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists push_t_after on public.tournaments;
create trigger push_t_after after update on public.tournaments
  for each row when (new.status = 'running' and new.payload->>'fmt' = 'swiss' and old.payload is distinct from new.payload)
  execute function public.push_t_after();

-- (1b, 2) Duels: a tournament invitation (guest), a join (host), a claim to
-- confirm (the other player).
create or replace function public.push_duel_after()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_t    tournaments%rowtype;
  v_ttl  int;
  v_to   uuid;
  v_sc   text;
  v_at   timestamptz;
begin
  begin
    if tg_op = 'INSERT' then
      if coalesce(new.t_invite, false) and new.status = 'waiting' and new.guest_id is not null
         and new.tournament_id is not null then
        select * into v_t from tournaments x where x.id = new.tournament_id;
        if found then
          v_ttl := greatest(60, least(1800, coalesce(floor(extract(epoch from new.pin_expires_at - now()))::int, 1800)));
          perform push_enqueue(new.guest_id, 'tournaments', 't_invite',
                               format('%s is waiting for you', push_name(new.host_id)),
                               concat_ws(' · ', 'Join your tournament game', t_game_label(v_t.payload, new.t_ref),
                                         coalesce(nullif(btrim(v_t.payload #>> '{pn,title}'), ''), 'Tournament')),
                               '#/tournaments/' || new.tournament_id, 'sl-next-t' || new.tournament_id,
                               jsonb_build_object('tid', new.tournament_id::text, 'duel', new.id::text),
                               't_invite:' || new.id, v_ttl, 'high');
        end if;
      end if;
    elsif old.status = 'waiting' and new.status = 'live' and new.guest_id is not null then
      perform push_enqueue(new.host_id, 'matches', 'm_join', format('%s joined your match', push_name(new.guest_id)),
                           coalesce('Playing ' || nullif(btrim(new.guest_seeker), ''), 'Open the tracker to play'),
                           '#/tracker', 'sl-duel-' || new.id, jsonb_build_object('duel', new.id::text),
                           'm_join:' || new.id, 900, 'high');
    elsif old.status = 'live' and new.status = 'ending' then
      v_to := case when new.claim_by = new.host_id then new.guest_id else new.host_id end;
      v_at := coalesce(new.claimed_at, now());
      v_sc := case when new.winner_score is not null and new.loser_score is not null
                   then format(' %s–%s', new.winner_score, new.loser_score) else '' end;
      perform push_enqueue(v_to, 'matches', 'm_confirm',
                           format('%s ended the match: confirm the result', push_name(new.claim_by)),
                           case when new.is_draw then 'Draw' || v_sc
                                else push_name(coalesce(new.claim_winner, new.claim_by)) || ' won' || v_sc end,
                           '#/tracker', 'sl-duel-' || new.id, jsonb_build_object('duel', new.id::text),
                           format('m_confirm:%s:%s', new.id, floor(extract(epoch from v_at) * 1000)::bigint),
                           greatest(600, 172800 - floor(extract(epoch from now() - v_at))::int), 'normal');
    end if;
  exception when others then
    raise warning 'push_duel_after: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists push_duel_after on public.duels;
create trigger push_duel_after after insert or update of status on public.duels
  for each row execute function public.push_duel_after();

-- (2) Multiplayer: a player sits down (host, until the match is full).
create or replace function public.push_gm_seat_after()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  g   group_matches%rowtype;
  v_n int;
begin
  begin
    select * into g from group_matches x where x.id = new.match_id;
    if found and g.status = 'waiting' then
      select count(*) into v_n from group_match_seats s where s.match_id = new.match_id;
      if v_n < g.seats then
        perform push_enqueue(g.host_id, 'matches', 'gm_join', format('%s joined your match', push_name(new.user_id)),
                             format('%s/%s seated · %s', v_n, g.seats, initcap(g.mode)),
                             '#/tracker', 'sl-gm-' || g.id, jsonb_build_object('gm', g.id::text),
                             format('gm_join:%s:%s:%s', g.id, new.user_id,
                                    floor(extract(epoch from new.joined_at) * 1000)::bigint),
                             900, 'high');
      end if;
    end if;
  exception when others then
    raise warning 'push_gm_seat_after: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists push_gm_seat_after on public.group_match_seats;
create trigger push_gm_seat_after after insert on public.group_match_seats
  for each row when (new.seat <> 0) execute function public.push_gm_seat_after();

-- (2) Multiplayer: the match is on (every seated player), a claim to confirm
-- (gm_confirmers).
create or replace function public.push_gm_after()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_u     uuid;
  v_names text;
  v_body  text;
begin
  begin
    if old.status = 'waiting' and new.status = 'live' then
      select string_agg(push_name(s.user_id), ', ' order by s.seat) into v_names
        from group_match_seats s where s.match_id = new.id and s.left_at is null;
      for v_u in select s.user_id from group_match_seats s where s.match_id = new.id and s.left_at is null loop
        perform push_enqueue(v_u, 'matches', 'gm_live', 'Your match is on',
                             concat_ws(' · ', initcap(new.mode), v_names),
                             '#/tracker', 'sl-gm-' || new.id, jsonb_build_object('gm', new.id::text),
                             format('gm_live:%s:%s', new.id, v_u), 1800, 'high');
      end loop;
    elsif old.status = 'live' and new.status = 'ending' then
      if new.claim_kind = 'draw' then
        v_body := 'Draw';
      else
        select 'Winner: ' || string_agg(push_name(s.user_id), ', ' order by s.seat) into v_body
          from group_match_seats s where s.match_id = new.id and s.side = new.claim_side;
      end if;
      for v_u in select c.u from gm_confirmers(new.id) c(u) loop
        perform push_enqueue(v_u, 'matches', 'gm_confirm',
                             format('%s ended the match: confirm the result', push_name(new.claim_by)),
                             coalesce(v_body, ''), '#/tracker', 'sl-gm-' || new.id,
                             jsonb_build_object('gm', new.id::text),
                             format('gm_confirm:%s:%s:%s', new.id,
                                    floor(extract(epoch from coalesce(new.claimed_at, now())) * 1000)::bigint, v_u),
                             172800, 'normal');
      end loop;
    end if;
  exception when others then
    raise warning 'push_gm_after: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists push_gm_after on public.group_matches;
create trigger push_gm_after after update of status on public.group_matches
  for each row execute function public.push_gm_after();

-- (3) Community events: a new listing (members except who added it; several
-- within 2 minutes become one message).
create or replace function public.push_ev_ins()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  l   leagues%rowtype;
  v_u uuid;
begin
  begin
    select * into l from leagues x where x.id = new.league_id and x.archived_at is null;
    if not found or (new.starts_at is not null and new.starts_at <= now()) then
      return null;
    end if;
    for v_u in select m.u from push_members(new.league_id) m(u) where m.u is distinct from new.created_by loop
      insert into push_event_sent (user_id, pn_id, kind, slot, league_id, pn_event_id)
      values (v_u, new.pn_id, 'new', coalesce(new.starts_at, 'epoch'), new.league_id, new.id)
      on conflict do nothing;
      if found then
        perform push_enqueue(v_u, 'events', 'ev_new', format('New event in %s', l.name),
                             case when new.starts_at is null then new.title else new.title || ' · {t}' end,
                             format('#/league/%s/events', new.league_id), 'sl-evn-' || new.league_id,
                             jsonb_build_object('lid', new.league_id::text, 'pn_id', new.pn_id, 'starts_at', new.starts_at,
                                                'league', l.name, 'last', new.title),
                             format('ev_new:%s:%s', new.pn_id, v_u),
                             case when new.starts_at is null then 604800
                                  else greatest(3600, least(604800, floor(extract(epoch from new.starts_at - now()))::int)) end,
                             'normal', now() + interval '2 minutes',
                             format('ev_new:%s:%s', new.league_id, v_u));
      end if;
    end loop;
  exception when others then
    raise warning 'push_ev_ins: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists push_ev_ins on public.pn_events;
create trigger push_ev_ins after insert on public.pn_events
  for each row execute function public.push_ev_ins();

-- (3) Reminders the day before (24 h to 3 h) and one hour before (60 to 5
-- minutes), run every minute by push_tick. A slot within 15 minutes of one
-- already reminded counts as the same; no "Coming up" within 12 hours of
-- "New event".
create or replace function public.push_event_sweep()
returns int language plpgsql security definer set search_path = public as $$
declare
  r     record;
  n     int := 0;
  v_ven text;
begin
  if not pg_try_advisory_xact_lock(hashtext('push_event_sweep')) then
    return 0;
  end if;
  for r in
    select distinct on (m.u, e.pn_id, k.kind)
           m.u, e.id as eid, e.pn_id, e.league_id, e.title, e.starts_at, e.venue, e.location_type,
           k.kind, l.name as lname
      from pn_events e
      join leagues l on l.id = e.league_id and l.archived_at is null
     cross join lateral (values ('day'), ('hour')) k(kind)
     cross join lateral push_members(e.league_id) m(u)
     where e.starts_at between now() and now() + interval '25 hours'
       and ((k.kind = 'day' and now() >= e.starts_at - interval '24 hours' and now() < e.starts_at - interval '3 hours'
                            and e.created_at <= e.starts_at - interval '24 hours')
         or (k.kind = 'hour' and now() >= e.starts_at - interval '60 minutes' and now() < e.starts_at - interval '5 minutes'))
       and not exists (select 1 from push_event_sent s
                        where s.user_id = m.u and s.pn_id = e.pn_id and s.kind = k.kind
                          and abs(extract(epoch from s.slot - e.starts_at)) < 900)
       and not (k.kind = 'day' and exists (select 1 from push_event_sent s
                                            where s.user_id = m.u and s.pn_id = e.pn_id and s.kind = 'new'
                                              and s.sent_at > now() - interval '12 hours'))
     order by m.u, e.pn_id, k.kind, e.created_at
  loop
    insert into push_event_sent (user_id, pn_id, kind, slot, league_id, pn_event_id)
    values (r.u, r.pn_id, r.kind, r.starts_at, r.league_id, r.eid)
    on conflict do nothing;
    if found then
      n := n + 1;
      v_ven := coalesce(nullif(btrim(r.venue), ''), nullif(btrim(r.location_type), ''));
      if r.kind = 'day' then
        perform push_enqueue(r.u, 'events', 'ev_day', 'Coming up: ' || r.title,
                             concat_ws(' · ', '{t}', v_ven, r.lname),
                             format('#/league/%s/events', r.league_id), 'sl-ev-' || r.pn_id,
                             jsonb_build_object('lid', r.league_id::text, 'pn_id', r.pn_id, 'starts_at', r.starts_at),
                             format('ev_day:%s:%s:%s', r.pn_id, floor(extract(epoch from r.starts_at))::bigint, r.u),
                             greatest(60, floor(extract(epoch from r.starts_at - now()))::int), 'normal');
      else
        perform push_enqueue(r.u, 'events', 'ev_hour', 'Starts soon: ' || r.title,
                             concat_ws(' · ', '{h}', v_ven),
                             format('#/league/%s/events', r.league_id), 'sl-ev-' || r.pn_id,
                             jsonb_build_object('lid', r.league_id::text, 'pn_id', r.pn_id, 'starts_at', r.starts_at),
                             format('ev_hour:%s:%s:%s', r.pn_id, floor(extract(epoch from r.starts_at))::bigint, r.u),
                             greatest(60, floor(extract(epoch from r.starts_at - now()))::int), 'high');
      end if;
    end if;
  end loop;
  return n;
end $$;

-- (3, extra) A listing removed after its reminder: "Event removed", unless the
-- member still sees the event in another of their communities.
create or replace function public.push_ev_del()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  l   leagues%rowtype;
  v_u uuid;
begin
  begin
    if old.starts_at is null or old.starts_at <= now() then
      return null;
    end if;
    select * into l from leagues x where x.id = old.league_id and x.archived_at is null;
    if not found then
      return null;
    end if;
    for v_u in
      select distinct s.user_id
        from push_event_sent s
       where s.pn_id = old.pn_id and s.kind in ('day','hour') and s.league_id = old.league_id
         and abs(extract(epoch from s.slot - old.starts_at)) < 900
         and s.user_id in (select m.u from push_members(old.league_id) m(u))
         and not exists (select 1 from pn_events e2
                          join leagues l2 on l2.id = e2.league_id and l2.archived_at is null
                         where e2.pn_id = old.pn_id and e2.id <> old.id
                           and (e2.league_id in (select m.league_id from memberships m
                                                  where m.user_id = s.user_id and m.dropped_at is null)
                                or l2.owner_id = s.user_id))
    loop
      insert into push_event_sent (user_id, pn_id, kind, slot, league_id, pn_event_id)
      values (v_u, old.pn_id, 'removed', old.starts_at, old.league_id, old.id)
      on conflict do nothing;
      if found then
        perform push_enqueue(v_u, 'events', 'ev_removed', 'Event removed: ' || old.title,
                             l.name || ' took it off its events',
                             format('#/league/%s/events', old.league_id), 'sl-ev-' || old.pn_id,
                             jsonb_build_object('lid', old.league_id::text, 'pn_id', old.pn_id, 'starts_at', old.starts_at),
                             format('ev_removed:%s:%s:%s', old.pn_id, floor(extract(epoch from old.starts_at))::bigint, v_u),
                             greatest(60, floor(extract(epoch from old.starts_at - now()))::int), 'normal');
      end if;
    end loop;
  exception when others then
    raise warning 'push_ev_del: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists push_ev_del on public.pn_events;
create trigger push_ev_del after delete on public.pn_events
  for each row execute function public.push_ev_del();

-- (4) Board notices: a new notice (members and owner except the author), 60 s
-- late so a notice deleted in the undo window is never pushed.
create or replace function public.push_nt_ins()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  l   leagues%rowtype;
  v_u uuid;
  v_b text;
begin
  begin
    if new.league_id is null or (new.expires_at is not null and new.expires_at <= now()) then
      return null;
    end if;
    select * into l from leagues x where x.id = new.league_id and x.archived_at is null;
    if not found then
      return null;
    end if;
    v_b := regexp_replace(coalesce(trim_blank(new.body), ''), '\s+', ' ', 'g');
    v_b := left(v_b, 100) || case when char_length(v_b) > 100 then '…' else '' end;
    for v_u in select m.u from push_members(new.league_id) m(u) where m.u is distinct from new.author_id loop
      perform push_enqueue(v_u, 'notices', 'nt_new', l.name || ': new notice', v_b,
                           format('#/league/%s/about', new.league_id), 'sl-nt-' || new.league_id,
                           jsonb_build_object('lid', new.league_id::text, 'aid', new.id::text),
                           format('nt_new:%s:%s', new.id, v_u),
                           case when new.expires_at is null then 259200
                                else greatest(60, least(259200, floor(extract(epoch from new.expires_at - now()))::int - 60)) end,
                           'normal', now() + interval '60 seconds');
    end loop;
  exception when others then
    raise warning 'push_nt_ins: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists push_nt_ins on public.announcements;
create trigger push_nt_ins after insert on public.announcements
  for each row execute function public.push_nt_ins();

-- Account deletion (erase_user_data sets deleted_at last): no push rows stay.
create or replace function public.push_profile_gone()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin
    delete from push_subscriptions where user_id = new.id;
    delete from notify_prefs       where user_id = new.id;
    delete from push_outbox        where user_id = new.id;
    delete from push_event_sent    where user_id = new.id;
  exception when others then
    raise warning 'push_profile_gone: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists push_profile_gone on public.profiles;
create trigger push_profile_gone after update of deleted_at on public.profiles
  for each row when (old.deleted_at is null and new.deleted_at is not null)
  execute function public.push_profile_gone();

-- 4. Client RPCs (signed-in players) ------------------------------------------------
-- push_uid: the caller, null when signed out, a guest or deleted.
create or replace function public.push_uid()
returns uuid language sql stable security definer set search_path = public as $$
  select p.id from profiles p
   where p.id = auth.uid() and p.deleted_at is null
     and not coalesce((auth.jwt()->>'is_anonymous')::boolean, false);
$$;

-- push_subscribe: this browser's subscription, for the caller (moved from
-- another account when the browser is the same). At most 10 per player.
create or replace function public.push_subscribe(p_endpoint text, p_p256dh text, p_auth text,
                                                 p_ua text default null, p_old text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := push_uid();
  v_host text;
  v_id   uuid;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'code', 'signed_out');
  end if;
  v_host := lower(substring(p_endpoint from '^https://([^/:?#]+)'));
  if p_endpoint is null or char_length(p_endpoint) > 1024 or v_host is null
     or v_host !~ '^(fcm\.googleapis\.com|android\.googleapis\.com|updates\.push\.services\.mozilla\.com|[a-z0-9.-]+\.push\.apple\.com|[a-z0-9.-]+\.notify\.windows\.com)$' then
    return jsonb_build_object('ok', false, 'code', 'bad_endpoint');
  end if;
  if coalesce(p_p256dh, '') !~ '^[A-Za-z0-9_-]{86,88}$' or coalesce(p_auth, '') !~ '^[A-Za-z0-9_-]{21,24}$' then
    return jsonb_build_object('ok', false, 'code', 'bad_keys');
  end if;
  perform pg_advisory_xact_lock(hashtext('push_subscribe:' || v_uid::text));
  insert into push_subscriptions (user_id, endpoint, p256dh, auth, ua, last_seen_at, fails)
  values (v_uid, p_endpoint, p_p256dh, p_auth, left(nullif(btrim(p_ua), ''), 200), now(), 0)
  on conflict (endpoint) do update
     set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, ua = excluded.ua,
         last_seen_at = now(), fails = 0
  returning id into v_id;
  if p_old is not null and p_old <> p_endpoint then
    delete from push_subscriptions where user_id = v_uid and endpoint = p_old;
  end if;
  delete from push_subscriptions
   where id in (select s.id from push_subscriptions s where s.user_id = v_uid
                 order by coalesce(s.last_seen_at, s.created_at) desc, s.created_at desc, s.id
                 offset 10);
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.push_unsubscribe(p_endpoint text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := push_uid();
  v_n   int;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'code', 'signed_out');
  end if;
  delete from push_subscriptions where user_id = v_uid and endpoint = p_endpoint;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'removed', v_n);
end $$;

create or replace function public.push_set_pref(p_family text, p_on boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := push_uid();
  v_on  boolean := coalesce(p_on, false);
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'code', 'signed_out');
  end if;
  if p_family is null or p_family not in ('tournaments','matches','events','notices') then
    return jsonb_build_object('ok', false, 'code', 'bad_family');
  end if;
  insert into notify_prefs (user_id) values (v_uid) on conflict (user_id) do nothing;
  update notify_prefs
     set tournaments = case when p_family = 'tournaments' then v_on else tournaments end,
         matches     = case when p_family = 'matches'     then v_on else matches end,
         events      = case when p_family = 'events'      then v_on else events end,
         notices     = case when p_family = 'notices'     then v_on else notices end,
         updated_at  = now()
   where user_id = v_uid;
  return jsonb_build_object('ok', true, 'prefs', push_prefs(v_uid));
end $$;

-- push_state: prefs, devices, whether p_endpoint is the caller's, and whether
-- the server side is set up (never the secret itself).
create or replace function public.push_state(p_endpoint text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := push_uid();
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'code', 'signed_out');
  end if;
  return jsonb_build_object(
    'ok', true, 'prefs', push_prefs(v_uid),
    'devices', (select count(*) from push_subscriptions s where s.user_id = v_uid),
    'here', p_endpoint is not null
            and exists (select 1 from push_subscriptions s where s.user_id = v_uid and s.endpoint = p_endpoint),
    'ready', push_cfg('secret') is not null and to_regnamespace('net') is not null);
end $$;

-- push_test: one test message to the caller's devices, at most one a minute.
create or replace function public.push_test()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := push_uid();
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'code', 'signed_out');
  end if;
  return jsonb_build_object('ok', true, 'queued',
    push_enqueue(v_uid, 'test', 'test', 'Notifications work', 'This is a test from Seekers League.', '#/', 'sl-test',
                 '{}'::jsonb, format('test:%s:%s', v_uid, floor(extract(epoch from now()) / 60)::bigint), 600, 'normal'));
end $$;

-- 5. Sender RPCs (push-send, service role) ------------------------------------------
-- push_stale: why a claimed row must not go out any more (null: send it).
create or replace function public.push_stale(o public.push_outbox)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  d    jsonb := coalesce(o.data, '{}'::jsonb);
  v_t  tournaments%rowtype;
  v_e  pn_events%rowtype;
  v_s  text;
  v_c  int;
begin
  if o.family <> 'test' and not push_on(o.user_id, o.family) then
    return 'pref_off';
  end if;
  if o.family in ('events','notices')
     and not exists (select 1 from push_members((d->>'lid')::uuid) m(u) where m.u = o.user_id) then
    return 'not_member';
  end if;
  if o.kind = 'nt_new' then
    if not exists (select 1 from announcements a where a.id = (d->>'aid')::uuid
                    and (a.expires_at is null or a.expires_at > now())) then
      return 'gone';
    end if;
  elsif (o.kind = 'ev_new' and coalesce((d->>'n')::int, 1) = 1) or o.kind in ('ev_day','ev_hour') then
    select * into v_e from pn_events e
     where e.league_id = (d->>'lid')::uuid and e.pn_id = (d->>'pn_id')::int
     order by e.created_at limit 1;
    if not found then
      return 'gone';
    end if;
    if o.kind in ('ev_day','ev_hour')
       and (v_e.starts_at is null
            or abs(extract(epoch from v_e.starts_at - (d->>'starts_at')::timestamptz)) > 900) then
      return 'moved';
    end if;
  elsif o.kind in ('t_round','t_bye','t_org_hand','t_org_pair') then
    select * into v_t from tournaments x where x.id = (d->>'tid')::uuid;
    if not found or v_t.status is distinct from 'running' then
      return 'stale';
    end if;
    v_c := t_sw_cur(v_t.payload);
    if o.kind = 't_org_pair' then
      if v_c > (d->>'r')::int or not t_gm_done(v_t.payload) then
        return 'stale';
      end if;
    elsif v_c <> (d->>'r')::int then
      return 'stale';
    end if;
  elsif o.kind in ('t_invite','m_join','m_confirm') then
    select x.status into v_s from duels x where x.id = (d->>'duel')::uuid;
    if v_s is distinct from (case o.kind when 't_invite' then 'waiting' when 'm_join' then 'live' else 'ending' end) then
      return 'stale';
    end if;
  elsif o.kind in ('gm_join','gm_live','gm_confirm') then
    select x.status into v_s from group_matches x where x.id = (d->>'gm')::uuid;
    if v_s is distinct from (case o.kind when 'gm_join' then 'waiting' when 'gm_live' then 'live' else 'ending' end) then
      return 'stale';
    end if;
    if o.kind = 'gm_confirm'
       and not exists (select 1 from gm_confirmers((d->>'gm')::uuid) c(u) where c.u = o.user_id) then
      return 'stale';
    end if;
  end if;
  return null;
exception when others then
  return null;
end $$;

-- push_claim: up to p_limit due rows, leased for p_lease_s seconds, each with
-- the player's subscriptions. Rows without a subscription, or stale ones, are
-- closed here and not returned.
create or replace function public.push_claim(p_limit int default 40, p_lease_s int default 120)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_lim   int := least(greatest(coalesce(p_limit, 40), 1), 200);
  v_lease int := least(greatest(coalesce(p_lease_s, 120), 10), 900);
  o       push_outbox%rowtype;
  v_subs  jsonb;
  v_why   text;
  v_out   jsonb := '[]'::jsonb;
begin
  for o in
    with due as (
      select x.id from push_outbox x
       where x.sent_at is null and x.not_before <= now() and x.expires_at > now() and x.attempts < 6
         and (x.claimed_until is null or x.claimed_until < now())
       order by x.not_before, x.id
       limit v_lim
       for update skip locked
    )
    update push_outbox x
       set claimed_until = now() + make_interval(secs => v_lease), attempts = x.attempts + 1
      from due where x.id = due.id
    returning x.*
  loop
    select jsonb_agg(jsonb_build_object('id', s.id, 'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth)
                     order by coalesce(s.last_seen_at, s.created_at) desc, s.id)
      into v_subs
      from push_subscriptions s where s.user_id = o.user_id;
    if v_subs is null then
      update push_outbox set sent_at = now(), claimed_until = null, last_error = 'no_subscription' where id = o.id;
      continue;
    end if;
    v_why := push_stale(o);
    if v_why is not null then
      update push_outbox set sent_at = now(), claimed_until = null, last_error = 'stale:' || v_why where id = o.id;
      continue;
    end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id', o.id, 'kind', o.kind, 'fam', o.family, 'title', o.title, 'body', o.body, 'url', o.url, 'tag', o.tag,
      'urgency', o.urgency, 'ttl', greatest(0, floor(extract(epoch from o.expires_at - now())))::int,
      'attempts', o.attempts, 'ts', to_char(o.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'data', o.data, 'subs', v_subs));
  end loop;
  return v_out;
end $$;

-- push_uuids: the uuid strings of a jsonb array (anything else is skipped).
create or replace function public.push_uuids(p jsonb)
returns uuid[] language sql immutable security definer set search_path = public as $$
  select coalesce(array_agg(v::uuid), '{}')
    from jsonb_array_elements_text(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end) q(v)
   where v ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
$$;

-- push_done: what push-send did with each claimed row and subscription.
create or replace function public.push_done(p_res jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  x       jsonb;
  v_id    bigint;
  v_err   text;
  v_ra    int;
  v_att   int;
  v_n     int;
  v_sent  int := 0;
  v_retry int := 0;
  v_fail  int := 0;
  v_gone  int := 0;
begin
  if jsonb_typeof(p_res) is distinct from 'array' then
    return jsonb_build_object('ok', false, 'code', 'bad_input');
  end if;
  for x in select q.x from jsonb_array_elements(p_res) q(x) where jsonb_typeof(q.x) = 'object' loop
    -- the subscriptions, even when the row is no longer claimed
    delete from push_subscriptions where id = any(push_uuids(x->'gone'));
    get diagnostics v_n = row_count;
    v_gone := v_gone + v_n;
    update push_subscriptions set last_ok_at = now(), fails = 0 where id = any(push_uuids(x->'okd'));
    update push_subscriptions set fails = fails + 1 where id = any(push_uuids(x->'bad'));
    delete from push_subscriptions
     where id = any(push_uuids(x->'bad')) and fails >= 8
       and coalesce(last_ok_at, created_at) < now() - interval '14 days';

    -- the row
    if coalesce(x->>'id', '') !~ '^[0-9]{1,18}$' then
      continue;
    end if;
    v_id := (x->>'id')::bigint;
    v_err := left(nullif(btrim(x->>'err'), ''), 200);
    if x->>'status' in ('sent','failed') then
      update push_outbox set sent_at = now(), claimed_until = null, last_error = v_err
       where id = v_id and sent_at is null;
      get diagnostics v_n = row_count;
      if x->>'status' = 'sent' then v_sent := v_sent + v_n; else v_fail := v_fail + v_n; end if;
    elsif x->>'status' = 'retry' then
      select o.attempts into v_att from push_outbox o
       where o.id = v_id and o.sent_at is null and o.claimed_until is not null for update;
      if not found then
        continue;
      end if;
      if v_att >= 6 then
        update push_outbox set sent_at = now(), claimed_until = null, last_error = 'gave_up:' || coalesce(v_err, 'retry')
         where id = v_id;
        v_fail := v_fail + 1;
      else
        v_ra := case when jsonb_typeof(x->'retry_after_s') = 'number'
                     then least(greatest(floor((x->>'retry_after_s')::numeric), 0), 86400)::int end;
        update push_outbox
           set claimed_until = null, last_error = v_err,
               not_before = now() + make_interval(secs => least(3600, greatest(coalesce(v_ra, 0),
                                                                             60 * power(2, greatest(v_att, 1) - 1))))
         where id = v_id;
        v_retry := v_retry + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'sent', v_sent, 'retry', v_retry, 'failed', v_fail, 'gone', v_gone);
end $$;

-- 6. Delivery schedule and retention -------------------------------------------------
-- push_tick (pg_cron, every minute): the reminders, expired rows closed, and a
-- kick when something is due (rows queued for later, retries).
create or replace function public.push_tick()
returns int language plpgsql security definer set search_path = public as $$
declare
  n int := 0;
begin
  if not pg_try_advisory_xact_lock(hashtext('push_tick')) then
    return 0;
  end if;
  begin
    n := push_event_sweep();
  exception when others then
    raise warning 'push_tick (reminders): %', sqlerrm;
  end;
  update push_outbox set sent_at = now(), claimed_until = null, last_error = 'expired'
   where sent_at is null and expires_at <= now() and (claimed_until is null or claimed_until < now());
  update push_outbox set sent_at = now(), claimed_until = null, last_error = 'gave_up:lease'
   where sent_at is null and attempts >= 6 and (claimed_until is null or claimed_until < now());
  if exists (select 1 from push_outbox o
              where o.sent_at is null and o.not_before <= now() and o.expires_at > now() and o.attempts < 6
                and (o.claimed_until is null or o.claimed_until < now())) then
    perform push_kick();
  end if;
  return n;
end $$;

-- purge_old_rows (nightly sl-purge-old-rows): the two old deletes unchanged,
-- plus the push tables and pg_cron's run log.
create or replace function public.purge_old_rows()
returns integer language plpgsql security definer set search_path = public as $$
declare n integer; m integer; t integer := 0;
begin
  delete from app_events where created_at < now() - interval '90 days';
  get diagnostics n = row_count;
  delete from feedback where created_at < now() - interval '12 months';
  get diagnostics m = row_count;
  t := n + m;
  delete from push_outbox where created_at < now() - interval '7 days';
  get diagnostics m = row_count; t := t + m;
  delete from push_event_sent
   where (slot > 'epoch' and slot < now() - interval '7 days')
      or (slot = 'epoch' and sent_at < now() - interval '60 days');
  get diagnostics m = row_count; t := t + m;
  delete from push_subscriptions where coalesce(last_ok_at, last_seen_at, created_at) < now() - interval '120 days';
  get diagnostics m = row_count; t := t + m;
  if to_regclass('cron.job_run_details') is not null then
    begin
      execute 'delete from cron.job_run_details where end_time < now() - interval ''7 days''';
    exception when others then
      raise warning 'purge cron log: %', sqlerrm;
    end;
  end if;
  return t;
end $$;

-- pg_cron job sl-push, every minute. Re-running replaces the job.
do $$
begin
  begin
    create extension if not exists pg_cron with schema pg_catalog;
  exception when others then
    raise notice 'pg_cron is not available (%); nothing sends queued pushes on a schedule.', sqlerrm;
  end;
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      perform cron.unschedule(j.jobid) from cron.job j where j.jobname = 'sl-push';
      perform cron.schedule('sl-push', '* * * * *', 'select public.push_tick()');
    exception when others then
      raise notice 'Could not schedule sl-push (%).', sqlerrm;
    end;
  end if;
end $$;

-- 7. Who may call what -----------------------------------------------------------------
revoke all on function public.push_cfg(text)                                   from public, anon, authenticated;
revoke all on function public.push_kick()                                      from public, anon, authenticated;
revoke all on function public.push_on(uuid, text)                              from public, anon, authenticated;
revoke all on function public.push_prefs(uuid)                                 from public, anon, authenticated;
revoke all on function public.push_name(uuid)                                  from public, anon, authenticated;
revoke all on function public.push_t_name(jsonb, text)                         from public, anon, authenticated;
revoke all on function public.push_t_drop(jsonb, text)                         from public, anon, authenticated;
revoke all on function public.push_t_open(jsonb, int)                          from public, anon, authenticated;
revoke all on function public.push_members(uuid)                               from public, anon, authenticated;
revoke all on function public.push_enqueue(uuid, text, text, text, text, text, text, jsonb, text, int, text, timestamptz, text)
                                                                               from public, anon, authenticated;
revoke all on function public.push_t_after()                                   from public, anon, authenticated;
revoke all on function public.push_duel_after()                                from public, anon, authenticated;
revoke all on function public.push_gm_seat_after()                             from public, anon, authenticated;
revoke all on function public.push_gm_after()                                  from public, anon, authenticated;
revoke all on function public.push_ev_ins()                                    from public, anon, authenticated;
revoke all on function public.push_event_sweep()                               from public, anon, authenticated;
revoke all on function public.push_ev_del()                                    from public, anon, authenticated;
revoke all on function public.push_nt_ins()                                    from public, anon, authenticated;
revoke all on function public.push_profile_gone()                              from public, anon, authenticated;
revoke all on function public.push_uid()                                       from public, anon, authenticated;
revoke all on function public.push_stale(public.push_outbox)                   from public, anon, authenticated;
revoke all on function public.push_uuids(jsonb)                                from public, anon, authenticated;
revoke all on function public.push_tick()                                      from public, anon, authenticated;
revoke all on function public.purge_old_rows()                                 from public, anon, authenticated;
revoke all on function public.push_subscribe(text, text, text, text, text)     from public, anon, authenticated;
revoke all on function public.push_unsubscribe(text)                           from public, anon, authenticated;
revoke all on function public.push_set_pref(text, boolean)                     from public, anon, authenticated;
revoke all on function public.push_state(text)                                 from public, anon, authenticated;
revoke all on function public.push_test()                                      from public, anon, authenticated;
revoke all on function public.push_claim(int, int)                             from public, anon, authenticated;
revoke all on function public.push_done(jsonb)                                 from public, anon, authenticated;
grant execute on function public.push_subscribe(text, text, text, text, text)  to authenticated;
grant execute on function public.push_unsubscribe(text)                        to authenticated;
grant execute on function public.push_set_pref(text, boolean)                  to authenticated;
grant execute on function public.push_state(text)                              to authenticated;
grant execute on function public.push_test()                                   to authenticated;
grant execute on function public.push_claim(int, int)                          to service_role;
grant execute on function public.push_done(jsonb)                              to service_role;

-- ============================================================
--  PLAYER ICONS (2026-11-23)
-- ============================================================
-- Run as migration-2026-11-23-avatars.sql.
-- What changes:
--   * profiles.avatar text, null by default. null = the default image (the
--     Seekers League emblem); 'O', 'C', 'P' or 'L' = the icon of Order,
--     Conclave, Primal or Legion (the page's faction letters, FAC_HEX and
--     LICON in index.html). Anything else is refused (profiles_avatar_check).
--   * Who may change it: the player, on their own row, like the name
--     ("own profile update" policy; guard_profile_update still refuses a
--     deleted account). Everyone may read it, like the rest of the profile
--     ("profiles readable").
--   * A deleted account goes back to the default image: the new trigger
--     profile_avatar_tombstone clears avatar on any row with deleted_at set
--     (erase_user_data sets deleted_at, so it needs no change).
--   * Not changed: no function or view returns a fixed list of profile
--     columns that the page shows as a picture. The page shows icons for the
--     signed-in player (loadMe: select()) and on a player's profile page
--     (a direct select on profiles that now names avatar).

-- 1. The column ------------------------------------------------------------------
alter table public.profiles add column if not exists avatar text;
do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'profiles_avatar_check' and conrelid = 'public.profiles'::regclass) then
    alter table public.profiles add constraint profiles_avatar_check
      check (avatar in ('O', 'C', 'P', 'L'));
  end if;
end $$;
comment on column public.profiles.avatar is
  'The player''s icon: null = default image, O/C/P/L = Order/Conclave/Primal/Legion icon. Set by the player.';

-- 2. A deleted account shows the default image ---------------------------------------
create or replace function public.profile_avatar_tombstone()
returns trigger language plpgsql set search_path = public as $$
begin
  new.avatar := null;
  return new;
end $$;
revoke all on function public.profile_avatar_tombstone() from public, anon, authenticated;
drop trigger if exists profile_avatar_tombstone on public.profiles;
create trigger profile_avatar_tombstone before insert or update on public.profiles
  for each row when (new.deleted_at is not null and new.avatar is not null)
  execute function public.profile_avatar_tombstone();
update public.profiles set avatar = null where deleted_at is not null and avatar is not null;

-- ============================================================
--  MAKERS (2026-11-24)
-- ============================================================
-- Run as migration-2026-11-24-makers.sql.
-- What changes:
--   * profiles.makes text, null by default. null = makes nothing; otherwise
--     the letters of what the player makes for other players, in this order:
--     F = FDM printing, R = resin printing, P = painting ('F', 'R', 'P',
--     'FR', 'FP', 'RP' or 'FRP'). Anything else is refused
--     (profiles_makes_check), so each letter appears at most once.
--   * profiles.makes_note text, null by default: a short note (at most 80
--     characters, e.g. "32mm minis, pickup in Naples"). Stored trimmed (spaces,
--     no-break and other Unicode spaces, zero-width marks); blank becomes null;
--     no control characters and no bidi override/isolate characters, which
--     could flip the text around it (profiles_makes_note_check). Only
--     kept while makes is set: clearing makes clears the note
--     (profiles_makes_note_needs_makes, and the trigger below does it for you).
--   * Who may change them: the player, on their own row, like the name
--     ("own profile update" policy; guard_profile_update still refuses a
--     deleted account). Everyone may read them, signed in or not, like the
--     map pin and the Herald rank ("profiles readable"): the page lists makers
--     on a community's Makers tab and on Explore > Makers.
--   * The new trigger profile_makes_tidy removes bidi controls from the note,
--     trims it, turns a blank one into null (e.g. only zero-width spaces),
--     drops the note when makes is null, and clears both on any
--     row with deleted_at set (a deleted account is never listed as a maker;
--     erase_user_data sets deleted_at, so it needs no change).
--   * profiles_makers_idx: a small partial index for the Explore list
--     (makes is not null and deleted_at is null).
--   * Not changed: no function or view returns a fixed list of profile
--     columns that the page uses for makers (the page reads profiles and
--     memberships -> profiles directly).

-- 1. The columns -----------------------------------------------------------------
alter table public.profiles add column if not exists makes text;
alter table public.profiles add column if not exists makes_note text;
do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'profiles_makes_check' and conrelid = 'public.profiles'::regclass) then
    alter table public.profiles add constraint profiles_makes_check
      check (makes in ('F', 'R', 'P', 'FR', 'FP', 'RP', 'FRP'));
  end if;
  -- an earlier draft of this file had no bidi/Unicode-space rule: replace it
  if exists (select 1 from pg_constraint
              where conname = 'profiles_makes_note_check' and conrelid = 'public.profiles'::regclass
                and pg_get_constraintdef(oid) not like '%u202A%') then
    alter table public.profiles drop constraint profiles_makes_note_check;
  end if;
  if not exists (select 1 from pg_constraint
                 where conname = 'profiles_makes_note_check' and conrelid = 'public.profiles'::regclass) then
    alter table public.profiles add constraint profiles_makes_note_check
      check (char_length(makes_note) between 1 and 80
             and makes_note = btrim(makes_note)
             and makes_note !~ '[[:cntrl:]]'
             and makes_note !~ '[\u202A-\u202E\u2066-\u2069]'
             and makes_note !~ '^[[:space:]\u00A0\u1680\u2000-\u200D\u2028\u2029\u202F\u205F\u2060\u3000\uFEFF]|[[:space:]\u00A0\u1680\u2000-\u200D\u2028\u2029\u202F\u205F\u2060\u3000\uFEFF]$');
  end if;
  if not exists (select 1 from pg_constraint
                 where conname = 'profiles_makes_note_needs_makes' and conrelid = 'public.profiles'::regclass) then
    alter table public.profiles add constraint profiles_makes_note_needs_makes
      check (makes_note is null or makes is not null);
  end if;
end $$;
comment on column public.profiles.makes is
  'What the player makes for other players (Makers): null = nothing, else F (FDM printing), R (resin printing), P (painting) in that order. Public. Set by the player.';
comment on column public.profiles.makes_note is
  'Makers: a short public note (1..80 characters, trimmed, no bidi controls), only while makes is set. Set by the player.';

-- 2. Tidy the note; a deleted account makes nothing --------------------------------
create or replace function public.profile_makes_tidy()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.deleted_at is not null then
    new.makes := null;
    new.makes_note := null;
    return new;
  end if;
  -- bidi override/isolate characters out; then trim spaces (any Unicode
  -- space) and zero-width marks at both ends, as the page does
  new.makes_note := nullif(regexp_replace(
                      regexp_replace(new.makes_note, '[\u202A-\u202E\u2066-\u2069]', '', 'g'),
                      '^[[:space:]\u00A0\u1680\u2000-\u200D\u2028\u2029\u202F\u205F\u2060\u3000\uFEFF]+|[[:space:]\u00A0\u1680\u2000-\u200D\u2028\u2029\u202F\u205F\u2060\u3000\uFEFF]+$',
                      '', 'g'), '');
  if new.makes is null then
    new.makes_note := null;
  end if;
  return new;
end $$;
revoke all on function public.profile_makes_tidy() from public, anon, authenticated;
drop trigger if exists profile_makes_tidy on public.profiles;
create trigger profile_makes_tidy before insert or update on public.profiles
  for each row when (new.makes is not null or new.makes_note is not null)
  execute function public.profile_makes_tidy();
update public.profiles set makes = null, makes_note = null
 where deleted_at is not null and (makes is not null or makes_note is not null);

-- 3. The Explore list reads only the makers ------------------------------------------
create index if not exists profiles_makers_idx on public.profiles (id)
  where makes is not null and deleted_at is null;

-- ============================================================
--  NEW SEEKERS IN THE DECK DEDUPE (2026-11-25)
-- ============================================================
-- Run as migration-2026-11-25-new-seekers.sql.
-- What changes:
--   * deck_sig_legacy (PLAY NETWORK DECK DEDUPE above) knows the two Seekers
--     of the Fury and Dread Seeker Decks (out 2026-11-12): Mad Jonru,
--     Starving Maw -> Malwat Cauldron and Nar'Tak Bluebane -> Guise of the
--     Videre (12 Seekers in all, as on the page). Before it, for those two a
--     Play Network list without the Legacy and the same deck made in the
--     builder were seen as different decks.
create or replace function public.deck_sig_legacy(p text)
returns text language sql immutable set search_path = public as $$
  select '{"auricevenhand":"willoftheforge","countessmorridaumberland":"soulstitcher",
           "grizalingeringwound":"ihreniv","ingorthespiritbound":"effigyofchaos",
           "karmamok":"lienawhodreams","londrielspellwarden":"arkoflamentation",
           "madjonrustarvingmaw":"malwatcauldron","nartakbluebane":"guiseofthevidere",
           "polinoreprimearchivist":"runefoldgauntlet","sigrithandravos":"andravon",
           "thundersteps":"stormseye","vorendalthedreadheart":"heartlock"}'::jsonb ->> nullif(p, '');
$$;
revoke all on function public.deck_sig_legacy(text) from public, anon, authenticated;


-- ============================================================
--  HOME COUNTERS (2026-11-26)
-- ============================================================
-- Run as migration-2026-11-26-site-counts.sql.
-- What changes:
--   * site_counts() gives the four numbers of Home's "The Malediction is
--     growing" band, as totals only (no ids, names or rows), to anyone:
--       communities  public communities that are not archived;
--       players      accounts that are not deleted;
--       tournaments  tournaments past their draft (running, closed, and the
--                    older ones that have no status);
--       matches      every finished game, each once:
--         - tracked 1v1 matches (duels, status 'done', draws included,
--           tournament games included);
--         - multiplayer matches (group_matches, status 'done');
--         - results entered by hand in a tournament (payload v2/v3: a group
--           or Swiss game with a winner or a draw, a finals game with a
--           winner), unless a finished tracked match is that game (its 'du',
--           or a done duel with the tournament, the slot and the same two
--           players); byes and forfeits ('bye', 'drop') were never played;
--         - matches logged by hand (the matches table), confirmed, without
--           the copies sync_tournament once wrote for a tournament
--           (tournament_id), whose games already count from the payload.
--     As in the Meta (meta_duels), nothing of a Swiss tournament still in
--     draft or running counts, so the number cannot tell how far one is.
--     Cancelled and expired matches never count.
--     The older tournaments (no status) are still edited from the site by
--     their community's admins, so there a result counts only between two
--     accounts, and each pair of players once in the groups and once in the
--     finals (a round robin and a knockout never pair two players twice).
--     As in the Meta, a game an organizer both recorded in an older
--     tournament and logged again as an ordinary match counts twice (the two
--     cannot be told apart).
--     Before it, Home counted only the matches table under its read rules
--     (anon saw a few rows), and the profiles and tournaments it could read.
--   * idx_duels_tref: finished tournament duels by tournament and slot, so
--     matching a result to its tracked match stays quick on big tournaments.
--   * guard_tournament(): an older tournament's payload saved from the site
--     may not grow past 1 MB (the cap new tournaments already have). Every
--     other rule of it is as before.
--   * Not changed: every table, policy and other function.
create index if not exists idx_duels_tref on public.duels (tournament_id, t_ref)
  where status = 'done' and tournament_id is not null;

create or replace function public.guard_tournament()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return coalesce(new, old);
  end if;
  if tg_op = 'INSERT' then
    raise exception 'New tournaments are made from a Play Network event' using errcode = '42501';
  elsif tg_op = 'DELETE' then
    if old.status is not null then
      raise exception 'Discard this tournament from its page' using errcode = '42501';
    end if;
    return old;
  end if;
  if old.status is not null or new.status is not null
     or new.pn_event_id is distinct from old.pn_event_id
     or new.organizer_id is distinct from old.organizer_id
     or new.mode is distinct from old.mode
     or new.rev is distinct from old.rev
     or new.payload->>'v' = '3' then
    raise exception 'This tournament is changed from its page' using errcode = '42501';
  end if;
  -- An older tournament's payload may not grow past 1 MB (a real one is a
  -- few KB); one already bigger can still be saved smaller.
  if octet_length(new.payload::text) > 1048576
     and octet_length(new.payload::text) > octet_length(coalesce(old.payload, '{}'::jsonb)::text) then
    raise exception 'This tournament is too large to save' using errcode = '54000';
  end if;
  return new;
end $$;

create or replace function public.site_counts()
returns json
language sql stable security definer set search_path = public, pg_temp as $$
  with
  -- Swiss tournaments still in draft or running: none of their games count.
  hide as (
    select t.id from tournaments t
     where t.status in ('draft', 'running') and t.payload->>'fmt' = 'swiss'
  ),
  shown as (
    select t.id, t.payload, t.status is null as legacy from tournaments t
     where t.payload->>'v' in ('2', '3')
       and t.status is distinct from 'draft'
       and not exists (select 1 from hide h where h.id = t.id)
  ),
  -- Results in the payloads: a group or Swiss game {a, b, w}, w = a, b or
  -- 'draw'; a finals game {a: {id}, b: {id}, winner: 'a' | 'b'}.
  tg as (
    select s.id as tid, s.legacy, 'g:' || (x.o - 1) as ref,
           x.m->>'a' as a, x.m->>'b' as b, x.m->>'du' as du
      from shown s
     cross join lateral jsonb_array_elements(
             case when jsonb_typeof(s.payload->'gm') = 'array' then s.payload->'gm' else '[]'::jsonb end
           ) with ordinality x(m, o)
     where jsonb_typeof(x.m) = 'object'
       and x.m->>'a' is not null and x.m->>'b' is not null and x.m->>'a' <> x.m->>'b'
       and (x.m->>'w' = 'draw' or x.m->>'w' = x.m->>'a' or x.m->>'w' = x.m->>'b')
       and coalesce(x.m->>'src', '') not in ('bye', 'drop')
    union all
    select s.id, s.legacy, 'b:' || (r.o - 1) || ':' || (q.o - 1),
           q.m #>> '{a,id}', q.m #>> '{b,id}', q.m->>'du'
      from shown s
     cross join lateral jsonb_array_elements(
             case when jsonb_typeof(s.payload->'bracket') = 'array' then s.payload->'bracket' else '[]'::jsonb end
           ) with ordinality r(rd, o)
     cross join lateral jsonb_array_elements(
             case when jsonb_typeof(r.rd) = 'array' then r.rd else '[]'::jsonb end
           ) with ordinality q(m, o)
     where jsonb_typeof(q.m) = 'object'
       and q.m #>> '{a,id}' is not null and q.m #>> '{b,id}' is not null
       and q.m #>> '{a,id}' <> q.m #>> '{b,id}'
       and q.m->>'winner' in ('a', 'b')
       and coalesce(q.m->>'src', '') not in ('bye', 'drop')
  ),
  -- Older tournaments (no status) are edited from the site by their
  -- community's admins: a result counts only between two accounts, and each
  -- pair once in the groups ('g') and once in the finals ('b').
  legacy_ok as (
    select distinct on (tg.tid, left(tg.ref, 1), least(tg.a, tg.b), greatest(tg.a, tg.b)) tg.*
      from tg
     where tg.legacy
       and exists (select 1 from profiles p
                    where p.id = case when tg.a ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                                      then tg.a::uuid end)
       and exists (select 1 from profiles p
                    where p.id = case when tg.b ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                                      then tg.b::uuid end)
     order by tg.tid, left(tg.ref, 1), least(tg.a, tg.b), greatest(tg.a, tg.b), tg.ref
  ),
  games as (
    select * from tg where not tg.legacy
    union all
    select * from legacy_ok
  )
  select json_build_object(
    'communities', (select count(*) from leagues l where l.is_public and l.archived_at is null),
    'players',     (select count(*) from profiles p where p.deleted_at is null),
    'tournaments', (select count(*) from tournaments t where t.status is distinct from 'draft'),
    'matches',
      (select count(*) from duels d
        where d.status = 'done'
          and not exists (select 1 from hide h where h.id = d.tournament_id))
    + (select count(*) from group_matches g where g.status = 'done')
    + (select count(*) from matches m where m.confirmed is true and m.tournament_id is null)
    -- a result typed in a payload, unless a finished tracked match is that
    -- game: its 'du', or the same tournament, slot and two players (two
    -- separate lookups, each by an index)
    + (select count(*) from games g
        where not exists (
                select 1 from duels d
                 where d.status = 'done'
                   and d.id = case when g.du ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                                   then g.du::uuid end)
          and not exists (
                select 1 from duels d
                 where d.status = 'done'
                   and d.tournament_id = g.tid and d.t_ref = g.ref
                   and ((d.host_id::text = g.a and d.guest_id::text = g.b)
                        or (d.host_id::text = g.b and d.guest_id::text = g.a))))
  );
$$;
revoke all on function public.site_counts() from public;
grant execute on function public.site_counts() to anon, authenticated;
comment on function public.site_counts() is
  'Home counters: totals only (communities, players, tournaments, matches = every finished game once; nothing of a Swiss tournament in draft or running). Callable by anyone.';

-- ============================================================
--  BOARD MODERATION (2026-11-27)
-- ============================================================
-- Run as migration-2026-11-27-board-moderation.sql.
-- What changes:
--   * Who moderates a community's board: its creator (leagues.owner_id) and
--     its co-organizers (memberships.is_admin, not dropped), as before for
--     deleting messages, plus the site admin everywhere. The organizers and
--     the creator of a community can't be muted, reported or blocked there,
--     and don't mute or report there themselves (they moderate instead). The
--     site admin moderates every community, so never mutes or reports.
--   * board_mutes (new): any member can mute another player. The muted
--     player's board messages are hidden from them in every community (the
--     read policy filters them, so "the latest 100" stay 100 visible ones),
--     except the messages of a community where the muted player is an
--     organizer or the creator, and except on a board they moderate
--     themselves. Private: each player reads and deletes only their own rows;
--     new rows only through board_mute(). At most 1000 per player. The muted
--     player isn't told.
--   * board_reports (new): any member can report a board message of their
--     community (not their own, not an organizer's): spam, harassment,
--     inappropriate or other, with an optional note (up to 200 characters,
--     one line). One report per message per reporter; 10 an hour and 30 a
--     day per reporter. Each report keeps a copy of the message, so it
--     survives the author deleting it. Only the community's organizers, its
--     creator and the site admin read reports (who sent them included),
--     never the reports about their own messages (a member who becomes an
--     organizer later, or the site admin as a member); they close them: dismiss, delete the message, block the author, or
--     delete and block. A moderator deleting a message (the board's x or the
--     Reports list) closes its open reports as 'deleted'; the author deleting
--     their own message leaves them open.
--   * board_blocks (new): the moderators of a community can stop a member
--     from writing on its board, with an optional reason (up to 200
--     characters) that the blocked player sees (not who blocked them). A
--     blocked player is still a
--     member, still reads the board and can still delete their own messages.
--     The moderators and the blocked player read the row; changes only
--     through board_block() / board_unblock() / board_resolve(). A block of a
--     player who later becomes an organizer is ignored (kept, not applied).
--   * check_board_write(): as in COMMUNITY BOARD AND ADDRESS (2026-11-18),
--     plus a blocked player is refused (hint 'blocked') before the brake, so
--     a refused message never counts. The "board members write" policy
--     refuses a blocked player too (the backstop), the "board members read"
--     policy hides muted players. "board delete" is not changed: the author,
--     the organizers and the site admin delete (any message, for the last two).
--   * Length: not changed. A message is still 1 to 1000 characters as stored,
--     formatting marks (**bold**, *italic*, __underline__, # Title,
--     [text](link), :d20:) included; the page counts the same 1000.
--   * New RPCs for the page (signed-in players with an account; none for
--     signed-out visitors): board_state, board_mute, board_unmute,
--     board_mutes, board_report, board_reports_list, board_resolve,
--     board_block, board_unblock. Each answers jsonb and refuses with a hint
--     the page reads (sign_in, deleted, self, gone, not_member, moderator,
--     organizer, own, bad_reason, bad_note, too_many, rate_limited, not_mod,
--     bad_status, bad_action).
--   * Push: a new report notifies the creator and the co-organizers of that
--     community (not the reporter, not the site admin) under their "Board
--     notices" switch, without the message text (kind bd_report). It is
--     dropped when the reports of that message are closed before it goes
--     out (push_stale: as in WEB PUSH NOTIFICATIONS (2026-11-22), plus that
--     one check). An archived community sends no report push. The other
--     pushes are not changed.
--   * Deleting an account removes its mutes (made and received), its reports
--     (sent and about its messages) and its blocks (trigger
--     board_profile_gone, like push_profile_gone: erase_user_data is not
--     changed).

-- 0. Who organizes a community (any player, not only the caller). Used only
-- inside the functions below; not callable over the API.
create or replace function public.board_is_org(p_league uuid, p_user uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select p_user is not null and (
    exists (select 1 from leagues l where l.id = p_league and l.owner_id = p_user)
    or exists (select 1 from memberships m
                where m.league_id = p_league and m.user_id = p_user
                  and m.is_admin and m.dropped_at is null));
$$;

-- The caller of a board RPC: refused when signed out, a guest (anonymous
-- sign-in) or deleted, as check_board_write refuses them.
create or replace function public.board_me()
returns uuid language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null or coalesce((auth.jwt()->>'is_anonymous')::boolean, false) then
    raise exception 'Sign in with an account to do this' using errcode = '42501', hint = 'sign_in';
  end if;
  if not exists (select 1 from profiles p where p.id = v_uid and p.deleted_at is null) then
    raise exception 'This account was deleted' using errcode = '42501', hint = 'deleted';
  end if;
  return v_uid;
end $$;

-- A one-line note: control characters become spaces, bidi controls go,
-- every kind of blank is trimmed, blank means none.
create or replace function public.board_clean(p text)
returns text language sql immutable parallel safe set search_path = public, pg_temp as $$
  select nullif(trim_blank(regexp_replace(regexp_replace(p, '[\u0001-\u001f\u007f]', ' ', 'g'),
                                          '[\u202a-\u202e\u2066-\u2069]', '', 'g')), '');
$$;

-- 1. Tables ------------------------------------------------------------------------
-- Mutes: user_id hides muted_id's board messages.
create table if not exists public.board_mutes (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  muted_id   uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, muted_id)
);
alter table public.board_mutes drop constraint if exists board_mutes_not_self;
alter table public.board_mutes add constraint board_mutes_not_self check (user_id <> muted_id);
create index if not exists idx_board_mutes_muted on public.board_mutes(muted_id);

-- Blocks: user_id may not write on league_id's board.
create table if not exists public.board_blocks (
  league_id  uuid not null references public.leagues(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  reason     text,
  blocked_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (league_id, user_id)
);
alter table public.board_blocks drop constraint if exists board_blocks_reason_len;
alter table public.board_blocks add constraint board_blocks_reason_len
  check (reason is null or char_length(reason) between 1 and 200);
create index if not exists idx_board_blocks_user on public.board_blocks(user_id);

-- Reports: message_id has no foreign key, so a report outlives the message
-- (body keeps a copy) and the reports of one message stay together.
create table if not exists public.board_reports (
  id          uuid primary key default gen_random_uuid(),
  league_id   uuid not null references public.leagues(id) on delete cascade,
  message_id  uuid not null,
  author_id   uuid references public.profiles(id) on delete cascade,
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  reason      text not null,
  note        text,
  body        text not null,
  status      text not null default 'open',
  resolved_by uuid references public.profiles(id) on delete set null,
  resolved_at timestamptz,
  created_at  timestamptz not null default now()
);
alter table public.board_reports drop constraint if exists board_reports_reason;
alter table public.board_reports add constraint board_reports_reason
  check (reason in ('spam', 'harassment', 'inappropriate', 'other'));
alter table public.board_reports drop constraint if exists board_reports_note;
alter table public.board_reports add constraint board_reports_note
  check (note is null or char_length(note) between 1 and 200);
alter table public.board_reports drop constraint if exists board_reports_body;
alter table public.board_reports add constraint board_reports_body
  check (char_length(body) between 1 and 2000);
alter table public.board_reports drop constraint if exists board_reports_status;
alter table public.board_reports add constraint board_reports_status
  check (status in ('open', 'dismissed', 'deleted', 'blocked', 'deleted_blocked'));
alter table public.board_reports drop constraint if exists board_reports_closed;
alter table public.board_reports add constraint board_reports_closed
  check ((status = 'open') = (resolved_at is null));
create unique index if not exists uq_board_reports_once on public.board_reports(message_id, reporter_id);
create index if not exists idx_board_reports_league on public.board_reports(league_id, status, created_at desc);
create index if not exists idx_board_reports_open on public.board_reports(created_at desc) where status = 'open';
create index if not exists idx_board_reports_reporter on public.board_reports(reporter_id, created_at);
create index if not exists idx_board_reports_author on public.board_reports(author_id);
create index if not exists idx_board_reports_message on public.board_reports(message_id, status);

alter table public.board_mutes   enable row level security;
alter table public.board_blocks  enable row level security;
alter table public.board_reports enable row level security;
drop policy if exists "mutes own read" on public.board_mutes;
drop policy if exists "mutes own delete" on public.board_mutes;
drop policy if exists "blocks read" on public.board_blocks;
drop policy if exists "reports moderators read" on public.board_reports;
create policy "mutes own read" on public.board_mutes
  for select to authenticated using (user_id = auth.uid());
create policy "mutes own delete" on public.board_mutes
  for delete to authenticated using (user_id = auth.uid());
create policy "blocks read" on public.board_blocks
  for select to authenticated
  using (user_id = auth.uid() or is_league_admin(league_id) or is_site_admin());
create policy "reports moderators read" on public.board_reports
  for select to authenticated
  using ((is_league_admin(league_id) or is_site_admin()) and author_id is distinct from auth.uid());

revoke all on public.board_mutes   from anon, authenticated;
revoke all on public.board_blocks  from anon, authenticated;
revoke all on public.board_reports from anon, authenticated;
grant select, delete on public.board_mutes to authenticated;
-- Not blocked_by: the blocked player reads their own row, but not who blocked
-- them (the moderators see that through board_state).
grant select (league_id, user_id, reason, created_at) on public.board_blocks to authenticated;
grant select on public.board_reports to authenticated;
grant select, insert, update, delete on public.board_mutes   to service_role;
grant select, insert, update, delete on public.board_blocks  to service_role;
grant select, insert, update, delete on public.board_reports to service_role;

-- 2. Helpers of the policies (about the caller only) ----------------------------------
-- Does the caller hide p_author's messages in p_league? Their own mute, the
-- author not an organizer there, the caller not a moderator there.
create or replace function public.board_muted(p_league uuid, p_author uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select p_author is not null and p_author is distinct from auth.uid()
     and exists (select 1 from board_mutes b where b.user_id = auth.uid() and b.muted_id = p_author)
     and not board_is_org(p_league, p_author)
     and not is_league_admin(p_league) and not is_site_admin();
$$;

-- Is the caller blocked from writing in p_league? (an organizer never is)
create or replace function public.board_blocked(p_league uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from board_blocks b where b.league_id = p_league and b.user_id = auth.uid())
     and not board_is_org(p_league, auth.uid());
$$;

-- 3. The board: the read and write policies, the write check -----------------------
drop policy if exists "board members read" on public.community_messages;
drop policy if exists "board members write" on public.community_messages;
-- As in COMMUNITY BOARD AND ADDRESS (2026-11-18), without the players the
-- reader muted.
create policy "board members read" on public.community_messages
  for select to authenticated
  using ((is_active_member(league_id) or is_league_admin(league_id) or is_site_admin()
          or author_id = auth.uid())
         and not board_muted(league_id, author_id));
-- The trigger gives the clear refusals; this is the backstop (a blocked
-- player included).
create policy "board members write" on public.community_messages
  for insert to authenticated
  with check (author_id = auth.uid()
              and (is_active_member(league_id) or is_league_owner(league_id))
              and not coalesce((auth.jwt()->>'is_anonymous')::boolean, false)
              and not board_blocked(league_id));

-- check_board_write(): as in COMMUNITY BOARD AND ADDRESS (2026-11-18), plus
-- the block, checked before the brake (a refused message is not counted),
-- and pg_temp last in the search_path.
create or replace function public.check_board_write(p_league uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null or coalesce((auth.jwt()->>'is_anonymous')::boolean, false) then
    raise exception 'Sign in with an account to write on the board'
      using errcode = '42501', hint = 'sign_in';
  end if;
  if not exists (select 1 from profiles p where p.id = v_uid and p.deleted_at is null) then
    raise exception 'This account was deleted' using errcode = '42501', hint = 'deleted';
  end if;
  if not (is_active_member(p_league) or is_league_owner(p_league)) then
    raise exception 'Only the members of this community can write on its board'
      using errcode = '42501', hint = 'not_member';
  end if;
  if exists (select 1 from leagues l where l.id = p_league and l.archived_at is not null) then
    raise exception 'This community is archived' using errcode = '42501', hint = 'archived';
  end if;
  if exists (select 1 from board_blocks b where b.league_id = p_league and b.user_id = v_uid)
     and not board_is_org(p_league, v_uid) then
    raise exception 'You can''t write on this board right now'
      using errcode = '42501', hint = 'blocked';
  end if;
  -- One writer at a time per author, so two quick sends cannot both slip
  -- under the brake.
  perform pg_advisory_xact_lock(hashtext('community_board'), hashtext(v_uid::text));
  delete from community_message_writes w
   where w.author_id = v_uid and w.at <= now() - interval '1 hour';
  if (select count(*) from community_message_writes w
       where w.author_id = v_uid and w.at > now() - interval '1 minute') >= 5 then
    raise exception 'You wrote 5 messages in the last minute. Wait a moment and try again.'
      using errcode = 'P0001', hint = 'rate_limited';
  end if;
  if (select count(*) from community_message_writes w
       where w.author_id = v_uid and w.at > now() - interval '1 hour') >= 60 then
    raise exception 'You wrote 60 messages in the last hour. Try again later.'
      using errcode = 'P0001', hint = 'rate_limited';
  end if;
  if pg_trigger_depth() > 0 then
    insert into community_message_writes(author_id, at) values (v_uid, now());
  end if;
end $$;

-- A moderator deleting a message (the board's x, board_resolve, the SQL
-- editor) closes its open reports as 'deleted'; the author deleting their
-- own message (an organizer's included) leaves them open (the copy stays for
-- the other moderators). A report
-- problem never blocks a delete.
create or replace function public.board_message_gone()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  begin
    if auth.uid() is null
       or (old.author_id is distinct from auth.uid()
           and (is_league_admin(old.league_id) or is_site_admin())) then
      update board_reports
         set status = 'deleted', resolved_by = auth.uid(), resolved_at = now()
       where message_id = old.id and status = 'open';
    end if;
  exception when others then
    raise warning 'board_message_gone: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists board_message_gone on public.community_messages;
create trigger board_message_gone after delete on public.community_messages
  for each row execute function public.board_message_gone();

-- Account deletion (erase_user_data sets deleted_at last): no mutes, reports
-- or blocks of the account stay.
create or replace function public.board_profile_gone()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  begin
    delete from board_mutes   where user_id = new.id or muted_id = new.id;
    delete from board_reports where reporter_id = new.id or author_id = new.id;
    delete from board_blocks  where user_id = new.id;
    update board_blocks  set blocked_by  = null where blocked_by  = new.id;
    update board_reports set resolved_by = null where resolved_by = new.id;
  exception when others then
    raise warning 'board_profile_gone: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists board_profile_gone on public.profiles;
create trigger board_profile_gone after update of deleted_at on public.profiles
  for each row when (old.deleted_at is null and new.deleted_at is not null)
  execute function public.board_profile_gone();

-- 4. RPCs for the page ------------------------------------------------------------------
-- board_state: what the board needs besides the messages. blocked* is about
-- the caller (never for an organizer); open_reports (messages with an open
-- report) and blocks only for a moderator of p_league. Signed out, a guest or
-- a deleted account: all false / empty, no error.
create or replace function public.board_state(p_league uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := auth.uid();
  v_mod boolean := false;
  b     board_blocks%rowtype;
  v_n   int := 0;
  v_bl  jsonb := '[]'::jsonb;
begin
  if v_uid is null or coalesce((auth.jwt()->>'is_anonymous')::boolean, false)
     or not exists (select 1 from profiles p where p.id = v_uid and p.deleted_at is null) then
    return jsonb_build_object('mod', false, 'blocked', false, 'block_reason', null, 'blocked_at', null,
                              'open_reports', 0, 'blocks', '[]'::jsonb);
  end if;
  v_mod := is_league_admin(p_league) or is_site_admin();
  if not board_is_org(p_league, v_uid) then
    select * into b from board_blocks x where x.league_id = p_league and x.user_id = v_uid;
  end if;
  if v_mod then
    select count(distinct r.message_id) into v_n from board_reports r
     where r.league_id = p_league and r.status = 'open' and r.author_id is distinct from v_uid;
    select coalesce(jsonb_agg(jsonb_build_object(
             'user_id', x.user_id, 'name', p.display_name, 'avatar', p.avatar, 'reason', x.reason,
             'at', x.created_at, 'by_name', q.display_name) order by x.created_at desc), '[]'::jsonb)
      into v_bl
      from (select * from board_blocks y
             where y.league_id = p_league and not board_is_org(p_league, y.user_id)
             order by y.created_at desc limit 200) x
      join profiles p on p.id = x.user_id
      left join profiles q on q.id = x.blocked_by;
  end if;
  return jsonb_build_object('mod', v_mod, 'blocked', b.user_id is not null,
                            'block_reason', b.reason, 'blocked_at', b.created_at,
                            'open_reports', v_n, 'blocks', v_bl);
end $$;

-- board_mute: a member (not a moderator of p_league, not the site admin)
-- hides p_user, who is not an organizer of p_league (the community the
-- message was in). Answers {ok, muted}.
create or replace function public.board_mute(p_user uuid, p_league uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := board_me();
begin
  if p_user = v_uid then
    raise exception 'You cannot mute yourself' using errcode = '22023', hint = 'self';
  end if;
  if p_user is null or not exists (select 1 from profiles p where p.id = p_user and p.deleted_at is null) then
    raise exception 'This player is no longer here' using errcode = 'P0002', hint = 'gone';
  end if;
  if is_league_admin(p_league) or is_site_admin() then
    raise exception 'You moderate this board: block players instead of muting them'
      using errcode = '42501', hint = 'moderator';
  end if;
  if not is_active_member(p_league) then
    raise exception 'Only the members of this community can mute players here'
      using errcode = '42501', hint = 'not_member';
  end if;
  if board_is_org(p_league, p_user) then
    raise exception 'The organizers of a community cannot be muted there'
      using errcode = '42501', hint = 'organizer';
  end if;
  if not exists (select 1 from board_mutes b where b.user_id = v_uid and b.muted_id = p_user)
     and (select count(*) from board_mutes b where b.user_id = v_uid) >= 1000 then
    raise exception 'You muted 1000 players. Unmute some first.' using errcode = 'P0001', hint = 'too_many';
  end if;
  insert into board_mutes(user_id, muted_id) values (v_uid, p_user) on conflict do nothing;
  return jsonb_build_object('ok', true, 'muted', true);
end $$;

create or replace function public.board_unmute(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := board_me();
  v_n   int;
begin
  delete from board_mutes b where b.user_id = v_uid and b.muted_id = p_user;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'was', v_n > 0);
end $$;

-- The caller's mutes, newest first (Account > Muted).
create or replace function public.board_mutes()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := board_me();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', b.muted_id, 'name', p.display_name, 'avatar', p.avatar,
                                        'at', b.created_at) order by b.created_at desc)
      from board_mutes b join profiles p on p.id = b.muted_id
     where b.user_id = v_uid and p.deleted_at is null), '[]'::jsonb);
end $$;

-- board_report: a member reports a message they can read in their community
-- (not their own, not an organizer's). Answers {ok, id, already}.
create or replace function public.board_report(p_message uuid, p_reason text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid  uuid := board_me();
  m      community_messages%rowtype;
  v_note text := board_clean(p_note);
  v_id   uuid;
begin
  select * into m from community_messages x where x.id = p_message;
  if not found
     or not (is_active_member(m.league_id) or is_league_admin(m.league_id) or is_site_admin()
             or m.author_id = v_uid)
     or board_muted(m.league_id, m.author_id) then
    raise exception 'This message is no longer there' using errcode = 'P0002', hint = 'gone';
  end if;
  if is_league_admin(m.league_id) or is_site_admin() then
    raise exception 'You moderate this board: delete the message or block its author instead'
      using errcode = '42501', hint = 'moderator';
  end if;
  if not is_active_member(m.league_id) then
    raise exception 'Only the members of this community can report its messages'
      using errcode = '42501', hint = 'not_member';
  end if;
  if m.author_id = v_uid then
    raise exception 'You cannot report your own message' using errcode = '22023', hint = 'own';
  end if;
  if board_is_org(m.league_id, m.author_id) then
    raise exception 'The organizers'' messages cannot be reported' using errcode = '42501', hint = 'organizer';
  end if;
  if p_reason is null or p_reason not in ('spam', 'harassment', 'inappropriate', 'other') then
    raise exception 'Pick a reason: spam, harassment, inappropriate or other'
      using errcode = '22023', hint = 'bad_reason';
  end if;
  if char_length(v_note) > 200 then
    raise exception 'Keep the note to 200 characters' using errcode = '22023', hint = 'bad_note';
  end if;
  perform pg_advisory_xact_lock(hashtext('board_report'), hashtext(v_uid::text));
  select r.id into v_id from board_reports r where r.message_id = p_message and r.reporter_id = v_uid;
  if v_id is not null then
    return jsonb_build_object('ok', true, 'id', v_id, 'already', true);
  end if;
  if (select count(*) from board_reports r
       where r.reporter_id = v_uid and r.created_at > now() - interval '1 hour') >= 10
     or (select count(*) from board_reports r
          where r.reporter_id = v_uid and r.created_at > now() - interval '24 hours') >= 30 then
    raise exception 'You sent a lot of reports. Try again later.' using errcode = 'P0001', hint = 'rate_limited';
  end if;
  insert into board_reports(league_id, message_id, author_id, reporter_id, reason, note, body)
  values (m.league_id, m.id, m.author_id, v_uid, p_reason, v_note, m.body)
  on conflict (message_id, reporter_id) do nothing
  returning id into v_id;
  if v_id is null then
    select r.id into v_id from board_reports r where r.message_id = p_message and r.reporter_id = v_uid;
    return jsonb_build_object('ok', true, 'id', v_id, 'already', true);
  end if;
  return jsonb_build_object('ok', true, 'id', v_id, 'already', false);
end $$;

-- board_reports_list: the reports of p_league (its moderators), or of every
-- community (p_league null: the site admin), one item per message, newest
-- report first. p_status: 'open' (at least one open report), 'closed' (all
-- closed, the last within 30 days) or 'all'. Never the reports about the
-- caller's own messages. Answers {open, items}.
create or replace function public.board_reports_list(p_league uuid default null, p_status text default 'open',
                                                     p_limit int default 50)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_uid   uuid := board_me();
  v_lim   int := least(greatest(coalesce(p_limit, 50), 0), 100);
  v_open  int;
  v_items jsonb;
begin
  if not (case when p_league is null then is_site_admin() else is_league_admin(p_league) or is_site_admin() end) then
    raise exception 'Only the organizers of this community can see its reports'
      using errcode = '42501', hint = 'not_mod';
  end if;
  if p_status is null or p_status not in ('open', 'closed', 'all') then
    raise exception 'Unknown list' using errcode = '22023', hint = 'bad_status';
  end if;
  select count(distinct r.message_id) into v_open from board_reports r
   where (p_league is null or r.league_id = p_league) and r.status = 'open'
     and r.author_id is distinct from v_uid;
  with g as (
    select r.message_id, r.league_id,
           bool_or(r.status = 'open') as is_open,
           min(r.created_at) as first_at, max(r.created_at) as last_at,
           max(r.resolved_at) as last_res
      from board_reports r
     where (p_league is null or r.league_id = p_league)
       and r.author_id is distinct from v_uid
     group by r.message_id, r.league_id
  ), s as (
    select g.* from g
     where (case p_status when 'open' then g.is_open
                          when 'closed' then not g.is_open and g.last_res > now() - interval '30 days'
                          else true end)
     order by g.last_at desc
     limit v_lim
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'message_id', s.message_id, 'league_id', s.league_id, 'league_name', l.name,
           'author_id', a.author_id, 'author_name', pa.display_name,
           'author_org', board_is_org(s.league_id, a.author_id),
           'author_blocked', a.author_id is not null
                             and exists (select 1 from board_blocks b where b.league_id = s.league_id and b.user_id = a.author_id)
                             and not board_is_org(s.league_id, a.author_id),
           'message_exists', exists (select 1 from community_messages c where c.id = s.message_id),
           'body', a.body, 'first_at', s.first_at, 'last_at', s.last_at,
           'status', case when s.is_open then 'open' else a.last_status end,
           'reports', a.reports) order by s.last_at desc), '[]'::jsonb)
    into v_items
    from s
    join leagues l on l.id = s.league_id
    cross join lateral (
      select (array_agg(r.author_id order by r.created_at desc))[1] as author_id,
             (array_agg(r.body order by r.created_at desc))[1] as body,
             (array_agg(r.status order by r.resolved_at desc nulls last))[1] as last_status,
             jsonb_agg(jsonb_build_object(
               'id', r.id, 'reporter_id', r.reporter_id, 'reporter_name', pr.display_name,
               'reason', r.reason, 'note', r.note, 'created_at', r.created_at, 'status', r.status,
               'resolved_at', r.resolved_at, 'resolved_by_name', pv.display_name) order by r.created_at desc) as reports
        from board_reports r
        left join profiles pr on pr.id = r.reporter_id
        left join profiles pv on pv.id = r.resolved_by
       where r.message_id = s.message_id and r.league_id = s.league_id
    ) a
    left join profiles pa on pa.id = a.author_id;
  return jsonb_build_object('open', v_open, 'items', v_items);
end $$;

-- board_block / board_unblock: a moderator of p_league stops p_user (not an
-- organizer there, not themselves) from writing on its board, or lets them
-- write again. A new reason replaces the old one; the date stays.
create or replace function public.board_block(p_league uuid, p_user uuid, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := board_me();
  v_r   text := board_clean(p_reason);
begin
  if not (is_league_admin(p_league) or is_site_admin()) then
    raise exception 'Only the organizers of this community can block players here'
      using errcode = '42501', hint = 'not_mod';
  end if;
  if p_user = v_uid then
    raise exception 'You cannot block yourself' using errcode = '22023', hint = 'self';
  end if;
  if p_user is null or not exists (select 1 from profiles p where p.id = p_user and p.deleted_at is null) then
    raise exception 'This player is no longer here' using errcode = 'P0002', hint = 'gone';
  end if;
  if board_is_org(p_league, p_user) then
    raise exception 'The organizers of a community cannot be blocked there'
      using errcode = '42501', hint = 'organizer';
  end if;
  if char_length(v_r) > 200 then
    raise exception 'Keep the reason to 200 characters' using errcode = '22023', hint = 'bad_note';
  end if;
  insert into board_blocks(league_id, user_id, reason, blocked_by) values (p_league, p_user, v_r, v_uid)
  on conflict (league_id, user_id) do update set reason = excluded.reason, blocked_by = excluded.blocked_by;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.board_unblock(p_league uuid, p_user uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := board_me();
  v_n   int;
begin
  if not (is_league_admin(p_league) or is_site_admin()) then
    raise exception 'Only the organizers of this community can unblock players here'
      using errcode = '42501', hint = 'not_mod';
  end if;
  delete from board_blocks b where b.league_id = p_league and b.user_id = p_user;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'was', v_n > 0);
end $$;

-- board_resolve: a moderator closes every open report of a message:
-- 'dismiss', 'delete' (the message, if still there), 'block' (its author in
-- that community, p_reason = the block reason) or 'delete_block'. Blocking an
-- organizer refuses the whole call. Answers {ok, closed, deleted, blocked}.
create or replace function public.board_resolve(p_message uuid, p_action text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid  uuid := board_me();
  v_l    uuid;
  v_a    uuid;
  v_ids  uuid[];
  v_del  boolean := false;
  v_blk  boolean := false;
  v_st   text;
  v_r    text := board_clean(p_reason);
begin
  if p_action is null or p_action not in ('dismiss', 'delete', 'block', 'delete_block') then
    raise exception 'Unknown action' using errcode = '22023', hint = 'bad_action';
  end if;
  select r.league_id, r.author_id into v_l, v_a from board_reports r
   where r.message_id = p_message order by r.created_at desc limit 1;
  if v_l is null then
    raise exception 'No report for this message' using errcode = 'P0002', hint = 'gone';
  end if;
  if not (is_league_admin(v_l) or is_site_admin()) then
    raise exception 'Only the organizers of this community can close its reports'
      using errcode = '42501', hint = 'not_mod';
  end if;
  if v_a = v_uid then
    raise exception 'The reports about your own message are for the other moderators'
      using errcode = '42501', hint = 'own';
  end if;
  if p_action in ('block', 'delete_block') then
    if v_a is null or not exists (select 1 from profiles p where p.id = v_a and p.deleted_at is null) then
      raise exception 'This player is no longer here' using errcode = 'P0002', hint = 'gone';
    end if;
    if v_a = v_uid or board_is_org(v_l, v_a) then
      raise exception 'The organizers of a community cannot be blocked there'
        using errcode = '42501', hint = 'organizer';
    end if;
    if char_length(v_r) > 200 then
      raise exception 'Keep the reason to 200 characters' using errcode = '22023', hint = 'bad_note';
    end if;
  end if;
  select array_agg(r.id) into v_ids from board_reports r
   where r.message_id = p_message and r.status = 'open';
  if p_action in ('delete', 'delete_block') then
    delete from community_messages c where c.id = p_message;
    v_del := found;
  end if;
  if p_action in ('block', 'delete_block') then
    insert into board_blocks(league_id, user_id, reason, blocked_by) values (v_l, v_a, v_r, v_uid)
    on conflict (league_id, user_id) do update set reason = excluded.reason, blocked_by = excluded.blocked_by;
    v_blk := true;
  end if;
  v_st := (case p_action when 'dismiss' then 'dismissed' when 'delete' then 'deleted'
                         when 'block' then 'blocked' else 'deleted_blocked' end);
  update board_reports r set status = v_st, resolved_by = v_uid, resolved_at = now()
   where r.id = any(coalesce(v_ids, '{}'::uuid[]));
  return jsonb_build_object('ok', true, 'closed', coalesce(cardinality(v_ids), 0),
                            'deleted', v_del, 'blocked', v_blk);
end $$;

-- 5. Push: a new report tells the creator and the co-organizers --------------------------
-- (family 'notices', the "Board notices" switch; no message text). Never for
-- the reporter (push_enqueue skips the actor); nothing in an archived community.
create or replace function public.board_report_push()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  l   leagues%rowtype;
  v_u uuid;
begin
  begin
    select * into l from leagues x where x.id = new.league_id and x.archived_at is null;
    if not found then
      return null;
    end if;
    for v_u in
      select l.owner_id
      union
      select m.user_id from memberships m
       where m.league_id = new.league_id and m.is_admin and m.dropped_at is null
    loop
      perform push_enqueue(v_u, 'notices', 'bd_report', left(l.name, 80) || ': a board message was reported',
                           'Reason: ' || initcap(new.reason) || '. Open the board to review it.',
                           format('#/league/%s/about', new.league_id), 'sl-bdr-' || new.league_id,
                           jsonb_build_object('lid', new.league_id::text, 'mid', new.message_id::text),
                           format('bd_report:%s:%s', new.id, v_u), 86400, 'normal', now() + interval '30 seconds');
    end loop;
  exception when others then
    raise warning 'board_report_push: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists board_report_push on public.board_reports;
create trigger board_report_push after insert on public.board_reports
  for each row execute function public.board_report_push();

-- push_stale(): as in WEB PUSH NOTIFICATIONS (2026-11-22), plus bd_report:
-- dropped once every report of that message is closed; pg_temp last in the
-- search_path.
create or replace function public.push_stale(o public.push_outbox)
returns text language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  d    jsonb := coalesce(o.data, '{}'::jsonb);
  v_t  tournaments%rowtype;
  v_e  pn_events%rowtype;
  v_s  text;
  v_c  int;
begin
  if o.family <> 'test' and not push_on(o.user_id, o.family) then
    return 'pref_off';
  end if;
  if o.family in ('events','notices')
     and not exists (select 1 from push_members((d->>'lid')::uuid) m(u) where m.u = o.user_id) then
    return 'not_member';
  end if;
  if o.kind = 'nt_new' then
    if not exists (select 1 from announcements a where a.id = (d->>'aid')::uuid
                    and (a.expires_at is null or a.expires_at > now())) then
      return 'gone';
    end if;
  elsif o.kind = 'bd_report' then
    if not exists (select 1 from board_reports r where r.message_id = (d->>'mid')::uuid
                    and r.league_id = (d->>'lid')::uuid and r.status = 'open') then
      return 'gone';
    end if;
  elsif (o.kind = 'ev_new' and coalesce((d->>'n')::int, 1) = 1) or o.kind in ('ev_day','ev_hour') then
    select * into v_e from pn_events e
     where e.league_id = (d->>'lid')::uuid and e.pn_id = (d->>'pn_id')::int
     order by e.created_at limit 1;
    if not found then
      return 'gone';
    end if;
    if o.kind in ('ev_day','ev_hour')
       and (v_e.starts_at is null
            or abs(extract(epoch from v_e.starts_at - (d->>'starts_at')::timestamptz)) > 900) then
      return 'moved';
    end if;
  elsif o.kind in ('t_round','t_bye','t_org_hand','t_org_pair') then
    select * into v_t from tournaments x where x.id = (d->>'tid')::uuid;
    if not found or v_t.status is distinct from 'running' then
      return 'stale';
    end if;
    v_c := t_sw_cur(v_t.payload);
    if o.kind = 't_org_pair' then
      if v_c > (d->>'r')::int or not t_gm_done(v_t.payload) then
        return 'stale';
      end if;
    elsif v_c <> (d->>'r')::int then
      return 'stale';
    end if;
  elsif o.kind in ('t_invite','m_join','m_confirm') then
    select x.status into v_s from duels x where x.id = (d->>'duel')::uuid;
    if v_s is distinct from (case o.kind when 't_invite' then 'waiting' when 'm_join' then 'live' else 'ending' end) then
      return 'stale';
    end if;
  elsif o.kind in ('gm_join','gm_live','gm_confirm') then
    select x.status into v_s from group_matches x where x.id = (d->>'gm')::uuid;
    if v_s is distinct from (case o.kind when 'gm_join' then 'waiting' when 'gm_live' then 'live' else 'ending' end) then
      return 'stale';
    end if;
    if o.kind = 'gm_confirm'
       and not exists (select 1 from gm_confirmers((d->>'gm')::uuid) c(u) where c.u = o.user_id) then
      return 'stale';
    end if;
  end if;
  return null;
exception when others then
  return null;
end $$;

-- 6. Grants -------------------------------------------------------------------------------
revoke all on function public.board_is_org(uuid, uuid)                  from public, anon, authenticated;
revoke all on function public.board_me()                                from public, anon, authenticated;
revoke all on function public.board_clean(text)                         from public, anon, authenticated;
revoke all on function public.board_message_gone()                      from public, anon, authenticated;
revoke all on function public.board_profile_gone()                      from public, anon, authenticated;
revoke all on function public.board_report_push()                          from public, anon, authenticated;
revoke all on function public.push_stale(public.push_outbox)            from public, anon, authenticated;
revoke all on function public.board_muted(uuid, uuid)                   from public, anon;
revoke all on function public.board_blocked(uuid)                       from public, anon;
revoke all on function public.check_board_write(uuid)                   from public, anon;
revoke all on function public.board_state(uuid)                         from public, anon;
revoke all on function public.board_mute(uuid, uuid)                    from public, anon;
revoke all on function public.board_unmute(uuid)                        from public, anon;
revoke all on function public.board_mutes()                             from public, anon;
revoke all on function public.board_report(uuid, text, text)            from public, anon;
revoke all on function public.board_reports_list(uuid, text, int)       from public, anon;
revoke all on function public.board_resolve(uuid, text, text)           from public, anon;
revoke all on function public.board_block(uuid, uuid, text)             from public, anon;
revoke all on function public.board_unblock(uuid, uuid)                 from public, anon;
grant execute on function public.board_muted(uuid, uuid)                to authenticated;
grant execute on function public.board_blocked(uuid)                    to authenticated;
grant execute on function public.check_board_write(uuid)                to authenticated;
grant execute on function public.board_state(uuid)                      to authenticated;
grant execute on function public.board_mute(uuid, uuid)                 to authenticated;
grant execute on function public.board_unmute(uuid)                     to authenticated;
grant execute on function public.board_mutes()                          to authenticated;
grant execute on function public.board_report(uuid, text, text)         to authenticated;
grant execute on function public.board_reports_list(uuid, text, int)    to authenticated;
grant execute on function public.board_resolve(uuid, text, text)        to authenticated;
grant execute on function public.board_block(uuid, uuid, text)          to authenticated;
grant execute on function public.board_unblock(uuid, uuid)              to authenticated;
