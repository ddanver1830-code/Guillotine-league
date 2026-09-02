-- Guillotine League Manager - draft support migration
-- Run once in Supabase SQL Editor after install.sql.

create policy players_commissioner_write on public.players
for all to authenticated
using (public.is_commissioner((select id from public.leagues where commissioner_user_id=auth.uid() limit 1)))
with check (true);

create or replace function public.make_draft_pick(p_league_id uuid, p_team_id uuid, p_sleeper_id text, p_player_name text, p_position text)
returns public.draft_picks
language plpgsql
security definer
set search_path=public
as $$
declare
  v_pick public.draft_picks;
  v_count int;
  v_pick_number int;
  v_round int;
  v_expected_team int;
  v_team_number int;
  v_status text;
begin
  if not exists(select 1 from public.teams where id=p_team_id and league_id=p_league_id and owner_user_id=auth.uid())
     and not public.is_commissioner(p_league_id) then
    raise exception 'You do not control that team.';
  end if;
  select status into v_status from public.leagues where id=p_league_id;
  if v_status is null then raise exception 'League not found.'; end if;
  if exists(select 1 from public.draft_picks where league_id=p_league_id and sleeper_id=p_sleeper_id) then
    raise exception 'That player has already been drafted.';
  end if;
  select team_number into v_team_number from public.teams where id=p_team_id and league_id=p_league_id;
  select count(*) into v_count from public.draft_picks where league_id=p_league_id;
  v_pick_number := v_count + 1;
  v_round := ((v_pick_number-1) / 18) + 1;
  if mod(v_round,2)=1 then v_expected_team := mod(v_pick_number-1,18)+1;
  else v_expected_team := 18-mod(v_pick_number-1,18); end if;
  if v_team_number <> v_expected_team and not public.is_commissioner(p_league_id) then
    raise exception 'It is Team %''s turn to pick.', v_expected_team;
  end if;
  if not exists(select 1 from public.players where sleeper_id=p_sleeper_id) then
    raise exception 'Player is not in the league player database. Commissioner must sync players first.';
  end if;
  insert into public.draft_picks(league_id,round,pick_number,team_id,sleeper_id,player_name,position)
  values(p_league_id,v_round,v_pick_number,p_team_id,p_sleeper_id,p_player_name,p_position)
  returning * into v_pick;
  insert into public.roster_players(league_id,team_id,sleeper_id,acquired_week,acquired_via,roster_slot)
  values(p_league_id,p_team_id,p_sleeper_id,1,'draft','BENCH');
  return v_pick;
exception when unique_violation then
  raise exception 'That player or pick was just taken. Refresh the draft room.';
end;
$$;
revoke all on function public.make_draft_pick(uuid,uuid,text,text,text) from public;
grant execute on function public.make_draft_pick(uuid,uuid,text,text,text) to authenticated;

create policy draft_insert_members on public.draft_picks
for insert to authenticated
with check (public.is_league_member(league_id) or public.is_commissioner(league_id));
