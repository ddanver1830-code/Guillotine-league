-- Guillotine weekly workflow hardening
-- Run this once in Supabase SQL Editor after weekly.sql.

create or replace function public.lock_lineup(p_league_id uuid, p_team_id uuid, p_week int)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_user uuid := auth.uid();
  v_comm uuid;
  v_count int;
begin
  if v_user is null then raise exception 'You must be signed in.'; end if;
  select commissioner_user_id into v_comm from public.leagues where id=p_league_id;
  if v_comm is null then raise exception 'League not found.'; end if;
  if not (exists(select 1 from public.teams where id=p_team_id and league_id=p_league_id and owner_user_id=v_user) or v_comm=v_user) then
    raise exception 'You do not control this team.';
  end if;
  select count(*) into v_count from public.lineups where league_id=p_league_id and team_id=p_team_id and week=p_week;
  if v_count = 0 then raise exception 'Set a lineup before locking it.'; end if;
  update public.lineups set locked=true where league_id=p_league_id and team_id=p_team_id and week=p_week;
  return jsonb_build_object('success',true,'week',p_week,'locked',true,'slots',v_count);
end;
$$;
revoke all on function public.lock_lineup(uuid,uuid,int) from public;
grant execute on function public.lock_lineup(uuid,uuid,int) to authenticated;
