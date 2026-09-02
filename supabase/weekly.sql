-- Guillotine League Manager: weekly scoring, elimination, lineups, and FAAB waivers
-- Run this once in Supabase SQL Editor after install.sql and draft.sql.

create or replace function public.set_lineup(
  p_league_id uuid,
  p_team_id uuid,
  p_week int,
  p_slots jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_user uuid := auth.uid();
  v_slot jsonb;
  v_player text;
  v_slot_name text;
  v_required jsonb;
  v_count int;
  v_roster_count int;
begin
  if v_user is null then raise exception 'You must be signed in.'; end if;
  if not (exists(select 1 from public.teams where id=p_team_id and league_id=p_league_id and (owner_user_id=v_user or public.is_commissioner(p_league_id)))) then
    raise exception 'You do not control this team.';
  end if;
  if p_week not between 1 and 17 then raise exception 'Week must be between 1 and 17.'; end if;
  if jsonb_typeof(p_slots) <> 'array' then raise exception 'Lineup must be a JSON array.'; end if;

  v_required := case
    when p_week between 1 and 6 then '["QB","RB","WR1","WR2","TE","FLEX","K","DEF"]'::jsonb
    when p_week between 7 and 12 then '["QB","RB1","RB2","WR1","WR2","WR3","TE","FLEX","K","DEF"]'::jsonb
    else '["QB1","QB2","RB1","RB2","WR1","WR2","WR3","TE","FLEX1","FLEX2","K","DEF"]'::jsonb
  end;

  delete from public.lineups where league_id=p_league_id and team_id=p_team_id and week=p_week and not locked;

  for v_slot in select * from jsonb_array_elements(p_slots) loop
    v_slot_name := trim(v_slot->>'slot');
    v_player := nullif(trim(v_slot->>'sleeper_id'),'');
    if v_slot_name is null or v_player is null then continue; end if;
    if not (v_required ? v_slot_name) then raise exception 'Invalid lineup slot: %',v_slot_name; end if;
    if not exists(select 1 from public.roster_players where league_id=p_league_id and team_id=p_team_id and sleeper_id=v_player) then
      raise exception 'Player is not on your roster: %',v_player;
    end if;
    if exists(select 1 from public.lineups where league_id=p_league_id and team_id=p_team_id and week=p_week and sleeper_id=v_player and slot<>v_slot_name) then
      raise exception 'A player cannot occupy multiple lineup slots.';
    end if;
    insert into public.lineups(league_id,team_id,week,sleeper_id,slot,locked)
    values(p_league_id,p_team_id,p_week,v_player,v_slot_name,false)
    on conflict(league_id,team_id,week,slot) do update set sleeper_id=excluded.sleeper_id,locked=false;
  end loop;

  select count(*) into v_count from public.lineups where league_id=p_league_id and team_id=p_team_id and week=p_week and sleeper_id is not null;
  select count(*) into v_roster_count from jsonb_array_elements(p_slots);
  if v_count <> jsonb_array_length(v_required) then
    raise exception 'Starting lineup is incomplete. % starters are required for Week %.',jsonb_array_length(v_required),p_week;
  end if;
  return jsonb_build_object('success',true,'week',p_week,'starters',v_count);
end;
$$;
revoke all on function public.set_lineup(uuid,uuid,int,jsonb) from public;
grant execute on function public.set_lineup(uuid,uuid,int,jsonb) to authenticated;

create or replace function public.calculate_week_scores(p_league_id uuid, p_week int)
returns int
language plpgsql
security definer
set search_path=public
as $$
declare
  v_team record;
  v_line record;
  v_stats jsonb;
  v_points numeric;
  v_total numeric;
  v_count int := 0;
  v_s numeric;
  v_score numeric;
begin
  if not public.is_commissioner(p_league_id) then raise exception 'Commissioner access required.'; end if;
  if p_week not between 1 and 17 then raise exception 'Week must be between 1 and 17.'; end if;

  for v_team in select id from public.teams where league_id=p_league_id and alive loop
    v_total := 0;
    for v_line in select l.sleeper_id from public.lineups l where l.league_id=p_league_id and l.team_id=v_team.id and l.week=p_week loop
      select stats into v_stats from public.nfl_stats where sleeper_id=v_line.sleeper_id and season=(select season from public.leagues where id=p_league_id) and week=p_week;
      if v_stats is null then continue; end if;
      v_total := v_total +
        coalesce((v_stats->>'pass_yd')::numeric,0)*0.04 +
        coalesce((v_stats->>'pass_td')::numeric,0)*4 +
        coalesce((v_stats->>'pass_int')::numeric,coalesce((v_stats->>'int')::numeric,0))*(-2) +
        coalesce((v_stats->>'rush_yd')::numeric,0)*0.1 +
        coalesce((v_stats->>'rush_td')::numeric,0)*6 +
        coalesce((v_stats->>'rec')::numeric,0)*0.5 +
        coalesce((v_stats->>'rec_yd')::numeric,0)*0.1 +
        coalesce((v_stats->>'rec_td')::numeric,0)*6 +
        coalesce((v_stats->>'fum_lost')::numeric,coalesce((v_stats->>'fumble')::numeric,0))*(-2);
    end loop;
    insert into public.weekly_scores(league_id,team_id,week,points,locked,calculated_at)
    values(p_league_id,v_team.id,p_week,round(v_total,2),true,now())
    on conflict(league_id,team_id,week) do update set points=excluded.points,locked=true,calculated_at=now();
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;
revoke all on function public.calculate_week_scores(uuid,int) from public;
grant execute on function public.calculate_week_scores(uuid,int) to authenticated;

create or replace function public.eliminate_lowest_team(p_league_id uuid, p_week int)
returns public.eliminations
language plpgsql
security definer
set search_path=public
as $$
declare
  v_team public.teams;
  v_elim public.eliminations;
  v_score numeric;
  v_cum numeric;
begin
  if not public.is_commissioner(p_league_id) then raise exception 'Commissioner access required.'; end if;
  if p_week not between 1 and 17 then raise exception 'Week must be between 1 and 17.'; end if;
  if exists(select 1 from public.eliminations where league_id=p_league_id and week=p_week) then raise exception 'Week % has already been processed.',p_week; end if;
  if (select count(*) from public.teams where league_id=p_league_id and alive) <= 1 then raise exception 'Only one team remains.'; end if;

  select t.* into v_team
  from public.teams t
  join public.weekly_scores s on s.team_id=t.id and s.league_id=t.league_id and s.week=p_week
  where t.league_id=p_league_id and t.alive
  order by s.points asc, (select coalesce(sum(ws.points),0) from public.weekly_scores ws where ws.league_id=p_league_id and ws.team_id=t.id and ws.week<=p_week) asc, t.team_number asc
  limit 1 for update;
  if v_team.id is null then raise exception 'No weekly scores found for Week %.',p_week; end if;
  select points into v_score from public.weekly_scores where league_id=p_league_id and team_id=v_team.id and week=p_week;
  select coalesce(sum(points),0) into v_cum from public.weekly_scores where league_id=p_league_id and team_id=v_team.id and week<=p_week;

  insert into public.waiver_pool(league_id,sleeper_id,source_team_id,released_week)
    select league_id,sleeper_id,v_team.id,p_week from public.roster_players where league_id=p_league_id and team_id=v_team.id
    on conflict(league_id,sleeper_id) do update set source_team_id=excluded.source_team_id,released_week=excluded.released_week;
  delete from public.roster_players where league_id=p_league_id and team_id=v_team.id;
  update public.teams set alive=false,elimination_week=p_week where id=v_team.id;
  insert into public.eliminations(league_id,team_id,week,score,tiebreak_points) values(p_league_id,v_team.id,p_week,v_score,v_cum) returning * into v_elim;
  insert into public.audit_log(league_id,actor_user_id,action,details) values(p_league_id,auth.uid(),'team_eliminated',jsonb_build_object('team_id',v_team.id,'week',p_week,'score',v_score));
  return v_elim;
end;
$$;
revoke all on function public.eliminate_lowest_team(uuid,int) from public;
grant execute on function public.eliminate_lowest_team(uuid,int) to authenticated;

create or replace function public.submit_waiver_bid(p_league_id uuid,p_team_id uuid,p_sleeper_id text,p_bid_amount int,p_priority int,p_week int)
returns public.waiver_bids
language plpgsql
security definer
set search_path=public
as $$
declare v_bid public.waiver_bids; v_faab int;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if not exists(select 1 from public.teams where id=p_team_id and league_id=p_league_id and owner_user_id=auth.uid() and alive) and not public.is_commissioner(p_league_id) then raise exception 'You do not control this team.'; end if;
  select faab into v_faab from public.teams where id=p_team_id and league_id=p_league_id;
  if not exists(select 1 from public.waiver_pool where league_id=p_league_id and sleeper_id=p_sleeper_id) then raise exception 'Player is not in the waiver pool.'; end if;
  if p_bid_amount<0 or p_bid_amount>v_faab then raise exception 'Bid must be between $0 and your available FAAB.'; end if;
  if p_week not between 1 and 17 then raise exception 'Invalid week.'; end if;
  insert into public.waiver_bids(league_id,team_id,sleeper_id,bid_amount,priority,week)
  values(p_league_id,p_team_id,p_sleeper_id,p_bid_amount,greatest(1,p_priority),p_week) returning * into v_bid;
  return v_bid;
end;
$$;
revoke all on function public.submit_waiver_bid(uuid,uuid,text,int,int,int) from public;
grant execute on function public.submit_waiver_bid(uuid,uuid,text,int,int,int) to authenticated;

create or replace function public.process_waivers(p_league_id uuid,p_week int)
returns int
language plpgsql
security definer
set search_path=public
as $$
declare
  v_player record;
  v_bid record;
  v_count int := 0;
  v_faab int;
  v_slot text;
begin
  if not public.is_commissioner(p_league_id) then raise exception 'Commissioner access required.'; end if;
  for v_player in select distinct sleeper_id from public.waiver_bids where league_id=p_league_id and week=p_week and processed_at is null loop
    select b.* into v_bid from public.waiver_bids b join public.teams t on t.id=b.team_id
      where b.league_id=p_league_id and b.week=p_week and b.sleeper_id=v_player.sleeper_id and b.processed_at is null and t.alive
      order by b.bid_amount desc,b.priority asc,b.submitted_at asc,b.id asc limit 1 for update;
    if v_bid.id is null then continue; end if;
    select faab into v_faab from public.teams where id=v_bid.team_id for update;
    if v_bid.bid_amount>v_faab then
      update public.waiver_bids set processed_at=now() where league_id=p_league_id and week=p_week and sleeper_id=v_player.sleeper_id;
      continue;
    end if;
    delete from public.roster_players where league_id=p_league_id and sleeper_id=v_player.sleeper_id;
    insert into public.roster_players(league_id,team_id,sleeper_id,acquired_week,acquired_via,roster_slot)
      values(p_league_id,v_bid.team_id,v_player.sleeper_id,p_week,'waiver','BENCH');
    update public.teams set faab=faab-v_bid.bid_amount where id=v_bid.team_id;
    delete from public.waiver_pool where league_id=p_league_id and sleeper_id=v_player.sleeper_id;
    update public.waiver_bids set processed_at=now() where league_id=p_league_id and week=p_week and sleeper_id=v_player.sleeper_id;
    insert into public.audit_log(league_id,actor_user_id,action,details) values(p_league_id,auth.uid(),'waiver_awarded',jsonb_build_object('team_id',v_bid.team_id,'sleeper_id',v_player.sleeper_id,'bid',v_bid.bid_amount,'week',p_week));
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;
revoke all on function public.process_waivers(uuid,int) from public;
grant execute on function public.process_waivers(uuid,int) to authenticated;

-- Safer read policies for waiver pool and scores are already present in install.sql.
