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
