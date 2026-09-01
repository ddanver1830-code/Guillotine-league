-- FINAL RLS/Realtime completion script.
-- Run schema.sql first. If schema.sql stops at the old roster policy error,
-- run this file afterward. This file safely replaces the policies.

drop policy if exists leagues_member_read on public.leagues;
drop policy if exists teams_member_read on public.teams;
drop policy if exists teams_owner_update on public.teams;
drop policy if exists players_authenticated_read on public.players;
drop policy if exists roster_member_read on public.roster_players;
drop policy if exists roster_owner_write on public.roster_players;
drop policy if exists draft_member_read on public.draft_picks;
drop policy if exists scores_member_read on public.weekly_scores;
drop policy if exists waiver_member_read on public.waiver_pool;
drop policy if exists bids_owner_read on public.waiver_bids;
drop policy if exists bids_owner_write on public.waiver_bids;
drop policy if exists elim_member_read on public.eliminations;
drop policy if exists lineup_owner_all on public.lineups;
drop policy if exists nfl_stats_member_read on public.nfl_stats;
drop policy if exists audit_commissioner_read on public.audit_log;

create policy leagues_member_read on public.leagues for select using (public.is_league_member(id) or commissioner_user_id=auth.uid());
create policy teams_member_read on public.teams for select using (public.is_league_member(league_id) or owner_user_id=auth.uid());
create policy teams_owner_update on public.teams for update using (owner_user_id=auth.uid() or public.is_commissioner(league_id));
create policy players_authenticated_read on public.players for select to authenticated using (true);
create policy roster_member_read on public.roster_players for select using (public.is_league_member(league_id));
create policy roster_owner_write on public.roster_players for all using (exists(select 1 from public.teams t where t.id=team_id and t.owner_user_id=auth.uid()) or public.is_commissioner(league_id)) with check (exists(select 1 from public.teams t where t.id=team_id and t.owner_user_id=auth.uid()) or public.is_commissioner(league_id));
create policy draft_member_read on public.draft_picks for select using (public.is_league_member(league_id));
create policy scores_member_read on public.weekly_scores for select using (public.is_league_member(league_id));
create policy waiver_member_read on public.waiver_pool for select using (public.is_league_member(league_id));
create policy bids_owner_read on public.waiver_bids for select using (exists(select 1 from public.teams t where t.id=team_id and t.owner_user_id=auth.uid()) or public.is_commissioner(league_id));
create policy bids_owner_write on public.waiver_bids for insert with check (exists(select 1 from public.teams t where t.id=team_id and t.owner_user_id=auth.uid()) or public.is_commissioner(league_id));
create policy elim_member_read on public.eliminations for select using (public.is_league_member(league_id));
create policy lineup_owner_all on public.lineups for all using (exists(select 1 from public.teams t where t.id=team_id and t.owner_user_id=auth.uid()) or public.is_commissioner(league_id)) with check (exists(select 1 from public.teams t where t.id=team_id and t.owner_user_id=auth.uid()) or public.is_commissioner(league_id));
create policy nfl_stats_member_read on public.nfl_stats for select to authenticated using (true);
create policy audit_commissioner_read on public.audit_log for select using (public.is_commissioner(league_id));

-- Add tables to Realtime only when they are not already members of the publication.
do $$
declare t text;
begin
  foreach t in array array['leagues','teams','roster_players','draft_picks','weekly_scores','waiver_pool','waiver_bids','eliminations','lineups'] loop
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then
      execute format('alter publication supabase_realtime add table public.%I',t);
    end if;
  end loop;
end $$;
