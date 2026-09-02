-- Guillotine League Manager - persistent draft control
-- Run once in Supabase SQL Editor after draft.sql.

create table if not exists public.draft_state (
  league_id uuid primary key references public.leagues(id) on delete cascade,
  status text not null default 'setup' check(status in ('setup','running','paused','complete')),
  scheduled_at timestamptz,
  rounds int not null default 13 check(rounds between 1 and 30),
  pick_seconds int not null default 90 check(pick_seconds between 10 and 900),
  started_at timestamptz,
  paused_at timestamptz,
  pick_started_at timestamptz,
  remaining_seconds int,
  updated_at timestamptz not null default now()
);

alter table public.draft_state enable row level security;
drop policy if exists draft_state_select on public.draft_state;
create policy draft_state_select on public.draft_state for select to authenticated
using (public.is_league_member(league_id) or public.is_commissioner(league_id));

create or replace function public.setup_draft(
  p_league_id uuid,
  p_scheduled_at timestamptz,
  p_rounds int default 13,
  p_pick_seconds int default 90
) returns public.draft_state
language plpgsql security definer set search_path=public as $$
declare v public.draft_state;
begin
  if not public.is_commissioner(p_league_id) then raise exception 'Commissioner access required.'; end if;
  if exists(select 1 from public.draft_picks where league_id=p_league_id) then raise exception 'Draft picks already exist. Draft setup cannot be changed after the draft begins.'; end if;
  if p_rounds < 1 or p_rounds > 30 then raise exception 'Rounds must be between 1 and 30.'; end if;
  if p_pick_seconds < 10 or p_pick_seconds > 900 then raise exception 'Pick timer must be between 10 and 900 seconds.'; end if;
  insert into public.draft_state(league_id,status,scheduled_at,rounds,pick_seconds,started_at,paused_at,pick_started_at,remaining_seconds,updated_at)
  values(p_league_id,'setup',p_scheduled_at,p_rounds,p_pick_seconds,null,null,null,p_pick_seconds,now())
  on conflict(league_id) do update set status='setup',scheduled_at=excluded.scheduled_at,rounds=excluded.rounds,pick_seconds=excluded.pick_seconds,started_at=null,paused_at=null,pick_started_at=null,remaining_seconds=excluded.pick_seconds,updated_at=now()
  returning * into v;
  return v;
end; $$;

create or replace function public.start_draft(p_league_id uuid) returns public.draft_state
language plpgsql security definer set search_path=public as $$
declare v public.draft_state; v_count int; v_total int;
begin
  if not public.is_commissioner(p_league_id) then raise exception 'Commissioner access required.'; end if;
  select count(*) into v_count from public.draft_picks where league_id=p_league_id;
  select rounds into v_total from public.draft_state where league_id=p_league_id;
  if v_total is null then raise exception 'Set up the draft first.'; end if;
  if v_count >= 18*v_total then raise exception 'All draft picks are complete.'; end if;
  update public.draft_state set status='running',started_at=coalesce(started_at,now()),paused_at=null,pick_started_at=now(),remaining_seconds=pick_seconds,updated_at=now() where league_id=p_league_id returning * into v;
  return v;
end; $$;

create or replace function public.pause_draft(p_league_id uuid) returns public.draft_state
language plpgsql security definer set search_path=public as $$
declare v public.draft_state; v_remaining int;
begin
  if not public.is_commissioner(p_league_id) then raise exception 'Commissioner access required.'; end if;
  select * into v from public.draft_state where league_id=p_league_id for update;
  if v.status <> 'running' then raise exception 'Draft is not running.'; end if;
  v_remaining := greatest(0, v.remaining_seconds - greatest(0,extract(epoch from (now()-v.pick_started_at))::int));
  update public.draft_state set status='paused',paused_at=now(),pick_started_at=null,remaining_seconds=v_remaining,updated_at=now() where league_id=p_league_id returning * into v;
  return v;
end; $$;

create or replace function public.resume_draft(p_league_id uuid) returns public.draft_state
language plpgsql security definer set search_path=public as $$
declare v public.draft_state;
begin
  if not public.is_commissioner(p_league_id) then raise exception 'Commissioner access required.'; end if;
  update public.draft_state set status='running',pick_started_at=now(),remaining_seconds=greatest(1,coalesce(remaining_seconds,pick_seconds)),updated_at=now() where league_id=p_league_id and status='paused' returning * into v;
  if v.league_id is null then raise exception 'Draft is not paused.'; end if;
  return v;
end; $$;

create or replace function public.complete_draft(p_league_id uuid) returns public.draft_state
language plpgsql security definer set search_path=public as $$
declare v public.draft_state; v_count int; v_total int;
begin
  if not public.is_commissioner(p_league_id) then raise exception 'Commissioner access required.'; end if;
  select count(*) into v_count from public.draft_picks where league_id=p_league_id;
  select rounds into v_total from public.draft_state where league_id=p_league_id;
  if v_total is null then raise exception 'Set up the draft first.'; end if;
  if v_count < 18*v_total then raise exception 'Draft is not complete. % of % picks have been made.',v_count,18*v_total; end if;
  update public.draft_state set status='complete',paused_at=null,pick_started_at=null,remaining_seconds=0,updated_at=now() where league_id=p_league_id returning * into v;
  return v;
end; $$;

-- Replace the draft RPC so each completed pick automatically starts the next pick timer.
create or replace function public.make_draft_pick(p_league_id uuid, p_team_id uuid, p_sleeper_id text, p_player_name text, p_position text)
returns public.draft_picks language plpgsql security definer set search_path=public as $$
declare v_pick public.draft_picks; v_count int; v_pick_number int; v_round int; v_expected_team int; v_team_number int; v_status text; v_ds public.draft_state; v_total int;
begin
  if not exists(select 1 from public.teams where id=p_team_id and league_id=p_league_id and owner_user_id=auth.uid()) and not public.is_commissioner(p_league_id) then raise exception 'You do not control that team.'; end if;
  select status into v_status from public.leagues where id=p_league_id;
  if v_status is null then raise exception 'League not found.'; end if;
  if exists(select 1 from public.draft_picks where league_id=p_league_id and sleeper_id=p_sleeper_id) then raise exception 'That player has already been drafted.'; end if;
  select team_number into v_team_number from public.teams where id=p_team_id and league_id=p_league_id;
  select count(*) into v_count from public.draft_picks where league_id=p_league_id;
  select * into v_ds from public.draft_state where league_id=p_league_id;
  if v_ds.league_id is not null then
    if v_ds.status <> 'running' and not public.is_commissioner(p_league_id) then raise exception 'The draft is not currently running.'; end if;
    v_total := 18*v_ds.rounds;
    if v_count >= v_total then raise exception 'The draft is complete.'; end if;
  end if;
  v_pick_number := v_count + 1; v_round := ((v_pick_number-1)/18)+1;
  if mod(v_round,2)=1 then v_expected_team := mod(v_pick_number-1,18)+1; else v_expected_team := 18-mod(v_pick_number-1,18); end if;
  if v_team_number <> v_expected_team and not public.is_commissioner(p_league_id) then raise exception 'It is Team %''s turn to pick.',v_expected_team; end if;
  if not exists(select 1 from public.players where sleeper_id=p_sleeper_id) then raise exception 'Player is not in the league player database. Commissioner must sync players first.'; end if;
  insert into public.draft_picks(league_id,round,pick_number,team_id,sleeper_id,player_name,position) values(p_league_id,v_round,v_pick_number,p_team_id,p_sleeper_id,p_player_name,p_position) returning * into v_pick;
  insert into public.roster_players(league_id,team_id,sleeper_id,acquired_week,acquired_via,roster_slot) values(p_league_id,p_team_id,p_sleeper_id,1,'draft','BENCH');
  if v_ds.league_id is not null then
    if v_pick_number >= v_total then update public.draft_state set status='complete',pick_started_at=null,remaining_seconds=0,updated_at=now() where league_id=p_league_id;
    else update public.draft_state set status='running',pick_started_at=now(),remaining_seconds=pick_seconds,updated_at=now() where league_id=p_league_id; end if;
  end if;
  return v_pick;
exception when unique_violation then raise exception 'That player or pick was just taken. Refresh the draft room.';
end; $$;

revoke all on function public.setup_draft(uuid,timestamptz,int,int) from public;
revoke all on function public.start_draft(uuid) from public;
revoke all on function public.pause_draft(uuid) from public;
revoke all on function public.resume_draft(uuid) from public;
revoke all on function public.complete_draft(uuid) from public;
grant execute on function public.setup_draft(uuid,timestamptz,int,int) to authenticated;
grant execute on function public.start_draft(uuid) to authenticated;
grant execute on function public.pause_draft(uuid) to authenticated;
grant execute on function public.resume_draft(uuid) to authenticated;
grant execute on function public.complete_draft(uuid) to authenticated;

do $$ begin if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='draft_state') then alter publication supabase_realtime add table public.draft_state; end if; end $$;
