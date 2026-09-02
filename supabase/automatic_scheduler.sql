-- Guillotine automatic NFL-week scheduler support
-- Run once after automatic_weekly.sql.
-- This does NOT auto-eliminate teams. It only records a safe, commissioner-reviewable
-- Sleeper NFL state and provides idempotent workflow helpers.

create table if not exists public.league_engine_state (
  league_id uuid primary key references public.leagues(id) on delete cascade,
  nfl_state jsonb not null default '{}'::jsonb,
  detected_week int,
  season_type text,
  is_scoring_period_complete boolean not null default false,
  last_checked_at timestamptz,
  last_stats_sync_at timestamptz,
  last_scores_at timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.league_engine_state enable row level security;
drop policy if exists "engine state select" on public.league_engine_state;
create policy "engine state select" on public.league_engine_state for select to authenticated using (
  exists(select 1 from public.leagues l where l.id=league_id and (l.commissioner_user_id=auth.uid() or exists(select 1 from public.teams t where t.league_id=l.id and t.owner_user_id=auth.uid())))
);
drop policy if exists "engine state commissioner write" on public.league_engine_state;
create policy "engine state commissioner write" on public.league_engine_state for all to authenticated using (
  exists(select 1 from public.leagues l where l.id=league_id and l.commissioner_user_id=auth.uid())
) with check (
  exists(select 1 from public.leagues l where l.id=league_id and l.commissioner_user_id=auth.uid())
);

create or replace function public.record_nfl_state(p_league_id uuid,p_state jsonb,p_detected_week int,p_season_type text,p_complete boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_user uuid:=auth.uid(); v_comm uuid; begin
 select commissioner_user_id into v_comm from public.leagues where id=p_league_id;
 if v_comm is null then raise exception 'League not found.'; end if;
 if v_comm<>v_user then raise exception 'Commissioner access required.'; end if;
 insert into public.league_engine_state(league_id,nfl_state,detected_week,season_type,is_scoring_period_complete,last_checked_at,updated_at)
 values(p_league_id,p_state,p_detected_week,p_season_type,p_complete,now(),now())
 on conflict(league_id) do update set nfl_state=excluded.nfl_state,detected_week=excluded.detected_week,season_type=excluded.season_type,is_scoring_period_complete=excluded.is_scoring_period_complete,last_checked_at=now(),updated_at=now();
 return jsonb_build_object('week',p_detected_week,'season_type',p_season_type,'complete',p_complete);
end; $$;
revoke all on function public.record_nfl_state(uuid,jsonb,int,text,boolean) from public;
grant execute on function public.record_nfl_state(uuid,jsonb,int,text,boolean) to authenticated;

create or replace function public.mark_engine_stats_synced(p_league_id uuid,p_week int)
returns void language plpgsql security definer set search_path=public as $$
declare v_user uuid:=auth.uid(); v_comm uuid; begin
 select commissioner_user_id into v_comm from public.leagues where id=p_league_id;
 if v_comm<>v_user then raise exception 'Commissioner access required.'; end if;
 update public.league_engine_state set last_stats_sync_at=now(),updated_at=now() where league_id=p_league_id;
end; $$;
revoke all on function public.mark_engine_stats_synced(uuid,int) from public;
grant execute on function public.mark_engine_stats_synced(uuid,int) to authenticated;

create or replace function public.mark_engine_scores_calculated(p_league_id uuid,p_week int)
returns void language plpgsql security definer set search_path=public as $$
declare v_user uuid:=auth.uid(); v_comm uuid; begin
 select commissioner_user_id into v_comm from public.leagues where id=p_league_id;
 if v_comm<>v_user then raise exception 'Commissioner access required.'; end if;
 update public.league_engine_state set last_scores_at=now(),updated_at=now() where league_id=p_league_id;
end; $$;
revoke all on function public.mark_engine_scores_calculated(uuid,int) from public;
grant execute on function public.mark_engine_scores_calculated(uuid,int) to authenticated;
