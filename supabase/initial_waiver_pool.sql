-- INITIAL WAIVER POOL
-- After the draft is complete, every player who was NOT drafted is placed
-- into that league's waiver pool. Drafted players remain on their teams.

create or replace function public.populate_initial_waiver_pool(p_league_id uuid)
returns int
language plpgsql
security definer
set search_path=public
as $initial_pool$
declare
  v_count int;
begin
  if not public.is_commissioner(p_league_id) then
    raise exception 'Commissioner access required.';
  end if;

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
$initial_pool$;

revoke all on function public.populate_initial_waiver_pool(uuid) from public;
grant execute on function public.populate_initial_waiver_pool(uuid) to authenticated;

-- Replace complete_draft so finishing the draft automatically builds the
-- initial waiver pool in the same transaction.
create or replace function public.complete_draft(p_league_id uuid)
returns public.draft_state
language plpgsql
security definer
set search_path=public
as $complete_draft$
declare
  v public.draft_state;
  v_count int;
  v_total int;
begin
  if not public.is_commissioner(p_league_id) then
    raise exception 'Commissioner access required.';
  end if;

  select count(*) into v_count
  from public.draft_picks
  where league_id=p_league_id;

  select rounds into v_total
  from public.draft_state
  where league_id=p_league_id;

  if v_total is null then
    raise exception 'Set up the draft first.';
  end if;

  if v_count < 18*v_total then
    raise exception 'Draft is not complete. % of % picks have been made.',v_count,18*v_total;
  end if;

  perform public.populate_initial_waiver_pool(p_league_id);

  update public.draft_state
  set status='complete',paused_at=null,pick_started_at=null,
      remaining_seconds=0,updated_at=now()
  where league_id=p_league_id
  returning * into v;

  return v;
end;
$complete_draft$;

revoke all on function public.complete_draft(uuid) from public;
grant execute on function public.complete_draft(uuid) to authenticated;

-- Keep the automatic completion path consistent with the manual Complete
-- Draft button: when the final pick is made, populate the waiver pool.
-- This replaces the existing draft pick RPC without changing its interface.
create or replace function public.make_draft_pick(
  p_league_id uuid,p_team_id uuid,p_sleeper_id text,
  p_player_name text,p_position text
)
returns public.draft_picks
language plpgsql
security definer
set search_path=public
as $make_pick$
declare
  v_pick public.draft_picks;
  v_count int;
  v_pick_number int;
  v_round int;
  v_expected_team int;
  v_team_number int;
  v_status text;
  v_ds public.draft_state;
  v_total int;
begin
  if not exists(
    select 1 from public.teams
    where id=p_team_id and league_id=p_league_id and owner_user_id=auth.uid()
  ) and not public.is_commissioner(p_league_id) then
    raise exception 'You do not control that team.';
  end if;

  select status into v_status from public.leagues where id=p_league_id;
  if v_status is null then raise exception 'League not found.'; end if;

  if exists(select 1 from public.draft_picks where league_id=p_league_id and sleeper_id=p_sleeper_id) then
    raise exception 'That player has already been drafted.';
  end if;

  select team_number into v_team_number
  from public.teams where id=p_team_id and league_id=p_league_id;

  select count(*) into v_count
  from public.draft_picks where league_id=p_league_id;

  select * into v_ds from public.draft_state where league_id=p_league_id;

  if v_ds.league_id is not null then
    if v_ds.status <> 'running' and not public.is_commissioner(p_league_id) then
      raise exception 'The draft is not currently running.';
    end if;
    v_total := 18*v_ds.rounds;
    if v_count >= v_total then raise exception 'The draft is complete.'; end if;
  end if;

  v_pick_number := v_count + 1;
  v_round := ((v_pick_number-1)/18)+1;

  if mod(v_round,2)=1 then
    v_expected_team := mod(v_pick_number-1,18)+1;
  else
    v_expected_team := 18-mod(v_pick_number-1,18);
  end if;

  if v_team_number <> v_expected_team and not public.is_commissioner(p_league_id) then
    raise exception 'It is Team %''s turn to pick.',v_expected_team;
  end if;

  if not exists(select 1 from public.players where sleeper_id=p_sleeper_id) then
    raise exception 'Player is not in the league player database. Commissioner must sync players first.';
  end if;

  insert into public.draft_picks(
    league_id,round,pick_number,team_id,sleeper_id,player_name,position
  ) values(
    p_league_id,v_round,v_pick_number,p_team_id,p_sleeper_id,p_player_name,p_position
  ) returning * into v_pick;

  insert into public.roster_players(
    league_id,team_id,sleeper_id,acquired_week,acquired_via,roster_slot
  ) values(
    p_league_id,p_team_id,p_sleeper_id,1,'draft','BENCH'
  );

  if v_ds.league_id is not null then
    if v_pick_number >= v_total then
      perform public.populate_initial_waiver_pool(p_league_id);
      update public.draft_state
      set status='complete',pick_started_at=null,remaining_seconds=0,updated_at=now()
      where league_id=p_league_id;
    else
      update public.draft_state
      set status='running',pick_started_at=now(),remaining_seconds=pick_seconds,updated_at=now()
      where league_id=p_league_id;
    end if;
  end if;

  return v_pick;
exception when unique_violation then
  raise exception 'That player or pick was just taken. Refresh the draft room.';
end;
$make_pick$;

revoke all on function public.make_draft_pick(uuid,uuid,text,text,text) from public;
grant execute on function public.make_draft_pick(uuid,uuid,text,text,text) to authenticated;
