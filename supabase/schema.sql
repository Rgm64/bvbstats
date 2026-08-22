-- ============================================================================
-- Beach Stat Collector — database schema
--
-- Paste this whole file into the Supabase SQL editor and run it.
-- It is safe to run more than once: everything is create-if-not-exists or
-- create-or-replace, and policies are dropped before being recreated.
--
-- Read the BOOTSTRAP section at the bottom before you finish — there is one
-- statement you must run to make yourself an administrator.
-- ============================================================================

create extension if not exists "pgcrypto";

-- ============================================================================
-- 1. ROLES
--
-- Roles live in a table rather than a hard-coded database type, so adding or
-- renaming one later is an INSERT, not a schema migration. Note the limit: a
-- genuinely new *shape* of access still needs a new policy written in SQL.
-- ============================================================================

create table if not exists roles (
  key   text primary key,
  label text not null,
  rank  int  not null default 0      -- higher = more access; for sorting UI
);

insert into roles (key, label, rank) values
  ('admin',  'Administrator', 100),
  ('coach',  'Coach',          60),
  ('stat',   'Stat-taker',     40),
  ('player', 'Player',         10)
on conflict (key) do update set label = excluded.label, rank = excluded.rank;

-- ============================================================================
-- 2. SCHOOLS AND ROSTER
-- ============================================================================

create table if not exists schools (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,          -- uppercase, e.g. 'TEXAS'
  created_at timestamptz not null default now()
);

create table if not exists players (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references schools(id) on delete cascade,
  first_name  text not null,
  last_name   text not null,
  number      text,                         -- text: numbers can have leading zeros
  alt_number  text,
  photo_url   text,                         -- unused for now; photos are deferred
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create index if not exists players_school_idx on players (school_id);

-- ============================================================================
-- 3. PROFILES — one row per login
--
-- Created automatically by a trigger when someone signs up. New users default
-- to 'player', the least-privileged role, so a stray signup can never read
-- anything. An administrator promotes them afterwards.
-- ============================================================================

create table if not exists profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  email        text,
  display_name text,
  role_key     text not null default 'player' references roles(key),
  school_id    uuid references schools(id),
  player_id    uuid references players(id),  -- links a player's login to their roster row
  created_at   timestamptz not null default now()
);

create index if not exists profiles_school_idx on profiles (school_id);

create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  insert into public.profiles (id, email, display_name)
  values (new.id, new.email, split_part(coalesce(new.email, ''), '@', 1))
  on conflict (id) do nothing;
  return new;
end;
$fn$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- Nobody may promote themselves. Without this, a user could PATCH their own
-- profile row and become an administrator, since they are allowed to edit
-- their own display name.
create or replace function guard_profile_changes()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  -- auth.uid() is null when this runs from the SQL editor rather than through
  -- the API. That path is how an administrator is first created, and it is
  -- already gated: the row-level policy denies any API caller without a uid.
  if auth.uid() is not null
     and (new.role_key is distinct from old.role_key
       or new.school_id is distinct from old.school_id
       or new.player_id is distinct from old.player_id)
     and coalesce((select role_key from public.profiles where id = auth.uid()), '') <> 'admin'
  then
    raise exception 'only an administrator can change role, school or player link';
  end if;
  return new;
end;
$fn$;

drop trigger if exists profiles_guard on profiles;
create trigger profiles_guard
  before update on profiles
  for each row execute function guard_profile_changes();

-- ============================================================================
-- 4. MATCHES — the unit that syncs between devices
--
-- payload holds the complete match record including the rally log. The log is
-- the single source of truth; every statistic is recomputed from it.
-- updated_at is epoch milliseconds supplied by the client, and drives the
-- last-write-wins merge.
-- ============================================================================

create table if not exists matches (
  id         text primary key,               -- the app's own id, so local and remote agree
  owner      uuid not null references auth.users(id) on delete cascade,
  school     text,
  school_id  uuid references schools(id),
  opponent   text,
  played_on  date,
  track_st   boolean not null default false,
  payload    jsonb not null,
  updated_at bigint not null,
  deleted    boolean not null default false, -- tombstone: a delete must not resurrect
  created_at timestamptz not null default now()
);

create index if not exists matches_owner_idx   on matches (owner);
create index if not exists matches_school_idx  on matches (school_id);
create index if not exists matches_updated_idx on matches (updated_at);

-- ============================================================================
-- 5. MATCH_STATS — the 45 spreadsheet columns, two rows per match
--
-- Derived data. The app recomputes these from the rally log and writes them on
-- every sync, so they can never drift from the log. Never edit them by hand.
--
-- Column names are snake_case here so they are pleasant to type in SQL. The
-- master_data view below exposes exactly the spreadsheet's header names.
-- ============================================================================

create table if not exists match_stats (
  match_id  text not null references matches(id) on delete cascade,
  slot      text not null check (slot in ('a','b')),
  player_id uuid references players(id),     -- set once rosters land; until then null

  -- 1-10  match metadata
  played_on            date,
  school               text,
  pair                 text,
  player               text,
  partner              text,
  opponent             text,
  opponent_pair        text,
  final_score          text,
  sets_won             int not null default 0,
  sets_lost            int not null default 0,

  -- 11-24  this player's own serve-receive counts
  points_earned        int not null default 0,
  points_given         int not null default 0,
  sr_total_attempts    int not null default 0,
  sr_0                 int not null default 0,
  sr_1                 int not null default 0,
  sr_2                 int not null default 0,
  sr_3                 int not null default 0,
  sr_bhe               int not null default 0,
  sr_a2_attempts       int not null default 0,
  sr_a2_kills          int not null default 0,
  sr_a2_errors         int not null default 0,
  sr_fb_swings         int not null default 0,
  sr_fb_kills          int not null default 0,
  sr_fb_errors         int not null default 0,

  -- 25-28  the partner's serve-receive counts
  sr_bhe_partner           int not null default 0,
  sr_a2_attempts_partner   int not null default 0,
  sr_a2_kills_partner      int not null default 0,
  sr_a2_errors_partner     int not null default 0,

  -- 29-42  this player's own serve/transition counts
  serve_attempts           int not null default 0,
  aces                     int not null default 0,
  serving_errors           int not null default 0,
  knockouts                int not null default 0,
  points_on_serve          int not null default 0,
  stuff_blocks             int not null default 0,
  tools                    int not null default 0,
  digs_to_swing            int not null default 0,   -- a subset of digs, not exclusive
  digs                     int not null default 0,   -- already the total
  transition_bhe           int not null default 0,
  transition_a2_kills      int not null default 0,
  transition_a2_errors     int not null default 0,
  transition_kills         int not null default 0,
  transition_hitting_errors int not null default 0,

  -- 43-45  the partner's serve/transition counts
  transition_bhe_partner       int not null default 0,
  transition_a2_kills_partner  int not null default 0,
  transition_a2_errors_partner int not null default 0,

  primary key (match_id, slot)
);

create index if not exists match_stats_player_idx on match_stats (player_id);
create index if not exists match_stats_school_idx on match_stats (school);

-- ============================================================================
-- 6. MASTER_DATA — the same rows under the exact spreadsheet header names
--
-- This is what you query for reports. Column names match Master_Data.xlsx
-- character for character, so you can copy a header straight from the sheet.
-- Because they contain spaces and brackets they must be double-quoted in SQL.
--
--   select "Player", sum("SR FB Kills (3rd Ball)"), sum("Total SR Attempts")
--   from master_data
--   where "School" = 'TEXAS'
--   group by "Player";
--
-- Run that in the SQL editor and use Download CSV for the file.
-- ============================================================================

create or replace view master_data with (security_invoker = true) as
select
  played_on                    as "Date",
  school                       as "School",
  pair                         as "Pair",
  player                       as "Player",
  partner                      as "Partner",
  opponent                     as "Opponent",
  opponent_pair                as "Opponent Pair",
  final_score                  as "Final Score",
  sets_won                     as "Sets Won",
  sets_lost                    as "Sets Lost",
  points_earned                as "Points Earned (+)",
  points_given                 as "Points Given (-)",
  sr_total_attempts            as "Total SR Attempts",
  sr_0                         as "0 SR Attempts",
  sr_1                         as "1 SR Attempts",
  sr_2                         as "2 SR Attempts",
  sr_3                         as "3 SR Attempts",
  sr_bhe                       as "SR BHE (2nd Ball)",
  sr_a2_attempts               as "SR A2 Attempts",
  sr_a2_kills                  as "SR A2 Kills",
  sr_a2_errors                 as "SR A2 Errors",
  sr_fb_swings                 as "SR FB Swings (3rd Ball)",
  sr_fb_kills                  as "SR FB Kills (3rd Ball)",
  sr_fb_errors                 as "SR FB Errors (3rd Ball)",
  sr_bhe_partner               as "SR BHE (2nd Ball) (Partner)",
  sr_a2_attempts_partner       as "SR A2 Attempts (Partner)",
  sr_a2_kills_partner          as "SR A2 Kills (Partner)",
  sr_a2_errors_partner         as "SR A2 Errors (Partner)",
  serve_attempts               as "Serve Attempts",
  aces                         as "Aces",
  serving_errors               as "Serving Errors",
  knockouts                    as "Knockouts",
  points_on_serve              as "Points on Serve",
  stuff_blocks                 as "Stuff Blocks",
  tools                        as "Tools",
  digs_to_swing                as "Digs -> Swing",
  digs                         as "Digs",
  transition_bhe               as "Transition BHE",
  transition_a2_kills          as "Transition A2 Kills",
  transition_a2_errors         as "Transition A2 Errors",
  transition_kills             as "Transition Kills (3rd Ball)",
  transition_hitting_errors    as "Transition Hitting Errors (3rd Ball)",
  transition_bhe_partner       as "Transition BHE (Partner)",
  transition_a2_kills_partner  as "Transition A2 Kills (Partner)",
  transition_a2_errors_partner as "Transition A2 Errors (Partner)"
from match_stats;

-- ============================================================================
-- 7. WHO AM I — helpers used by the policies
--
-- These are SECURITY DEFINER so that a policy on `profiles` can look at
-- `profiles` without recursing into its own policy. search_path is pinned,
-- which is the standard precaution for definer functions.
-- ============================================================================

create or replace function my_role() returns text
language sql stable security definer set search_path = public as $fn$
  select role_key from profiles where id = auth.uid()
$fn$;

create or replace function my_school() returns uuid
language sql stable security definer set search_path = public as $fn$
  select school_id from profiles where id = auth.uid()
$fn$;

create or replace function my_player() returns uuid
language sql stable security definer set search_path = public as $fn$
  select player_id from profiles where id = auth.uid()
$fn$;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $fn$
  select coalesce(my_role() = 'admin', false)
$fn$;

-- ============================================================================
-- 8. ROW-LEVEL SECURITY
--
--   Admin       full read and write
--   Coach       reads matches and stats for their own school; does not collect
--   Stat-taker  reads and writes the matches they own
--   Player      reads only their own rows in match_stats
--
-- These run inside the database, so they hold even if someone bypasses the app
-- and calls the API directly.
-- ============================================================================

grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on
  roles, schools, players, profiles, matches, match_stats to authenticated;
grant select on master_data to authenticated;

alter table roles       enable row level security;
alter table schools     enable row level security;
alter table players     enable row level security;
alter table profiles    enable row level security;
alter table matches     enable row level security;
alter table match_stats enable row level security;

-- ---- roles: everyone signed in may read the list; only admins change it ----
drop policy if exists roles_read  on roles;
drop policy if exists roles_write on roles;
create policy roles_read  on roles for select to authenticated using (true);
create policy roles_write on roles for all    to authenticated
  using (is_admin()) with check (is_admin());

-- ---- schools ----
drop policy if exists schools_read  on schools;
drop policy if exists schools_write on schools;
create policy schools_read  on schools for select to authenticated using (true);
create policy schools_write on schools for all    to authenticated
  using (is_admin()) with check (is_admin());

-- ---- players: rosters are readable by anyone signed in; adding a player is
--      always available to anyone who collects, per the requirement ----
drop policy if exists players_read   on players;
drop policy if exists players_add    on players;
drop policy if exists players_edit   on players;
drop policy if exists players_remove on players;
create policy players_read on players for select to authenticated using (true);
create policy players_add  on players for insert to authenticated
  with check (is_admin() or my_role() in ('coach','stat'));
create policy players_edit on players for update to authenticated
  using (is_admin() or (my_role() in ('coach','stat') and school_id = my_school()))
  with check (is_admin() or (my_role() in ('coach','stat') and school_id = my_school()));
create policy players_remove on players for delete to authenticated using (is_admin());

-- ---- profiles: your own row, plus admins, plus coaches over their school.
--      The profiles_guard trigger stops anyone editing their own role. ----
drop policy if exists profiles_read on profiles;
drop policy if exists profiles_edit on profiles;
create policy profiles_read on profiles for select to authenticated using (
  id = auth.uid()
  or is_admin()
  or (my_role() = 'coach' and school_id is not null and school_id = my_school())
);
create policy profiles_edit on profiles for update to authenticated
  using (id = auth.uid() or is_admin())
  with check (id = auth.uid() or is_admin());

-- ---- matches ----
drop policy if exists matches_read   on matches;
drop policy if exists matches_add    on matches;
drop policy if exists matches_edit   on matches;
drop policy if exists matches_remove on matches;
create policy matches_read on matches for select to authenticated using (
  is_admin()
  or owner = auth.uid()
  or (my_role() = 'coach' and school_id is not null and school_id = my_school())
);
create policy matches_add on matches for insert to authenticated
  with check (owner = auth.uid() and (is_admin() or my_role() = 'stat'));
create policy matches_edit on matches for update to authenticated
  using (is_admin() or owner = auth.uid())
  with check (is_admin() or owner = auth.uid());
create policy matches_remove on matches for delete to authenticated using (is_admin());

-- ---- match_stats: derived rows. A player sees only their own.
--      player_id is null until rosters land, so the player rule matches
--      nothing until then — it fails closed, which is the safe direction. ----
drop policy if exists match_stats_read  on match_stats;
drop policy if exists match_stats_write on match_stats;
create policy match_stats_read on match_stats for select to authenticated using (
  is_admin()
  or exists (select 1 from matches m where m.id = match_stats.match_id and m.owner = auth.uid())
  or (my_role() = 'coach' and exists (
        select 1 from matches m
        where m.id = match_stats.match_id
          and m.school_id is not null
          and m.school_id = my_school()))
  or (my_role() = 'player' and player_id is not null and player_id = my_player())
);
-- Only whoever owns the match may write its derived stats.
create policy match_stats_write on match_stats for all to authenticated
  using (is_admin() or exists (
    select 1 from matches m where m.id = match_stats.match_id and m.owner = auth.uid()))
  with check (is_admin() or exists (
    select 1 from matches m where m.id = match_stats.match_id and m.owner = auth.uid()));

-- ============================================================================
-- 9. BOOTSTRAP — run this after your first sign-in
--
-- Signing up creates your profile as a 'player', which can see nothing. Sign in
-- to the app once so the row exists, then run the two statements below with
-- your own email to make yourself an administrator and attach you to Texas.
--
--   insert into schools (name) values ('TEXAS') on conflict (name) do nothing;
--
--   update profiles
--      set role_key  = 'admin',
--          school_id = (select id from schools where name = 'TEXAS')
--    where email = 'you@example.com';
--
-- Check it worked:
--
--   select email, role_key from profiles;
-- ============================================================================
