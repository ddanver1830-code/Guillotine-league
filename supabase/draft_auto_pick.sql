-- Automatic best-available pick when a draft clock expires.
-- Run AFTER draft_timeout.sql and draft_timeout_fix.sql.
--
-- Best available is determined from the Sleeper player data stored in
-- players.metadata: lowest search_rank wins. Players without a usable
-- search_rank are placed after ranked players, then name is used as a
-- deterministic tie-breaker.

create or replace function public.auto_pick_expired_draft_pick(p_league_id uuid)
returns public.draft_picks
language plpgsql
security definer
set search_path=public
as $$
declare
  v_ds public.draft_state;
  v_pick public.draft_picks;
  v_player public.players;
  v_team_id uuid;
  v_team_number int;
  v_pick_number int;
  v_round int;
  v_expected_team int;
  v_total int;
  v_elapsed int;
begin
  if not public.is_league_member(p_league_id) and not public.is_commissioner(p_league_id) then
    raise exception 'League access required.';
  end if;

  select * into v_ds
  from public.draft_state
  where league_id=p_league_id
  for update;

  if v_ds.league_id is null then
    raise exception 'Draft has not been set up.';
  end if;
  if v_ds.status <> 'running' then
    raise exception 'Draft is not running.';
  end if;

  v_elapsed := greatest(0, extract(epoch from (clock_timestamp()-v_ds.pick_started_at))::int);
  if not v_ds.timeout_pending and v_elapsed < coalesce(v_ds.remaining_seconds,v_ds.pick_seconds) then
    raise exception 'The pick clock has not expired.';
  end if;

  select count(*) into v_pick_number from public.draft_picks where league_id=p_league_id;
  v_pick_number := v_pick_number + 1;
  v_total := 18 * v_ds.rounds;
  if v_pick_number > v_total then
    raise exception 'The draft is complete.';
  end if;

  v_round := ((v_pick_number-1)/18)+1;
  if mod(v_round,2)=1 then
    v_expected_team := mod(v_pick_number-1,18)+1;
  else
    v_expected_team := 18-mod(v_pick_number-1,18);
  end if;

  select id into v_team_id
  from public.teams
  where league_id=p_league_id and team_number=v_expected_team;
  if v_team_id is null then
    raise exception 'Expected Team % was not found.',v_expected_team;
  end if;

  -- Sleeper's search_rank is a useful deterministic proxy for the best
  -- available player. It is already present in the synced metadata.
  select p.* into v_player
  from public.players p
  where p.sleeper_id not in (
    select dp.sleeper_id
    from public.draft_picks dp
    where dp.league_id=p_league_id and dp.sleeper_id is not null
  )
  order by
    case when (p.metadata->>'search_rank') ~ '^\\d+(\\.\\d+)?$' then 0 else 1 end,
    case when (p.metadata->>'search_rank') ~ '^\\d+(\\.\\d+)?$'
      then (p.metadata->>'search_rank')::numeric else 999999999 end,
    p.name asc
  limit 1;

  if v_player.sleeper_id is null then
    raise exception 'No available players remain for the automatic pick.';
  end if;

  insert into public.draft_picks(
    league_id,round,pick_number,team_id,sleeper_id,player_name,position
  ) values (
    p_league_id,v_round,v_pick_number,v_team_id,v_player.sleeper_id,v_player.name,v_player.position
  ) returning * into v_pick;

  insert into public.roster_players(
    league_id,team_id,sleeper_id,acquired_week,acquired_via,roster_slot
  ) values (
    p_league_id,v_team_id,v_player.sleeper_id,1,'draft','BENCH'
  );

  insert into public.draft_skips(
    league_id,pick_number,round,team_id,reason
  ) values (
    p_league_id,v_pick_number,v_round,v_team_id,'Clock expired — automatic best-available pick'
  )
  on conflict (league_id,pick_number) do update
    set reason='Clock expired — automatic best-available pick';

  if v_pick_number >= v_total then
    update public.draft_state
      set status='complete',timeout_pending=false,pick_started_at=null,remaining_seconds=0,updated_at=now()
    where league_id=p_league_id;
  else
    update public.draft_state
      set status='running',timeout_pending=false,pick_started_at=now(),remaining_seconds=pick_seconds,updated_at=now()
    where league_id=p_league_id;
  end if;

  insert into public.audit_log(league_id,actor_user_id,action,details)
  values(
    p_league_id,auth.uid(),'draft_auto_pick',
    jsonb_build_object(
      'pick_number',v_pick_number,
      'team_id',v_team_id,
      'team_number',v_expected_team,
      'sleeper_id',v_player.sleeper_id,
      'player_name',v_player.name,
      'position',v_player.position,
      'reason','Clock expired — automatic best-available pick'
    )
  );

  return v_pick;
exception when unique_violation then
  raise exception 'That expired pick was already processed. Refresh the draft room.';
end;
$$;

revoke all on function public.auto_pick_expired_draft_pick(uuid) from public;
grant execute on function public.auto_pick_expired_draft_pick(uuid) to authenticated;
