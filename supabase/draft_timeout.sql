-- Guillotine League Manager - draft pick timeout handling
-- Run once in Supabase SQL Editor after draft_control.sql.

alter table public.draft_state
  add column if not exists timeout_pending boolean not null default false;

create table if not exists public.draft_skips (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  pick_number int not null,
  round int not null,
  team_id uuid not null references public.teams(id) on delete cascade,
  skipped_at timestamptz not null default now(),
  reason text not null default 'Pick clock expired',
  unique(league_id,pick_number)
);

alter table public.draft_skips enable row level security;
drop policy if exists draft_skips_select on public.draft_skips;
create policy draft_skips_select on public.draft_skips for select to authenticated
using (public.is_league_member(league_id) or public.is_commissioner(league_id));

-- Mark an expired clock as requiring commissioner action. Any league member may
-- safely trigger this; the database verifies the clock really expired.
create or replace function public.flag_expired_draft_pick(p_league_id uuid)
returns public.draft_state
language plpgsql security definer set search_path=public as $$
declare v public.draft_state; v_elapsed int;
begin
  if not public.is_league_member(p_league_id) and not public.is_commissioner(p_league_id) then
    raise exception 'League access required.';
  end if;
  select * into v from public.draft_state where league_id=p_league_id for update;
  if v.league_id is null then raise exception 'Draft has not been set up.'; end if;
  if v.status <> 'running' then raise exception 'Draft is not running.'; end if;
  v_elapsed := greatest(0, extract(epoch from (clock_timestamp()-v.pick_started_at))::int);
  if v_elapsed < coalesce(v.remaining_seconds,v.pick_seconds) then
    raise exception 'The pick clock has not expired.';
  end if;
  update public.draft_state
    set timeout_pending=true, remaining_seconds=0, updated_at=now()
    where league_id=p_league_id
    returning * into v;
  return v;
end; $$;

-- Commissioner-only action: skip the expired pick and immediately start the
-- next snake-order pick clock. The skipped pick is permanently recorded.
create or replace function public.skip_expired_draft_pick(p_league_id uuid)
returns public.draft_state
language plpgsql security definer set search_path=public as $$
declare
  v public.draft_state;
  v_picks int;
  v_skips int;
  v_pick_number int;
  v_round int;
  v_team_number int;
  v_team_id uuid;
  v_total int;
  v_elapsed int;
begin
  if not public.is_commissioner(p_league_id) then raise exception 'Commissioner access required.'; end if;
  select * into v from public.draft_state where league_id=p_league_id for update;
  if v.league_id is null then raise exception 'Draft has not been set up.'; end if;
  if v.status <> 'running' then raise exception 'Draft is not running.'; end if;
  v_elapsed := greatest(0, extract(epoch from (clock_timestamp()-v.pick_started_at))::int);
  if not v.timeout_pending and v_elapsed < coalesce(v.remaining_seconds,v.pick_seconds) then
    raise exception 'The pick clock has not expired.';
  end if;
  select count(*) into v_picks from public.draft_picks where league_id=p_league_id;
  select count(*) into v_skips from public.draft_skips where league_id=p_league_id;
  v_pick_number := v_picks + v_skips + 1;
  v_total := 18 * v.rounds;
  if v_pick_number > v_total then
    update public.draft_state set status='complete',timeout_pending=false,pick_started_at=null,remaining_seconds=0,updated_at=now() where league_id=p_league_id returning * into v;
    return v;
  end if;
  v_round := ((v_pick_number-1)/18)+1;
  if mod(v_round,2)=1 then v_team_number := mod(v_pick_number-1,18)+1; else v_team_number := 18-mod(v_pick_number-1,18); end if;
  select id into v_team_id from public.teams where league_id=p_league_id and team_number=v_team_number;
  if v_team_id is null then raise exception 'Expected Team % was not found.',v_team_number; end if;
  insert into public.draft_skips(league_id,pick_number,round,team_id)
    values(p_league_id,v_pick_number,v_round,v_team_id);
  if v_pick_number >= v_total then
    update public.draft_state set status='complete',timeout_pending=false,pick_started_at=null,remaining_seconds=0,updated_at=now() where league_id=p_league_id returning * into v;
  else
    update public.draft_state set timeout_pending=false,pick_started_at=now(),remaining_seconds=pick_seconds,updated_at=now() where league_id=p_league_id returning * into v;
  end if;
  insert into public.audit_log(league_id,actor_user_id,action,details)
    values(p_league_id,auth.uid(),'draft_pick_timeout',jsonb_build_object('pick_number',v_pick_number,'team_id',v_team_id,'team_number',v_team_number,'action','skip'));
  return v;
exception when unique_violation then
  raise exception 'That expired pick has already been advanced. Refresh the Draft Control page.';
end; $$;

-- Replace the draft pick RPC so skipped picks advance the snake order and a
-- successful commissioner/manager pick clears any timeout alert.
create or replace function public.make_draft_pick(p_league_id uuid, p_team_id uuid, p_sleeper_id text, p_player_name text, p_position text)
returns public.draft_picks language plpgsql security definer set search_path=public as $$
declare
  v_pick public.draft_picks;
  v_count int;
  v_skips int;
  v_pick_number int;
  v_round int;
  v_expected_team int;
  v_team_number int;
  v_status text;
  v_ds public.draft_state;
  v_total int;
begin
  if not exists(select 1 from public.teams where id=p_team_id and league_id=p_league_id and owner_user_id=auth.uid()) and not public.is_commissioner(p_league_id) then raise exception 'You do not control that team.'; end if;
  select status into v_status from public.leagues where id=p_league_id;
  if v_status is null then raise exception 'League not found.'; end if;
  if exists(select 1 from public.draft_picks where league_id=p_league_id and sleeper_id=p_sleeper_id) then raise exception 'That player has already been drafted.'; end if;
  select team_number into v_team_number from public.teams where id=p_team_id and league_id=p_league_id;
  select count(*) into v_count from public.draft_picks where league_id=p_league_id;
  select count(*) into v_skips from public.draft_skips where league_id=p_league_id;
  select * into v_ds from public.draft_state where league_id=p_league_id for update;
  if v_ds.league_id is not null then
    if v_ds.status <> 'running' and not public.is_commissioner(p_league_id) then raise exception 'The draft is not currently running.'; end if;
    v_total := 18*v_ds.rounds;
    if v_count + v_skips >= v_total then raise exception 'The draft is complete.'; end if;
  end if;
  v_pick_number := v_count + v_skips + 1; v_round := ((v_pick_number-1)/18)+1;
  if mod(v_round,2)=1 then v_expected_team := mod(v_pick_number-1,18)+1; else v_expected_team := 18-mod(v_pick_number-1,18); end if;
  if v_team_number <> v_expected_team and not public.is_commissioner(p_league_id) then raise exception 'It is Team %''s turn to pick.',v_expected_team; end if;
  if not exists(select 1 from public.players where sleeper_id=p_sleeper_id) then raise exception 'Player is not in the league player database. Commissioner must sync players first.'; end if;
  insert into public.draft_picks(league_id,round,pick_number,team_id,sleeper_id,player_name,position)
    values(p_league_id,v_round,v_pick_number,p_team_id,p_sleeper_id,p_player_name,p_position) returning * into v_pick;
  insert into public.roster_players(league_id,team_id,sleeper_id,acquired_week,acquired_via,roster_slot)
    values(p_league_id,p_team_id,p_sleeper_id,1,'draft','BENCH');
  if v_ds.league_id is not null then
    if v_pick_number >= v_total then
      update public.draft_state set status='complete',timeout_pending=false,pick_started_at=null,remaining_seconds=0,updated_at=now() where league_id=p_league_id;
    else
      update public.draft_state set status='running',timeout_pending=false,pick_started_at=now(),remaining_seconds=pick_seconds,updated_at=now() where league_id=p_league_id;
    end if;
  end if;
  return v_pick;
exception when unique_violation then raise exception 'That player or pick was just taken. Refresh the draft room.';
end; $$;

revoke all on function public.flag_expired_draft_pick(uuid) from public;
revoke all on function public.skip_expired_draft_pick(uuid) from public;
grant execute on function public.flag_expired_draft_pick(uuid) to authenticated;
grant execute on function public.skip_expired_draft_pick(uuid) to authenticated;

do $$ begin if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='draft_skips') then alter publication supabase_realtime add table public.draft_skips; end if; end $$;
