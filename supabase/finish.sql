-- If you already ran schema.sql, run this immediately afterward.
-- It repairs the roster RLS policy and completes the remaining policies/realtime setup.
drop policy if exists roster_owner_write on public.roster_players;
create policy roster_owner_write on public.roster_players for all using (
  exists(select 1 from public.teams t where t.id=team_id and t.owner_user_id=auth.uid())
  or public.is_commissioner(league_id)
) with check (
  exists(select 1 from public.teams t where t.id=team_id and t.owner_user_id=auth.uid())
  or public.is_commissioner(league_id)
);

create policy if not exists draft_member_read on public.draft_picks for select using (public.is_league_member(league_id));
create policy if not exists scores_member_read on public.weekly_scores for select using (public.is_league_member(league_id));
create policy if not exists waiver_member_read on public.waiver_pool for select using (public.is_league_member(league_id));
create policy if not exists bids_owner_read on public.waiver_bids for select using (exists(select 1 from public.teams t where t.id=team_id and t.owner_user_id=auth.uid()) or public.is_commissioner(league_id));
create policy if not exists bids_owner_write on public.waiver_bids for insert with check (exists(select 1 from public.teams t where t.id=team_id and t.owner_user_id=auth.uid()) or public.is_commissioner(league_id));
create policy if not exists elim_member_read on public.eliminations for select using (public.is_league_member(league_id));
create policy if not exists lineup_owner_all on public.lineups for all using (exists(select 1 from public.teams t where t.id=team_id and t.owner_user_id=auth.uid()) or public.is_commissioner(league_id)) with check (exists(select 1 from public.teams t where t.id=team_id and t.owner_user_id=auth.uid()) or public.is_commissioner(league_id));
create policy if not exists nfl_stats_member_read on public.nfl_stats for select to authenticated using (true);
create policy if not exists audit_commissioner_read on public.audit_log for select using (public.is_commissioner(league_id));

alter publication supabase_realtime add table public.leagues;
alter publication supabase_realtime add table public.teams;
alter publication supabase_realtime add table public.roster_players;
alter publication supabase_realtime add table public.draft_picks;
alter publication supabase_realtime add table public.weekly_scores;
alter publication supabase_realtime add table public.waiver_pool;
alter publication supabase_realtime add table public.waiver_bids;
alter publication supabase_realtime add table public.eliminations;
alter publication supabase_realtime add table public.lineups;
