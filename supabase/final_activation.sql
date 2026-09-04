-- FINAL ACTIVATION FOR THE 2026 GUILLOTINE LEAGUE
-- Run after schema.sql, complete.sql, weekly.sql, and automatic_weekly.sql.
-- This file activates draft reset, hardened FAAB processing, and automatic
-- population of all undrafted players into the initial waiver pool.

-- ================================================================
-- DRAFT RESET
-- ================================================================
create or replace function public.reset_draft(p_league_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $reset_draft$
declare
  v_user uuid := auth.uid();
  v_commissioner uuid;
begin
  if v_user is null then raise exception 'Authentication required.'; end if;
  select commissioner_user_id into v_commissioner from public.leagues where id=p_league_id;
  if v_commissioner is null then raise exception 'League not found.'; end if;
  if v_commissioner <> v_user then raise exception 'Commissioner access required.'; end if;

  -- A draft reset must remove all draft-era waiver state as well as rosters.
  delete from public.waiver_bids where league_id=p_league_id;
  delete from public.waiver_pool where league_id=p_league_id;
  delete from public.lineups where league_id=p_league_id;
  delete from public.roster_players where league_id=p_league_id;
  delete from public.draft_picks where league_id=p_league_id;
  delete from public.draft_skips where league_id=p_league_id;

  update public.draft_state
  set status='setup',started_at=null,paused_at=null,pick_started_at=null,
      remaining_seconds=pick_seconds,timeout_pending=false,updated_at=now()
  where league_id=p_league_id;

  insert into public.draft_state(league_id,status,rounds,pick_seconds,remaining_seconds,timeout_pending,updated_at)
  select p_league_id,'setup',13,90,90,false,now()
  where not exists(select 1 from public.draft_state where league_id=p_league_id);

  insert into public.audit_log(league_id,actor_user_id,action,details)
  values(p_league_id,v_user,'draft_reset',jsonb_build_object('message','Commissioner reset the draft to setup'));
end;
$reset_draft$;
revoke all on function public.reset_draft(uuid) from public;
grant execute on function public.reset_draft(uuid) to authenticated;

-- ================================================================
-- INITIAL WAIVER POOL
-- ================================================================
-- Every player not selected by this league's draft becomes available for
-- the first blind-FAAB waiver period. This is intentionally league-scoped:
-- a player drafted by another league is still available here unless this
-- league itself owns that player.
create or replace function public.populate_initial_waiver_pool(p_league_id uuid)
returns int
language plpgsql
security definer
set search_path = public
as $initial_waivers$
declare
  v_user uuid := auth.uid();
  v_count int := 0;
  v_commissioner uuid;
begin
  if v_user is null then raise exception 'Authentication required.'; end if;

  select commissioner_user_id
    into v_commissioner
  from public.leagues
  where id=p_league_id;

  if v_commissioner is null then raise exception 'League not found.'; end if;
  if v_commissioner <> v_user then raise exception 'Commissioner access required.'; end if;

  insert into public.waiver_pool(league_id,sleeper_id,source_team_id,released_week)
  select p_league_id,p.sleeper_id,null,1
  from public.players p
  where not exists (
    select 1
    from public.roster_players rp
    where rp.league_id=p_league_id
      and rp.sleeper_id=p.sleeper_id
  )
  on conflict (league_id,sleeper_id) do nothing;

  get diagnostics v_count = row_count;
  return v_count;
end;
$initial_waivers$;
revoke all on function public.populate_initial_waiver_pool(uuid) from public;
grant execute on function public.populate_initial_waiver_pool(uuid) to authenticated;

-- Seed the waiver pool whenever a draft transitions to complete. Using a
-- trigger makes this independent of whether completion happens through the
-- normal draft RPC, the final manual pick, or the automatic timeout picker.
create or replace function public.seed_initial_waivers_on_draft_complete()
returns trigger
language plpgsql
security definer
set search_path = public
as $seed_initial$
begin
  if new.status='complete' and old.status is distinct from 'complete' then
    perform public.populate_initial_waiver_pool(new.league_id);
  end if;
  return new;
end;
$seed_initial$;
revoke all on function public.seed_initial_waivers_on_draft_complete() from public;
grant execute on function public.seed_initial_waivers_on_draft_complete() to authenticated;

drop trigger if exists seed_initial_waivers_after_draft_complete on public.draft_state;
create trigger seed_initial_waivers_after_draft_complete
after update of status on public.draft_state
for each row
when (new.status='complete')
execute function public.seed_initial_waivers_on_draft_complete();

-- Backfill the pool for any league whose draft is already complete when this
-- activation script is run. Safe to run repeatedly because the pool has a
-- league/player uniqueness constraint and the function uses ON CONFLICT DO NOTHING.
do $waiver_backfill$
declare
  v_league record;
begin
  for v_league in
    select ds.league_id
    from public.draft_state ds
    where ds.status='complete'
  loop
    insert into public.waiver_pool(league_id,sleeper_id,source_team_id,released_week)
    select v_league.league_id,p.sleeper_id,null,1
    from public.players p
    where not exists (
      select 1
      from public.roster_players rp
      where rp.league_id=v_league.league_id
        and rp.sleeper_id=p.sleeper_id
    )
    on conflict (league_id,sleeper_id) do nothing;
  end loop;
end;
$waiver_backfill$;

-- ================================================================
-- PRIVATE / DETERMINISTIC FAAB BIDS
-- ================================================================
create or replace function public.submit_waiver_bid(
  p_league_id uuid,p_team_id uuid,p_sleeper_id text,
  p_bid_amount int,p_priority int,p_week int
)
returns public.waiver_bids
language plpgsql
security definer
set search_path=public
as $submit_bid$
declare
  v_bid public.waiver_bids;
  v_faab int;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if not exists(
    select 1 from public.teams
    where id=p_team_id and league_id=p_league_id and owner_user_id=auth.uid() and alive
  ) and not public.is_commissioner(p_league_id) then
    raise exception 'You do not control this team.';
  end if;

  select faab into v_faab from public.teams where id=p_team_id and league_id=p_league_id;
  if not found then raise exception 'Team not found.'; end if;
  if not exists(select 1 from public.waiver_pool where league_id=p_league_id and sleeper_id=p_sleeper_id) then
    raise exception 'Player is not in the waiver pool.';
  end if;
  if p_bid_amount < 0 or p_bid_amount > v_faab then
    raise exception 'Bid must be between $0 and your available FAAB.';
  end if;
  if p_week not between 1 and 17 then raise exception 'Invalid week.'; end if;

  delete from public.waiver_bids
  where league_id=p_league_id and team_id=p_team_id and sleeper_id=p_sleeper_id
    and week=p_week and processed_at is null;

  insert into public.waiver_bids(league_id,team_id,sleeper_id,bid_amount,priority,week)
  values(p_league_id,p_team_id,p_sleeper_id,p_bid_amount,greatest(1,p_priority),p_week)
  returning * into v_bid;
  return v_bid;
end;
$submit_bid$;
revoke all on function public.submit_waiver_bid(uuid,uuid,text,int,int,int) from public;
grant execute on function public.submit_waiver_bid(uuid,uuid,text,int,int,int) to authenticated;

-- ================================================================
-- COMMISSIONER FAAB PROCESSOR
-- ================================================================
create or replace function public.process_waivers(p_league_id uuid,p_week int)
returns int
language plpgsql
security definer
set search_path=public
as $process_waivers$
declare
  v_player record;
  v_bid record;
  v_faab int;
  v_count int := 0;
begin
  if not public.is_commissioner(p_league_id) then raise exception 'Commissioner access required.'; end if;
  if p_week not between 1 and 17 then raise exception 'Invalid week.'; end if;

  for v_player in
    select wb.sleeper_id,max(wb.bid_amount) top_bid
    from public.waiver_bids wb
    where wb.league_id=p_league_id and wb.week=p_week and wb.processed_at is null
    group by wb.sleeper_id
    order by max(wb.bid_amount) desc,wb.sleeper_id asc
  loop
    select b.* into v_bid
    from public.waiver_bids b
    join public.teams t on t.id=b.team_id
    where b.league_id=p_league_id and b.week=p_week and b.sleeper_id=v_player.sleeper_id
      and b.processed_at is null and t.league_id=p_league_id and t.alive and b.bid_amount<=t.faab
    order by b.bid_amount desc,b.priority asc,b.submitted_at asc,b.id asc
    limit 1;

    if not found then
      update public.waiver_bids set processed_at=now()
      where league_id=p_league_id and week=p_week and sleeper_id=v_player.sleeper_id and processed_at is null;
      continue;
    end if;

    select faab into v_faab from public.teams where id=v_bid.team_id for update;
    if v_bid.bid_amount>v_faab then continue; end if;

    delete from public.roster_players
    where league_id=p_league_id and sleeper_id=v_player.sleeper_id;

    insert into public.roster_players(league_id,team_id,sleeper_id,acquired_week,acquired_via,roster_slot)
    values(p_league_id,v_bid.team_id,v_player.sleeper_id,p_week,'waiver','BENCH');

    update public.teams set faab=faab-v_bid.bid_amount where id=v_bid.team_id;
    delete from public.waiver_pool where league_id=p_league_id and sleeper_id=v_player.sleeper_id;
    update public.waiver_bids set processed_at=now()
    where league_id=p_league_id and week=p_week and sleeper_id=v_player.sleeper_id and processed_at is null;

    insert into public.audit_log(league_id,actor_user_id,action,details)
    values(p_league_id,auth.uid(),'waiver_awarded',jsonb_build_object(
      'team_id',v_bid.team_id,
      'sleeper_id',v_player.sleeper_id,
      'bid',v_bid.bid_amount,
      'priority',v_bid.priority,
      'week',p_week
    ));
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$process_waivers$;
revoke all on function public.process_waivers(uuid,int) from public;
grant execute on function public.process_waivers(uuid,int) to authenticated;

-- ================================================================
-- FINAL REALTIME SAFETY NET
-- ================================================================
-- Idempotent: only add a table if it is not already in the publication.
do $realtime$
declare
  t text;
begin
  foreach t in array array[
    'leagues','teams','roster_players','draft_picks','weekly_scores',
    'waiver_pool','waiver_bids','eliminations','lineups'
  ] loop
    if not exists(
      select 1
      from pg_publication_tables
      where pubname='supabase_realtime'
        and schemaname='public'
        and tablename=t
    ) then
      execute format('alter publication supabase_realtime add table public.%I',t);
    end if;
  end loop;
end;
$realtime$;

-- Verify the critical activation functions exist.
do $verify$
begin
  if not exists(select 1 from pg_proc where pronamespace='public'::regnamespace and proname='reset_draft') then
    raise exception 'reset_draft was not created';
  end if;
  if not exists(select 1 from pg_proc where pronamespace='public'::regnamespace and proname='populate_initial_waiver_pool') then
    raise exception 'populate_initial_waiver_pool was not created';
  end if;
  if not exists(select 1 from pg_proc where pronamespace='public'::regnamespace and proname='seed_initial_waivers_on_draft_complete') then
    raise exception 'seed_initial_waivers_on_draft_complete was not created';
  end if;
  if not exists(select 1 from pg_proc where pronamespace='public'::regnamespace and proname='submit_waiver_bid') then
    raise exception 'submit_waiver_bid was not created';
  end if;
  if not exists(select 1 from pg_proc where pronamespace='public'::regnamespace and proname='process_waivers') then
    raise exception 'process_waivers was not created';
  end if;
end;
$verify$;
