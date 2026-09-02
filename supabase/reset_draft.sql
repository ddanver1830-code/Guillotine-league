-- Commissioner-only draft reset.
-- Clears draft picks, draft-created roster/lineup records, draft skips, and resets draft_state to setup.
create or replace function public.reset_draft(p_league_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_commissioner uuid;
begin
  if v_user is null then
    raise exception 'Authentication required.';
  end if;

  select commissioner_user_id into v_commissioner
  from public.leagues
  where id = p_league_id;

  if v_commissioner is null then
    raise exception 'League not found.';
  end if;

  if v_commissioner <> v_user then
    raise exception 'Commissioner access required.';
  end if;

  delete from public.lineups where league_id = p_league_id;
  delete from public.roster_players where league_id = p_league_id;
  delete from public.draft_picks where league_id = p_league_id;
  delete from public.draft_skips where league_id = p_league_id;

  update public.draft_state
  set status = 'setup',
      started_at = null,
      paused_at = null,
      pick_started_at = null,
      remaining_seconds = pick_seconds,
      timeout_pending = false,
      updated_at = now()
  where league_id = p_league_id;

  insert into public.draft_state (league_id, status, rounds, pick_seconds, remaining_seconds, timeout_pending, updated_at)
  select p_league_id, 'setup', 13, 90, 90, false, now()
  where not exists (select 1 from public.draft_state where league_id = p_league_id);

  insert into public.audit_log (league_id, actor_user_id, action, details)
  values (p_league_id, v_user, 'draft_reset', jsonb_build_object('message','Commissioner reset the draft to setup'));
end;
$$;

grant execute on function public.reset_draft(uuid) to authenticated;
