-- FINAL ACTIVATION FOR THE 2026 GUILLOTINE LEAGUE
-- Run after schema.sql, complete.sql, weekly.sql, and automatic_weekly.sql.
-- This file is the single final activation for the two functions that were
-- added after the original database setup: draft reset and hardened FAAB.

-- ================================================================
-- DRAFT RESET
-- ================================================================
create or replace function public.reset_draft(p_league_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_commissioner uuid;
begin
  if v_user is null then raise exception 'Authentication required.'; end if;
  select commissioner_user_id into v_commissioner from public.leagues where id=p_league_id;
  if v_commissioner is null then raise exception 'League not found.'; end if;
  if v_commissioner <> v_user then raise exception 'Commissioner access required.'; end if;

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
$$;
revoke all on function public.reset_draft(uuid) from public;
grant execute on function public.reset_draft(uuid) to authenticated;

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
as $$
declare v_bid public.waiver_bids; v_faab int;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if not exists(select 1 from public.teams where id=p_team_id and league_id=p_league_id and owner_user_id=auth.uid() and alive)
     and not public.is_commissioner(p_league_id) then raise exception 'You do not control this team.'; end if;
  select faab into v_faab from public.teams where id=p_team_id and league_id=p_league_id;
  if not found then raise exception 'Team not found.'; end if;
  if not exists(select 1 from public.waiver_pool where league_id=p_league_id and sleeper_id=p_sleeper_id) then raise exception 'Player is not in the waiver pool.'; end if;
  if p_bid_amount < 0 or p_bid_amount > v_faab then raise exception 'Bid must be between $0 and your available FAAB.'; end if;
  if p_week not between 1 and 17 then raise exception 'Invalid week.'; end if;

  delete from public.waiver_bids
  where league_id=p_league_id and team_id=p_team_id and sleeper_id=p_sleeper_id
    and week=p_week and processed_at is null;

  insert into public.waiver_bids(league_id,team_id,sleeper_id,bid_amount,priority,week)
  values(p_league_id,p_team_id,p_sleeper_id,p_bid_amount,greatest(1,p_priority),p_week)
  returning * into v_bid;
  return v_bid;
end;
$$;
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
as $$
declare v_player record; v_bid record; v_faab int; v_count int:=0;
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
    v_bid:=null;
    select b.* into v_bid
    from public.waiver_bids b
    join public.teams t on t.id=b.team_id
    where b.league_id=p_league_id and b.week=p_week and b.sleeper_id=v_player.sleeper_id
      and b.processed_at is null and t.league_id=p_league_id and t.alive and b.bid_amount<=t.faab
    order by b.bid_amount desc,b.priority asc,b.submitted_at asc,b.id asc limit 1;

    if v_bid.id is null then
      update public.waiver_bids set processed_at=now()
      where league_id=p_league_id and week=p_week and sleeper_id=v_player.sleeper_id and processed_at is null;
      continue;
    end if;

    select faab into v_faab from public.teams where id=v_bid.team_id for update;
    if v_bid.bid_amount>v_faab then continue; end if;

    delete from public.roster_players where league_id=p_league_id and sleeper_id=v_player.sleeper_id;
    insert into public.roster_players(league_id,team_id,sleeper_id,acquired_week,acquired_via,roster_slot)
    values(p_league_id,v_bid.team_id,v_player.sleeper_id,p_week,'waiver','BENCH');
    update public.teams set faab=faab-v_bid.bid_amount where id=v_bid.team_id;
    delete from public.waiver_pool where league_id=p_league_id and sleeper_id=v_player.sleeper_id;
    update public.waiver_bids set processed_at=now()
    where league_id=p_league_id and week=p_week and sleeper_id=v_player.sleeper_id and processed_at is null;

    insert into public.audit_log(league_id,actor_user_id,action,details)
    values(p_league_id,auth.uid(),'waiver_awarded',jsonb_build_object(
      'team_id',v_bid.team_id,'sleeper_id',v_player.sleeper_id,'bid',v_bid.bid_amount,
      'priority',v_bid.priority,'week',p_week));
    v_count:=v_count+1;
  end loop;
  return v_count;
end;
$$;
revoke all on function public.process_waivers(uuid,int) from public;
grant execute on function public.process_waivers(uuid,int) to authenticated;

-- ================================================================
-- FINAL REALTIME SAFETY NET
-- ================================================================
do $$
declare t text;
begin
  foreach t in array array['leagues','teams','roster_players','draft_picks','weekly_scores','waiver_pool','waiver_bids','eliminations','lineups'] loop
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then
      execute format('alter publication supabase_realtime add table public.%I',t);
    end if;
  end loop;
end $$;

-- Verify the three critical functions exist.
do $$
begin
  if not exists(select 1 from pg_proc where pronamespace='public'::regnamespace and proname='reset_draft') then raise exception 'reset_draft was not created'; end if;
  if not exists(select 1 from pg_proc where pronamespace='public'::regnamespace and proname='submit_waiver_bid') then raise exception 'submit_waiver_bid was not created'; end if;
  if not exists(select 1 from pg_proc where pronamespace='public'::regnamespace and proname='process_waivers') then raise exception 'process_waivers was not created'; end if;
end $$;
