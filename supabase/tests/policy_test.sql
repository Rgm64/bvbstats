-- ============================================================================
-- Policy tests — proves the row-level security rules actually hold.
--
-- Run against a THROWAWAY database only. It wipes every table before seeding.
-- The guard below refuses to run if it finds real data, but do not rely on
-- that alone: never point this at the live project.
--
--   psql -v ON_ERROR_STOP=1 -f policy_test.sql
--
-- Silence means every assertion passed; a failure raises and stops.
-- ============================================================================

do $$ begin
  if (select count(*) from matches) > 0 or (select count(*) from players) > 0 then
    raise exception 'refusing to run: this test wipes data and the database is not empty';
  end if;
end $$;

delete from match_stats; delete from matches; delete from profiles;
delete from players; delete from schools; delete from auth.users;

insert into schools (id, name) values
  ('11111111-0000-0000-0000-000000000001','TEXAS'),
  ('11111111-0000-0000-0000-000000000002','UCLA');

insert into players (id, school_id, first_name, last_name, number) values
  ('22222222-0000-0000-0000-000000000008','11111111-0000-0000-0000-000000000001','Ava','Belardi','8'),
  ('22222222-0000-0000-0000-000000000088','11111111-0000-0000-0000-000000000001','Mia','Jackson','88'),
  ('22222222-0000-0000-0000-000000000018','11111111-0000-0000-0000-000000000002','Rae','Ortiz','18');

-- Signing up fires handle_new_user(), creating each profile as 'player'.
insert into auth.users (id, email) values
  ('33333333-0000-0000-0000-00000000000a','admin@tex'),
  ('33333333-0000-0000-0000-00000000000b','coach@tex'),
  ('33333333-0000-0000-0000-00000000000c','coach@ucla'),
  ('33333333-0000-0000-0000-00000000000d','stat@tex'),
  ('33333333-0000-0000-0000-00000000000e','p8@tex');

do $$ begin
  if (select count(*) from profiles) <> 5 then
    raise exception 'signup trigger did not create a profile per user';
  end if;
  if (select count(*) from profiles where role_key <> 'player') > 0 then
    raise exception 'new users must default to the least-privileged role';
  end if;
end $$;

-- The BOOTSTRAP path from schema.sql section 9: promotion from the SQL editor,
-- where there is no auth.uid(). If the guard trigger blocks this, the project
-- owner can never make themselves an administrator.
update profiles set role_key='admin', school_id='11111111-0000-0000-0000-000000000001' where email='admin@tex';
update profiles set role_key='coach', school_id='11111111-0000-0000-0000-000000000001' where email='coach@tex';
update profiles set role_key='coach', school_id='11111111-0000-0000-0000-000000000002' where email='coach@ucla';
update profiles set role_key='stat',  school_id='11111111-0000-0000-0000-000000000001' where email='stat@tex';
update profiles set role_key='player',school_id='11111111-0000-0000-0000-000000000001',
       player_id='22222222-0000-0000-0000-000000000008' where email='p8@tex';

insert into matches (id, owner, school, school_id, opponent, played_on, track_st, payload, updated_at) values
  ('m1','33333333-0000-0000-0000-00000000000d','TEXAS','11111111-0000-0000-0000-000000000001','UCLA','2026-04-01',true,'{}'::jsonb,1),
  ('m2','33333333-0000-0000-0000-00000000000a','UCLA','11111111-0000-0000-0000-000000000002','ASU','2026-04-02',true,'{}'::jsonb,2);

insert into match_stats (match_id, slot, player_id, school, player) values
  ('m1','a','22222222-0000-0000-0000-000000000008','TEXAS','#8'),
  ('m1','b','22222222-0000-0000-0000-000000000088','TEXAS','#88'),
  ('m2','a',null,'UCLA','#18'),
  ('m2','b',null,'UCLA','#21');

-- ---------------------------------------------------------------- reads ----
create or replace function assert_visible(who uuid, label text, rel text, want int)
returns void language plpgsql as $fn$
declare got int;
begin
  perform set_config('request.jwt.claim.sub', who::text, true);
  execute format('select count(*) from %s', rel) into got;
  if got <> want then
    raise exception '% : expected % row(s) of %, got %', label, want, rel, got;
  end if;
end;
$fn$;

create or replace function assert_blocked(who uuid, label text, stmt text)
returns void language plpgsql as $fn$
begin
  perform set_config('request.jwt.claim.sub', who::text, true);
  begin
    execute stmt;
    raise exception '% : should have been blocked but succeeded', label;
  exception
    when insufficient_privilege or check_violation then return;
    when others then
      if sqlerrm like '%should have been blocked%' then raise; end if;
      return;                       -- any other rejection is still a rejection
  end;
end;
$fn$;

begin;
  set local role authenticated;
  do $t$
  begin
    perform assert_visible('33333333-0000-0000-0000-00000000000a','admin','matches',2);
    perform assert_visible('33333333-0000-0000-0000-00000000000a','admin','match_stats',4);
    perform assert_visible('33333333-0000-0000-0000-00000000000b','coach TEXAS','matches',1);
    perform assert_visible('33333333-0000-0000-0000-00000000000b','coach TEXAS','match_stats',2);
    perform assert_visible('33333333-0000-0000-0000-00000000000c','coach UCLA','matches',1);
    perform assert_visible('33333333-0000-0000-0000-00000000000c','coach UCLA','match_stats',2);
    perform assert_visible('33333333-0000-0000-0000-00000000000d','stat-taker','matches',1);
    perform assert_visible('33333333-0000-0000-0000-00000000000d','stat-taker','match_stats',2);
    perform assert_visible('33333333-0000-0000-0000-00000000000e','player','matches',0);
    perform assert_visible('33333333-0000-0000-0000-00000000000e','player','match_stats',1);
    -- The view must not become a side door. Postgres runs views with the
    -- owner's rights unless security_invoker is set, which would expose every
    -- player's stats here.
    perform assert_visible('33333333-0000-0000-0000-00000000000e','player via master_data','master_data',1);
    perform assert_visible('33333333-0000-0000-0000-00000000000e','player','profiles',1);
  end $t$;
rollback;

-- --------------------------------------------------------------- writes ----
begin;
  set local role authenticated;
  do $t$
  begin
    perform assert_blocked('33333333-0000-0000-0000-00000000000e','player creating a match',
      $q$insert into matches (id,owner,payload,updated_at)
         values ('hack','33333333-0000-0000-0000-00000000000e','{}'::jsonb,9)$q$);
    perform assert_blocked('33333333-0000-0000-0000-00000000000b','coach creating a match',
      $q$insert into matches (id,owner,payload,updated_at)
         values ('coachmatch','33333333-0000-0000-0000-00000000000b','{}'::jsonb,9)$q$);
    perform assert_blocked('33333333-0000-0000-0000-00000000000d','stat-taker spoofing an owner',
      $q$insert into matches (id,owner,payload,updated_at)
         values ('spoof','33333333-0000-0000-0000-00000000000a','{}'::jsonb,9)$q$);
  end $t$;
rollback;

-- A player must not be able to promote themselves by editing their own row.
begin;
  set local role authenticated;
  do $t$
  begin
    perform set_config('request.jwt.claim.sub','33333333-0000-0000-0000-00000000000e',true);
    begin
      update profiles set role_key='admin' where id='33333333-0000-0000-0000-00000000000e';
    exception when others then null;             -- the guard trigger fired
    end;
    if (select role_key from profiles where id='33333333-0000-0000-0000-00000000000e') = 'admin' then
      raise exception 'player promoted themselves to admin';
    end if;
  end $t$;
rollback;

-- A stat-taker must still be able to create their own match.
begin;
  set local role authenticated;
  do $t$
  begin
    perform set_config('request.jwt.claim.sub','33333333-0000-0000-0000-00000000000d',true);
    insert into matches (id,owner,payload,updated_at)
      values ('mine','33333333-0000-0000-0000-00000000000d','{}'::jsonb,9);
    if not exists (select 1 from matches where id='mine') then
      raise exception 'a stat-taker could not create their own match';
    end if;
  end $t$;
rollback;

drop function assert_visible(uuid,text,text,int);
drop function assert_blocked(uuid,text,text);
