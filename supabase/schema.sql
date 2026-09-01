-- Guillotine League Manager database schema
-- Run this file in the Supabase SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.leagues (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'Guillotine League',
  code text not null unique,
  season int not null default 2026,
  commissioner_user_id uuid,
  current_week int not null default 1 check (current_week between 1 and 17),
  status text not null default 'setup' check (status in ('setup','active','complete')),
  settings jsonb not null default jsonb_build_object(
    'team_count',18,'weeks',17,'starting_faab',100,'trades',false,
    'tiebreaker','lower season-long points',
    'scoring',jsonb_build_object('pass_td',4,'pass_yd',0.04,'int',-2,'rush_yd',0.1,'rush_td',6,'rec',0.5,'rec_yd',0.1,'rec_td',6,'fumble',-2)
  ),
  created_at timestamptz not null default now()
);

create table if not exists public.teams (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  team_number int not null,
  name text not null,
  manager_name text,
  owner_user_id uuid,
  faab int not null default 100 check (faab >= 0),
  alive boolean not null default true,
  elimination_week int,
  created_at timestamptz not null default now(),
  unique(league_id, team_number),
  unique(league_id, name)
);

create table if not exists public.players (
  sleeper_id text primary key,
  name text not null,
  first_name text,
  last_name text,
  position text,
  nfl_team text,
  status text,
  injury_status text,
  metadata jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists public.roster_players (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  team_id uuid not null references public.teams(id) on delete cascade,
  sleeper_id text not null references public.players(sleeper_id),
  acquired_week int,
  acquired_via text not null default 'draft' check (acquired_via in ('draft','waiver','free_agent','commissioner')),
  roster_slot text,
  is_ir boolean not null default false,
  created_at timestamptz not null default now(),
  unique(league_id, sleeper_id)
);

create table if not exists public.draft_picks (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  round int not null,
  pick_number int not null,
  team_id uuid not null references public.teams(id) on delete cascade,
  sleeper_id text references public.players(sleeper_id),
  player_name text,
  position text,
  created_at timestamptz not null default now(),
  unique(league_id, pick_number)
);

create table if not exists public.weekly_scores (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  team_id uuid not null references public.teams(id) on delete cascade,
  week int not null check (week between 1 and 17),
  points numeric(10,2) not null default 0,
  locked boolean not null default false,
  calculated_at timestamptz not null default now(),
  unique(league_id, team_id, week)
);

create table if not exists public.waiver_pool (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  sleeper_id text not null references public.players(sleeper_id),
  source_team_id uuid references public.teams(id),
  released_week int,
  created_at timestamptz not null default now(),
  unique(league_id, sleeper_id)
);

create table if not exists public.waiver_bids (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  team_id uuid not null references public.teams(id) on delete cascade,
  sleeper_id text not null references public.players(sleeper_id),
  bid_amount int not null check (bid_amount >= 0),
  priority int not null default 1,
  week int not null check (week between 1 and 17),
  submitted_at timestamptz not null default now(),
  processed_at timestamptz
);

create table if not exists public.eliminations (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  team_id uuid not null references public.teams(id) on delete cascade,
  week int not null check (week between 1 and 17),
  score numeric(10,2) not null,
  tiebreak_points numeric(10,2) not null default 0,
  created_at timestamptz not null default now(),
  unique(league_id, week)
);

create table if not exists public.lineups (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  team_id uuid not null references public.teams(id) on delete cascade,
  week int not null check (week between 1 and 17),
  sleeper_id text not null references public.players(sleeper_id),
  slot text not null,
  locked boolean not null default false,
  unique(league_id, team_id, week, slot)
);

create table if not exists public.nfl_stats (
  sleeper_id text not null references public.players(sleeper_id),
  week int not null check (week between 1 and 18),
  season int not null,
  stats jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (sleeper_id, season, week)
);

create table if not exists public.audit_log (
  id uuid primary key default gen_random_uuid(),
  league_id uuid references public.leagues(id) on delete cascade,
  actor_user_id uuid,
  action text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_teams_league on public.teams(league_id);
create index if not exists idx_roster_league_team on public.roster_players(league_id,team_id);
create index if not exists idx_scores_league_week on public.weekly_scores(league_id,week);
create index if not exists idx_bids_league_week on public.waiver_bids(league_id,week);
create index if not exists idx_lineups_league_week on public.lineups(league_id,week);

alter table public.leagues enable row level security;
alter table public.teams enable row level security;
alter table public.players enable row level security;
alter table public.roster_players enable row level security;
alter table public.draft_picks enable row level security;
alter table public.weekly_scores enable row level security;
alter table public.waiver_pool enable row level security;
alter table public.waiver_bids enable row level security;
alter table public.eliminations enable row level security;
alter table public.lineups enable row level security;
alter table public.nfl_stats enable row level security;
alter table public.audit_log enable row level security;

-- Helper functions keep RLS policies readable.
create or replace function public.is_league_member(p_league_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.teams t where t.league_id=p_league_id and t.owner_user_id=auth.uid());
$$;
create or replace function public.is_commissioner(p_league_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.leagues l where l.id=p_league_id and l.commissioner_user_id=auth.uid());
$$;

create policy leagues_member_read on public.leagues for select using (public.is_league_member(id) or commissioner_user_id=auth.uid());
create policy teams_member_read on public.teams for select using (public.is_league_member(league_id) or owner_user_id=auth.uid());
create policy teams_owner_update on public.teams for update using (owner_user_id=auth.uid() or public.is_commissioner(league_id));
create policy players_authenticated_read on public.players for select to authenticated using (true);
create policy roster_member_read on public.roster_players for select using (public.is_league_member(league_id));
create policy roster_owner_write on public.roster_players for all using (owner_user_id=auth.uid() or public.is_commissioner(league_id)) with check (public.is_league_member(league_id) or public.is_commissioner(league_id));
create policy draft_member_read on public.draft_picks for select using (public.is_league_member(league_id));
create policy scores_member_read on public.weekly_scores for select using (public.is_league_member(league_id));
create policy waiver_member_read on public.waiver_pool for select using (public.is_league_member(league_id));
create policy bids_owner_read on public.waiver_bids for select using (exists(select 1 from public.teams t where t.id=team_id and t.owner_user_id=auth.uid()) or public.is_commissioner(league_id));
create policy bids_owner_write on public.waiver_bids for insert with check (exists(select 1 from public.teams t where t.id=team_id and t.owner_user_id=auth.uid()) or public.is_commissioner(league_id));
create policy elim_member_read on public.eliminations for select using (public.is_league_member(league_id));
create policy lineup_owner_all on public.lineups for all using (exists(select 1 from public.teams t where t.id=team_id and t.owner_user_id=auth.uid()) or public.is_commissioner(league_id)) with check (exists(select 1 from public.teams t where t.id=team_id and t.owner_user_id=auth.uid()) or public.is_commissioner(league_id));
create policy nfl_stats_member_read on public.nfl_stats for select to authenticated using (true);
create policy audit_commissioner_read on public.audit_log for select using (public.is_commissioner(league_id));

-- Realtime publication for live league updates.
alter publication supabase_realtime add table public.leagues;
alter publication supabase_realtime add table public.teams;
alter publication supabase_realtime add table public.roster_players;
alter publication supabase_realtime add table public.draft_picks;
alter publication supabase_realtime add table public.weekly_scores;
alter publication supabase_realtime add table public.waiver_pool;
alter publication supabase_realtime add table public.waiver_bids;
alter publication supabase_realtime add table public.eliminations;
alter publication supabase_realtime add table public.lineups;
