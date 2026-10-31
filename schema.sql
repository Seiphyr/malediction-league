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
create table if not exists profiles (
  id          uuid primary key references auth.users on delete cascade,
  display_name text not null,
  role        text not null default 'player' check (role in ('player','organizer')),
  created_at  timestamptz not null default now()
);

-- ---------- LEAGUES ----------
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

-- To be able to post to everyone, add yourself once, by hand:
--   insert into site_admins (user_id)
--   select id from profiles where display_name = 'GengisGun';

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
