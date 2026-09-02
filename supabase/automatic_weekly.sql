-- Automatic Guillotine weekly engine
-- Run this once in Supabase SQL Editor after weekly.sql and workflow.sql.
-- This function is intentionally staged: it NEVER eliminates a team automatically.
-- It locks completed-week lineups, syncs/calculates through existing RPCs, and returns
-- the current workflow state. The commissioner still confirms the irreversible elimination.

create or replace function public.weekly_engine_status(p_league_id uuid, p_week int default null)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_league public.leagues;
  v_week int;
  v_alive int;
  v_scores int;
  v_locked int;
  v_elim boolean;
  v_pending int;
  v_low_team uuid;
  v_low_score numeric;
  v_low_tiebreak numeric;
begin
  select * into v_league from public.leagues where id=p_league_id;
  if not found then raise exception 'League not found.'; end if;
  v_week := coalesce(p_week,v_league.current_week);
  if v_week < 1 or v_week > 17 then raise exception 'Week must be 1-17.'; end if;
  select count(*) into v_alive from public.teams where league_id=p_league_id and alive;
  select count(*) into v_scores from public.weekly_scores where league_id=p_league_id and week=v_week and locked;
  select count(*) into v_locked from public.lineups l join public.teams t on t.id=l.team_id where l.league_id=p_league_id and l.week=v_week and l.locked and t.alive;
  select exists(select 1 from public.eliminations where league_id=p_league_id and week=v_week) into v_elim;
  select count(*) into v_pending from public.waiver_bids where league_id=p_league_id and week=v_week and processed_at is null;

  select t.id,ws.points,coalesce((select sum(x.points) from public.weekly_scores x where x.league_id=p_league_id and x.team_id=t.id and x.week<=v_week),0)
    into v_low_team,v_low_score,v_low_tiebreak
  from public.teams t join public.weekly_scores ws on ws.team_id=t.id and ws.league_id=p_league_id and ws.week=v_week
  where t.league_id=p_league_id and t.alive
  order by ws.points asc,
    (select coalesce(sum(x.points),0) from public.weekly_scores x where x.league_id=p_league_id and x.team_id=t.id and x.week<=v_week) asc,
    t.team_number asc
  limit 1;

  return jsonb_build_object('week',v_week,'league_status',v_league.status,'teams_alive',v_alive,'scores_calculated',v_scores,'lineups_locked',v_locked,'eliminated',v_elim,'pending_bids',v_pending,'lowest_team_id',v_low_team,'lowest_score',v_low_score,'lowest_season_points',v_low_tiebreak,'ready_for_elimination',(v_scores>0 and not v_elim),'ready_for_waivers',(v_elim and v_pending=0),'ready_to_advance',(v_elim and v_pending=0),'complete',(v_league.status='complete'));
end;
$$;
revoke all on function public.weekly_engine_status(uuid,int) from public;
grant execute on function public.weekly_engine_status(uuid,int) to authenticated;

create or replace function public.lock_week_lineups(p_league_id uuid, p_week int)
returns int language plpgsql security definer set search_path=public as $$
declare v_user uuid:=auth.uid(); v_comm uuid; v_count int;
begin
  if v_user is null then raise exception 'You must be signed in.'; end if;
  select commissioner_user_id into v_comm from public.leagues where id=p_league_id;
  if v_comm is null then raise exception 'League not found.'; end if;
  if v_comm<>v_user then raise exception 'Commissioner access required.'; end if;
  if p_week<1 or p_week>17 then raise exception 'Week must be 1-17.'; end if;
  update public.lineups l set locked=true where l.league_id=p_league_id and l.week=p_week and exists(select 1 from public.teams t where t.id=l.team_id and t.league_id=p_league_id and t.alive);
  get diagnostics v_count=row_count;
  insert into public.audit_log(league_id,actor_user_id,action,details) values(p_league_id,v_user,'lock_week_lineups',jsonb_build_object('week',p_week,'rows_locked',v_count));
  return v_count;
end;$$;
revoke all on function public.lock_week_lineups(uuid,int) from public;
grant execute on function public.lock_week_lineups(uuid,int) to authenticated;

create or replace function public.advance_guillotine_week(p_league_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_user uuid:=auth.uid(); v_league public.leagues; v_alive int; v_week int; v_pending int; v_elim boolean; v_champion text;
begin
  if v_user is null then raise exception 'You must be signed in.'; end if;
  select * into v_league from public.leagues where id=p_league_id for update;
  if not found then raise exception 'League not found.'; end if;
  if v_league.commissioner_user_id<>v_user then raise exception 'Commissioner access required.'; end if;
  if v_league.status='complete' then return jsonb_build_object('complete',true,'week',v_league.current_week); end if;
  v_week:=v_league.current_week;
  select count(*) into v_alive from public.teams where league_id=p_league_id and alive;
  select exists(select 1 from public.eliminations where league_id=p_league_id and week=v_week) into v_elim;
  select count(*) into v_pending from public.waiver_bids where league_id=p_league_id and week=v_week and processed_at is null;
  if not v_elim then raise exception 'Week % must be eliminated before advancing.',v_week; end if;
  if v_pending>0 then raise exception 'Process all waiver bids before advancing.'; end if;
  if v_week>=17 or v_alive<=1 then
    select coalesce(manager_name,name) into v_champion from public.teams where league_id=p_league_id and alive limit 1;
    update public.leagues set status='complete' where id=p_league_id;
    insert into public.audit_log(league_id,actor_user_id,action,details) values(p_league_id,v_user,'league_complete',jsonb_build_object('week',v_week,'champion',v_champion));
    return jsonb_build_object('complete',true,'week',v_week,'champion',v_champion);
  end if;
  update public.leagues set current_week=v_week+1,status='active' where id=p_league_id;
  insert into public.audit_log(league_id,actor_user_id,action,details) values(p_league_id,v_user,'advance_week',jsonb_build_object('from_week',v_week,'to_week',v_week+1));
  return jsonb_build_object('complete',false,'week',v_week+1);
end;$$;
revoke all on function public.advance_guillotine_week(uuid) from public;
grant execute on function public.advance_guillotine_week(uuid) to authenticated;
