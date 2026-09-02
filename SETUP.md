# Guillotine League — Final Launch

The app is built for the 18-team 2026 Guillotine / Survivor league.

## What is ready

- 18 teams
- Manager-specific join links and manager portal
- 17-week Guillotine format
- Lowest surviving score eliminated each week
- Eliminated roster released to the blind FAAB waiver pool
- $100 starting FAAB
- No trades
- Season-long points tiebreaker
- Week-based roster changes
- Snake draft with 90-second pick clock
- Draft pause/resume/reset controls
- Manager lineup management
- Live scores and standings
- Commissioner weekly control center
- Realtime league updates

## One remaining live-database activation

The browser app cannot create PostgreSQL functions by itself. The live Supabase project must execute the repository's final activation migration once.

Use **`supabase/final_activation.sql`** after the base database files are already installed. It activates the draft reset function, hardened private FAAB bidding/processing, and the final Realtime safety checks in one migration.

This is the only remaining database activation required for the final features. Do not expose a Supabase service-role or secret key in the website.

## Launch order

1. Activate `supabase/final_activation.sql` in the live Supabase project.
2. Open Commissioner Dashboard.
3. Open League Launch Center and verify the live league connection.
4. Open Draft Control and confirm the draft is in Setup.
5. Share the manager portal for league code **HO441Q**.
6. Have all 18 managers claim their assigned teams and mark ready.
7. Set the draft date/rounds/timer and start the draft.
8. After the draft, managers set and lock weekly lineups.
9. Commissioner runs the weekly workflow: lock → sync/calculate → confirm elimination → release roster → FAAB → advance.

## Important

The app code is hosted from GitHub Pages and uses only the browser-safe Supabase publishable key. The database migration is intentionally separate because GitHub Pages cannot securely execute privileged PostgreSQL DDL.
