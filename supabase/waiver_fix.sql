-- Guillotine League waiver processing hardening
-- Run after weekly.sql.
-- Fixes duplicate bid creation and makes FAAB processing deterministic.

create or replace function public.submit_waiver_bid(
  p_league_id uuid,
  p_team_id uuid,
  p_sleeper_id text,
  p_bid_amount int,
  p_priority int,
  p_week int
)
returns public.waiver_bids
language plpgsql
security definer
set search_path=public
as $$
declare
  v_bid public.waiver_bids;
  v_faab int;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  if not exists(
    select 1 from public.teams
    where id=p_team_id
      and league_id=p_league_id
      and owner_user_id=auth.uid()
      and alive
  ) and not public.is_commissioner(p_league_id) then
    raise exception 'You do not control this team.';
  end if;

  select faab into v_faab
  from public.teams
  where id=p_team_id and league_id=p_league_id;

  if not found then raise exception 'Team not found.'; end if;
  if not exists(select 1 from public.waiver_pool where league_id=p_league_id and sleeper_id=p_sleeper_id) then
    raise exception 'Player is not in the waiver pool.';
  end if;
  if p_bid_amount < 0 or p_bid_amount > v_faab then
    raise exception 'Bid must be between $0 and your available FAAB.';
  end if;
  if p_week not between 1 and 17 then raise exception 'Invalid week.'; end if;

  -- A team has one active bid per player per week. Re-submitting replaces it.
  delete from public.waiver_bids
  where league_id=p_league_id
    and team_id=p_team_id
    and sleeper_id=p_sleeper_id
    and week=p_week
    and processed_at is null;

  insert into public.waiver_bids(
    league_id,team_id,sleeper_id,bid_amount,priority,week
  ) values (
    p_league_id,p_team_id,p_sleeper_id,p_bid_amount,greatest(1,p_priority),p_week
  ) returning * into v_bid;

  return v_bid;
end;
$$;

revoke all on function public.submit_waiver_bid(uuid,uuid,text,int,int,int) from public;
grant execute on function public.submit_waiver_bid(uuid,uuid,text,int,int,int) to authenticated;

create or replace function public.process_waivers(p_league_id uuid,p_week int)
returns int
language plpgsql
security definer
set search_path=public
as $$
declare
  v_player record;
  v_bid record;
  v_faab int;
  v_count int := 0;
begin
  if not public.is_commissioner(p_league_id) then
    raise exception 'Commissioner access required.';
  end if;
  if p_week not between 1 and 17 then raise exception 'Invalid week.'; end if;

  -- Process players in descending top-bid order. This makes the result
  -- deterministic when a manager has submitted bids for multiple players
  -- and cannot afford to win all of them.
  for v_player in
    select wb.sleeper_id, max(wb.bid_amount) as top_bid
    from public.waiver_bids wb
    where wb.league_id=p_league_id
      and wb.week=p_week
      and wb.processed_at is null
    group by wb.sleeper_id
    order by max(wb.bid_amount) desc, wb.sleeper_id asc
  loop
    v_bid := null;

    -- Pick the highest currently affordable bid from a surviving team.
    -- Ties: lower priority number, then earlier submission, then bid id.
    select b.* into v_bid
    from public.waiver_bids b
    join public.teams t on t.id=b.team_id
    where b.league_id=p_league_id
      and b.week=p_week
      and b.sleeper_id=v_player.sleeper_id
      and b.processed_at is null
      and t.league_id=p_league_id
      and t.alive
      and b.bid_amount <= t.faab
    order by b.bid_amount desc,b.priority asc,b.submitted_at asc,b.id asc
    limit 1;

    if v_bid.id is null then
      -- Nobody can currently afford this player; close out all bids.
      update public.waiver_bids
      set processed_at=now()
      where league_id=p_league_id
        and week=p_week
        and sleeper_id=v_player.sleeper_id
        and processed_at is null;
      continue;
    end if;

    select faab into v_faab
    from public.teams
    where id=v_bid.team_id
    for update;

    if v_bid.bid_amount > v_faab then
      continue;
    end if;

    -- The player should only exist once in the league roster. Remove any
    -- stale waiver-pool copy before awarding the player.
    delete from public.roster_players
    where league_id=p_league_id and sleeper_id=v_player.sleeper_id;

    insert into public.roster_players(
      league_id,team_id,sleeper_id,acquired_week,acquired_via,roster_slot
    ) values (
      p_league_id,v_bid.team_id,v_player.sleeper_id,p_week,'waiver','BENCH'
    );

    update public.teams
    set faab=faab-v_bid.bid_amount
    where id=v_bid.team_id;

    delete from public.waiver_pool
    where league_id=p_league_id and sleeper_id=v_player.sleeper_id;

    update public.waiver_bids
    set processed_at=now()
    where league_id=p_league_id
      and week=p_week
      and sleeper_id=v_player.sleeper_id
      and processed_at is null;

    insert into public.audit_log(
      league_id,actor_user_id,action,details
    ) values (
      p_league_id,auth.uid(),'waiver_awarded',
      jsonb_build_object(
        'team_id',v_bid.team_id,
        'sleeper_id',v_player.sleeper_id,
        'bid',v_bid.bid_amount,
        'priority',v_bid.priority,
        'week',p_week
      )
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.process_waivers(uuid,int) from public;
grant execute on function public.process_waivers(uuid,int) to authenticated;
