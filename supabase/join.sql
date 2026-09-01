-- Run after install.sql.
-- Lets an authenticated manager claim exactly one open team from a league code.
create or replace function public.claim_team(p_code text, p_team_number int, p_manager_name text)
returns public.teams
language plpgsql
security definer
set search_path=public
as $$
declare
  v_team public.teams;
  v_league public.leagues;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if trim(coalesce(p_manager_name,'')) = '' then raise exception 'Manager name is required.'; end if;
  select * into v_league from public.leagues where upper(code)=upper(trim(p_code)) for update;
  if not found then raise exception 'League code not found.'; end if;
  select * into v_team from public.teams where league_id=v_league.id and team_number=p_team_number for update;
  if not found then raise exception 'Team not found.'; end if;
  if v_team.owner_user_id is not null then raise exception 'That team has already been claimed.'; end if;
  if exists(select 1 from public.teams where league_id=v_league.id and owner_user_id=auth.uid()) then raise exception 'You already have a team in this league.'; end if;
  update public.teams set owner_user_id=auth.uid(), manager_name=trim(p_manager_name) where id=v_team.id returning * into v_team;
  return v_team;
end;
$$;
revoke all on function public.claim_team(text,int,text) from public;
grant execute on function public.claim_team(text,int,text) to authenticated;
