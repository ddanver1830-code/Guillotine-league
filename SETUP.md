# Guillotine League Manager — Live Setup

The GitHub repository is ready. The remaining connection step is to initialize the Supabase database and provide the browser-safe Supabase `anon` key.

## 1. Open your Supabase project
Project: https://unmahnndjtljktvrupkh.supabase.co/

Open **SQL Editor** and run `supabase/schema.sql`.

If that script reports an error around the roster RLS policy, that is expected from the first draft of the schema. Then run `supabase/complete.sql`; it replaces the policies safely and enables Realtime.

## 2. Get the public anon key
In Supabase, open **Project Settings → API**. Copy the **anon / publishable public key**. Do NOT copy the `service_role` or secret key.

Put that public key into `config.js` where the placeholder appears.

## 3. Authentication
In Supabase, open **Authentication → Providers** and enable Email/password. Managers will use individual accounts so private FAAB bids remain private.

## 4. GitHub Pages
The repository contains `index.html`. Enable GitHub Pages for the `main` branch under the repository's **Settings → Pages**. GitHub will provide the public website address.

## 5. Important
The current `index.html` is the working prototype UI. The database schema is prepared for the full shared version, including teams, rosters, lineups, draft picks, private waiver bids, weekly scores, eliminations, player metadata, NFL stats, audit logging, and Realtime.

The production live-data layer still needs to be wired to the Supabase tables and a scheduled stats/player-data job. Do not expose any Supabase secret/service-role key in GitHub Pages.
