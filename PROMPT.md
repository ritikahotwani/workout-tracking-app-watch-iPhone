# Build: Minimal Workout Tracker for Apple Watch + iPhone

## Context
I lift and do cardio, and I've tracked my training for years in SetGraph. Its UI is cluttered and hard to use, so I want my own app that is beautifully minimal and fast to log with. I own an Apple Watch SE 3. I'll import my SetGraph history (CSV) into the new app.

## Platforms & stack
- **watchOS app** (primary for live logging) + **iOS companion app** (setup, import, history, charts, cloud backup).
- Swift + SwiftUI, target watchOS 26 / iOS 26.
- Swift Charts for all charts.
- Dependencies: only the official `supabase-swift` SDK (Swift Package Manager). Nothing else unless clearly justified.

## Data & sync architecture (local-first)
- **SwiftData on both devices is the source of truth for the UI.** The app must work fully offline; gyms often have no signal.
- **Watch ↔ iPhone:** WatchConnectivity. The watch logs offline and syncs to the iPhone when reachable. The watch never talks to Supabase directly.
- **iPhone ↔ Supabase (free tier) = cloud backup and restore:**
  - Auth: Sign in with Apple via Supabase Auth.
  - Row-level security on every table: users can only read/write rows where `user_id = auth.uid()`.
  - Every record has a client-generated UUID `id`, `user_id`, `created_at`, `updated_at`, `deleted_at` (soft delete).
  - Conflicts: last-write-wins on `updated_at`.
  - Sync triggers: app launch, app foreground, workout end, manual "Back up now" in Settings. Queue changes made offline and push them when back online; never block the UI on network.
  - **Restore:** on a fresh install, after sign-in, pull all data from Supabase into SwiftData.
  - Settings shows last successful backup time and sync errors in plain language.
  - Put the Supabase schema in the repo as SQL migration files (tables, indexes, RLS policies).
  - Config: Supabase project URL + anon key loaded from a git-ignored `Secrets.xcconfig`; commit a `Secrets.example.xcconfig`. Never use or request the `service_role` key.
- **CSV export** from the iPhone as an additional manual backup.

## HealthKit
- Run every workout as an `HKWorkoutSession` + `HKLiveWorkoutBuilder` on the watch (heart rate, active calories, keeps app foregrounded, saves to Health/Activity rings).
- **Body weight:** read from and write to Apple Health (`bodyMass`). Logging weight in-app writes to Health; weight entries from Health show up in-app.
- **Outdoor cardio:** watch GPS (`HKWorkoutRouteBuilder` / CoreLocation) for distance, pace and speed. Indoor cardio (treadmill etc.) allows manual distance entry.

## Units
- Settings toggle: kg/lb and km/mi. Store canonically in kg and meters; convert only for display.

## Features

### Workout session (watch-first, also startable on iPhone)
- Start / pause / end a session; show elapsed time, heart rate, calories.
- Start from a **routine** (e.g. "Chest Day", "Back Day") or an empty session.
- Log each set: **weight, reps**. Pre-fill with the last session's values for that exercise so logging is usually one tap. Use the Digital Crown to adjust values.
- **Rest timer:** auto-starts the moment a set is logged; per-exercise default rest duration (editable); haptic when rest ends; actual rest time is recorded.
- Cardio exercises log **distance, duration, pace, speed**.
- Add a **note** to any exercise within a session.
- While logging an exercise, show **last session's performance** for it (sets × reps × weight).

### Routines
- Create/edit/reorder routines (named day templates with an ordered exercise list and default sets/reps/rest). Managed primarily on iPhone, synced to the watch.

### Exercise library
- Built-in list of common exercises grouped by muscle group, each typed as **strength** or **cardio**.
- Users can add custom exercises. Exercises from the SetGraph import are auto-added (matched by name, case-insensitive).

### Body weight
- Quick daily body-weight entry (watch and iPhone), synced with Health.
- Trend chart with a 7-day moving average and range selection (1M / 3M / 1Y / All).

### Progress & stats (iPhone)
- **Workout history:** chronological list → tap for full session detail.
- **Total workouts completed** (overall and per week/month).
- **Training volume** = Σ(weight × reps) for strength sets; per session, per exercise, and per week.
- **Strength progress:** per-exercise chart of estimated 1RM over time.
- **Compare:** current session vs previous session of the same routine/exercise (volume, top set, e1RM deltas).
- **Personal records**, tracked per exercise:
  1. Heaviest weight lifted (any reps)
  2. Best estimated 1RM, Epley: `weight × (1 + reps / 30)` (reps = 1 → weight)
  3. Best reps at each specific weight
  4. Highest single-session volume for the exercise
- Subtle PR badge + haptic when a PR is hit during a live session.

### SetGraph import (iPhone)
- Import a SetGraph CSV export via the Files picker.
- **Before writing the importer, ask me for a sample file, inspect its columns, and propose the mapping to me for confirmation.**
- Idempotent (re-importing the same file doesn't duplicate data), shows a preview/summary before committing, and reports unparseable rows instead of silently dropping them.
- Imported history feeds all stats, charts and PRs exactly like native data, and is backed up to Supabase like any other data.

## Design
- Aesthetically minimal: generous whitespace, one accent color, SF system fonts, clear hierarchy, no clutter. Dark mode first.
- Watch UX optimized for mid-set use: big tap targets, shallow navigation, "log set" always one tap away.
- Support Dynamic Type and VoiceOver basics.

## How to work
1. Propose the data model (SwiftData entities, matching Supabase tables) and app structure first; wait for my approval.
2. Build in phases, each runnable and demoable:
   1. Data model + exercise library + routines (iPhone)
   2. Watch live workout session (HealthKit, logging, rest timer, previous performance)
   3. Watch ↔ iPhone sync (WatchConnectivity)
   4. History, stats, PRs, charts
   5. Body weight + Health sync
   6. Supabase: schema + RLS migrations, Sign in with Apple, backup/restore sync
   7. SetGraph CSV import + CSV export
   8. Cardio GPS tracking
3. Unit tests for calculation and sync logic: volume, e1RM, all four PR types, unit conversion, CSV parsing, last-write-wins conflict resolution.
4. When you reach phase 6, tell me exactly what to set up in the Supabase dashboard (project, Apple auth provider) and which values to put in `Secrets.xcconfig`.
5. Ask me whenever a requirement is ambiguous instead of guessing.
