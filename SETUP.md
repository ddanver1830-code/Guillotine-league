# Guillotine League Manager — Live Setup

The GitHub repository is ready. The remaining connection step is to initialize the Supabase database and provide the browser-safe Supabase `anon` key.

## 1. Open your Supabase project
Project: https://unmahnndjtljktvrupkh.supabase.co/

Open **SQL Editor** and run `supabase/schema.sql`.

If that script reports an error around the roster RLS policy, that is expected from the first draft of the schema. Then run `supabase/complete.sql`; it replaces the policies safely and enables Realtime.

For the Guillotine FAAB workflow, also run `supabase/waiver_fix.sql` after `weekly.sql`. This hardens one-active-bid-per-player behavior and makes waiver awards deterministic when a manager bids on multiple players.

## 2. Get the public anon key
In Supabase, open **Project Settings → API**. Copy the **anon / publishable public key**. Do NOT copy the `service_role` or secret key.

Put that public key into `config.js` where the placeholder appears.

## 3. Authentication
In Supabase, open **Authentication → Providers** and enable Email/password. Managers will use individual accounts so private FAAB bids remain private.

## 4. GitHub Pages
The repository contains `index.html`. Enable GitHub Pages for the `main` branch under the repository's **Settings → Pages**. GitHub will provide the public website address.

## 5. Weekly Guillotine workflow
The commissioner workflow is intentionally staged:

1. Lock completed-week lineups.
2. Sync final NFL stats and calculate surviving-team scores.
3. Review the lowest-scoring surviving team and explicitly confirm elimination.
4. The eliminated team's entire roster enters the waiver pool.
5. Managers submit blind FAAB bids.
6. Commissioner processes waivers; highest valid bid wins, with priority and submission time resolving ties.
7. Winning bid amounts are deducted from FAAB and players are added to the winning team's bench.
8. Commissioner advances the league to the next week.

The elimination confirmation is irreversible by design.

## 6. Important
The database schema is prepared for the full shared version, including teams, rosters, lineups, draft picks, private waiver bids, weekly scores, eliminations, player metadata, NFL stats, audit logging, and Realtime.

Do not expose any Supabase secret/service-role key in GitHub Pages.
