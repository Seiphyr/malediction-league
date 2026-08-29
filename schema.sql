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
  next_event_bonus smallint not null default 0
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
  winner_decklist text,         -- optional decklist link or text
  loser_decklist  text,
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
  cards      jsonb,                       -- { "Card name": copies }
  side       jsonb,
  tag        text check (tag is null or tag in ('competitive','test','fun')),
  is_public  boolean not null default false,
  created_at timestamptz not null default now()
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
alter table memberships add column if not exists dropped_at timestamptz;
alter table sessions    add column if not exists event_url text;
alter table sessions    add column if not exists is_tournament boolean not null default false;
alter table matches     add column if not exists winner_terrain text;
alter table matches     add column if not exists loser_terrain text;
alter table matches     add column if not exists winner_decklist text;
alter table matches     add column if not exists loser_decklist text;

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

-- Only organizers can create leagues, and only as themselves.
drop policy if exists "organizers create leagues" on leagues;
create policy "organizers create leagues" on leagues
  for insert with check (
    owner_id = auth.uid()
    and exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'organizer')
  );

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

-- A player joins themselves (via join code, verified client-side by lookup).
drop policy if exists "self join" on memberships;
create policy "self join" on memberships
  for insert with check (user_id = auth.uid() or is_league_admin(league_id));

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
create or replace view public_leagues
with (security_invoker = on) as
select
  l.id, l.name, l.location, l.city, l.country, l.description, l.created_at,
  (select count(*) from memberships m where m.league_id = l.id) as member_count,
  (select count(*) from sessions s where s.league_id = l.id)    as session_count,
  (select max(s.date) from sessions s where s.league_id = l.id) as last_session
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
