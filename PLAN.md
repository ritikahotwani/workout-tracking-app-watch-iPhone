# Implementation Plan — Minimal Workout Tracker (watchOS + iOS)

Source requirements: `PROMPT.md`. This plan covers the data model, app structure, sync design, the 8 phases, tests, and how subagents will build it.

Environment found: Xcode 26.3, XcodeGen installed, iOS 26.3 simulator installed, **no watchOS simulator runtime installed** (needed to run the watch app; install via Xcode › Settings › Components or `xcodebuild -downloadPlatform watchOS`).

---

## 1. Repository layout

```
workout-tracker/
├── project.yml                     # XcodeGen spec → WorkoutTracker.xcodeproj (generated, committed)
├── Config/
│   ├── Shared.xcconfig             # #include? "Secrets.xcconfig"
│   ├── Secrets.example.xcconfig    # committed: SUPABASE_URL / SUPABASE_ANON_KEY placeholders
│   └── Secrets.xcconfig            # git-ignored
├── Packages/WorkoutCore/           # local SwiftPM package, shared by both apps, no UI
│   ├── Sources/WorkoutCore/
│   │   ├── Model/                  # SwiftData @Model entities + Syncable protocol
│   │   ├── Library/                # built-in exercise seed (JSON) + deterministic IDs
│   │   ├── Calc/                   # volume, e1RM, PRs, compare, moving average, units
│   │   ├── Sync/                   # DTOs (Codable), LWW merge, change tracking
│   │   └── CSV/                    # RFC-4180 parser/writer, SetGraph mapping, export
│   └── Tests/WorkoutCoreTests/     # `swift test` on macOS — fast, no simulator
├── iOS/                            # iPhone app target
│   ├── App/ (entry, ModelContainer, tab root)
│   ├── Features/ Library/ Routines/ Workout/ History/ Stats/ BodyWeight/ Settings/ Import/
│   └── Services/ PhoneConnectivity, HealthStore, SupabaseSync, Auth
├── Watch/                          # watchOS app target (single-target watch app)
│   ├── App/
│   ├── Features/ Start/ Session/ SetLogger/ Rest/ Cardio/ BodyWeight/
│   └── Services/ WorkoutManager (HK), WatchConnectivity, LocationRoute
├── supabase/migrations/            # 0001_schema.sql, 0002_rls.sql, 0003_triggers.sql
└── PLAN.md / PROMPT.md / README.md
```

Why a local package: all calculation, CSV and sync logic is pure Swift, testable in seconds with `swift test` (no simulator), and shared verbatim by watch + phone.

Dependencies: `supabase-swift` (iOS target only). XcodeGen is a dev tool, not a runtime dependency. Nothing else.

---

## 2. Data model

### 2.1 Common sync fields (every entity, local + Supabase)

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | client-generated, `@Attribute(.unique)` |
| `userID` | UUID? | nil until signed in; stamped on push |
| `createdAt` | Date | |
| `updatedAt` | Date | bumped on every local mutation; LWW key |
| `deletedAt` | Date? | soft delete; UI filters `deletedAt == nil` |
| `needsPush` | Bool | **local only** — dirty flag for the Supabase queue |

Foreign keys are stored as plain `UUID` columns (not SwiftData relationships). Reason: each row maps 1:1 to a Supabase row and a WatchConnectivity DTO, LWW is per-row, soft deletes don't fight cascade rules, and rows can arrive out of order during sync/restore without breaking.

Canonical units: **kg, meters, seconds**. Conversion only at display.

### 2.2 Entities

**Exercise** — `name`, `muscleGroup` (enum string: chest, back, shoulders, biceps, triceps, legs, glutes, core, fullBody, cardio, other), `kind` (`strength` | `cardio`), `cardioActivity` (HK activity: running, walking, cycling, rowing, elliptical, stairs, other; nil for strength), `isBuiltIn`, `defaultRestSeconds` (default 90), `nameKey` (lowercased, trimmed — for case-insensitive matching/import).
Built-in exercises use **deterministic UUIDv5(name)** so every device and every restore agrees on the same ID → no duplicates.

**Routine** — `name`, `sortOrder`.

**RoutineExercise** — `routineID`, `exerciseID`, `sortOrder`, `targetSets`, `targetReps`, `restSeconds?` (nil → exercise default).

**WorkoutSession** — `routineID?`, `startedAt`, `endedAt?`, `pausedSeconds`, `source` (`watch` | `phone` | `import`), `activeCalories?`, `avgHeartRate?`, `healthKitWorkoutID?`, `importKey?`.

**SessionExercise** — `sessionID`, `exerciseID`, `sortOrder`, `note?`.

**SetEntry** — `sessionExerciseID`, `sortOrder`, `weightKg?`, `reps?`, `distanceMeters?`, `durationSeconds?`, `restSeconds?` (actual rest taken after this set), `completedAt`, `importKey?`.
Pace and speed are **derived** from distance/duration, never stored.

**BodyWeightEntry** — `date`, `weightKg`, `healthKitSampleID?`, `source` (`app` | `health` | `import`).

**Local only (not synced to Supabase):** settings in `@AppStorage` (weight unit, distance unit, last backup time, last sync error, pull cursor). Units are pushed phone → watch via WatchConnectivity application context.

### 2.3 Supabase tables

One table per entity, snake_case: `exercises`, `routines`, `routine_exercises`, `workout_sessions`, `session_exercises`, `set_entries`, `body_weight_entries`. Each has the common columns plus:
- `server_updated_at timestamptz default now()` — set by trigger on every insert/update. Used **only** as the incremental pull cursor (client clocks can't be trusted for "what changed since my last pull").
- `BEFORE UPDATE` trigger **keep-newer**: if `NEW.updated_at < OLD.updated_at` return `OLD` → server enforces last-write-wins even with plain PostgREST upserts.
- Indexes: `(user_id, server_updated_at)` on every table; FK-ish indexes (`session_id`, `session_exercise_id`, `routine_id`).
- RLS enabled on every table; policies for select/insert/update with `user_id = auth.uid()` (no delete policy — soft deletes only).
- No hard FK constraints between tables (rows may arrive out of order; integrity is client-side).

---

## 3. Sync design

### 3.1 Watch ↔ iPhone (WatchConnectivity)

| Direction | Payload | Mechanism |
|---|---|---|
| Phone → Watch | exercises, routines, routine exercises, units, **per-exercise snapshot**: last session sets + PR baselines (heaviest, best e1RM, best reps per weight, best session volume) | `updateApplicationContext` (latest-state wins). If > context size limit, `transferFile` with JSON. |
| Watch → Phone | completed/changed sessions + their exercises + sets; body-weight entries | `transferUserInfo` (queued, survives offline/app termination) |
| Both | live "session started on other device" ping (optional, when reachable) | `sendMessage` |

Receiver applies DTOs through the same `LWWMerge` used for Supabase. Phone marks merged rows `needsPush = true` so they reach the cloud. The watch keeps its own SwiftData store (offline logging) and prunes history older than ~60 days; the phone-sent snapshot covers "last performance" and PR baselines beyond that.

### 3.2 iPhone ↔ Supabase

- **Auth:** Sign in with Apple (`AuthenticationServices`) → `supabase.auth.signInWithIdToken(.apple, idToken, nonce)`. Session persisted by the SDK (keychain).
- **Push:** for each table in dependency order, fetch `needsPush == true`, stamp `userID`, `upsert` in batches of 500, clear `needsPush` only for rows the server accepted.
- **Pull:** `select * where server_updated_at > cursor order by server_updated_at` per table, paged; apply LWW (`remote.updatedAt > local.updatedAt` → overwrite); advance cursor to max `server_updated_at` seen.
- **Order:** push then pull. Triggers: launch, foreground (`scenePhase`), workout end, manual "Back up now". Debounced, single-flight actor, runs off the main actor; UI never awaits it.
- **Offline queue:** the `needsPush` flag *is* the queue — survives relaunch, no separate outbox table. `NWPathMonitor` triggers a sync when connectivity returns.
- **Restore:** fresh install + sign-in with empty cursor = full pull into SwiftData. Built-in exercise IDs are deterministic so they merge instead of duplicating.
- **Errors:** mapped to plain language ("No internet — changes will back up later", "Signed out — sign in to back up", "Server rejected 3 changes", …) and shown in Settings with last successful backup time.

### 3.3 LWW rule (shared, unit-tested)

`apply(remote) → if local == nil: insert; else if remote.updatedAt > local.updatedAt: overwrite (incl. deletedAt); else: keep local`. Ties keep local. Soft-deletes are just a newer `updatedAt` with `deletedAt` set.

---

## 4. HealthKit & location

- **Watch workout:** `HKWorkoutSession` + `HKLiveWorkoutBuilder` with `HKLiveWorkoutDataSource`. Live HR + active energy via builder delegate. Pause/resume map to session pause/resume. End → `endCollection` → `finishWorkout`; store `healthKitWorkoutID`.
- **Activity type:** strength sessions use `.traditionalStrengthTraining`. Cardio exercises within a session use HK workout activities (`beginNewActivity` / `endCurrentActivity`) with the exercise's `cardioActivity` type and indoor/outdoor location type. *(Open question Q2.)*
- **iPhone-started session:** iOS 26 supports `HKWorkoutSession` on iPhone — same `WorkoutManager` API, built for both platforms.
- **Outdoor cardio GPS (watch):** `CLLocationManager` (fitness activity) → `HKWorkoutRouteBuilder`; distance from builder statistics (`distanceWalkingRunning` / `distanceCycling`) with location fallback; live pace & speed. Indoor: manual distance entry (Digital Crown).
- **Body weight:** read via `HKAnchoredObjectQuery` on `bodyMass` (persist anchor) → upsert `BodyWeightEntry` by `healthKitSampleID`; in-app entry writes an `HKQuantitySample` and stores its UUID (no echo duplicates). Deleting in-app deletes the sample we wrote.
- Entitlements/Info.plist: HealthKit (both), background mode `workout-processing` (watch), location when-in-use (watch), Sign in with Apple (iOS).

---

## 5. Calculations (WorkoutCore/Calc — all unit-tested)

- `volume(set) = weightKg × reps` for strength sets; session / per-exercise / per-ISO-week sums.
- `e1RM(w, r) = r == 1 ? w : w × (1 + r/30)`; nil when reps ≤ 0 or weight ≤ 0.
- PRs per exercise, computed from history:
  1. heaviest weight (any reps)
  2. best e1RM
  3. best reps at each weight (weight key = kg rounded to 0.01)
  4. highest single-session volume
- `PRDetector.check(newSet, baseline) → [PRType]` — used live on watch with the phone-sent baseline merged with today's sets.
- Compare: current vs previous session of same routine (or same exercise): volume, top set, e1RM deltas.
- Workout counts: total, per ISO week, per month.
- Body weight 7-day moving average (calendar-day based, gaps handled).
- Units: kg↔lb (0.45359237), m↔km/mi (1609.344); pace (sec/km or sec/mi), speed (km/h or mph).

---

## 6. UI structure

**iPhone (TabView, dark-first, single accent color):**
1. **Workout** — start empty or from routine; live session screen (same model as watch); history list → session detail.
2. **Progress** — totals, weekly volume chart, per-exercise e1RM chart, PR list, compare.
3. **Body** — quick weight entry, trend chart (7-day MA, 1M/3M/1Y/All).
4. **Library** — exercises by muscle group (+ custom), routines (create/edit/reorder via `List` + `onMove`).
5. **Settings** — units, Sign in with Apple, Back up now, last backup + error text, Import SetGraph CSV, Export CSV.

**Watch (shallow, big targets):**
- Start: routine list + "Empty workout" + "Log weight".
- Session (vertical `TabView` pages): **Current exercise** (big weight/reps values, Digital Crown on focused value, giant "Log Set" button, last-session line under it, PR badge) · **Metrics** (elapsed, HR, kcal) · **Controls** (pause/end, add exercise, note via dictation).
- Rest overlay: countdown ring auto-starts after log; haptic at zero; "skip" records actual rest.

### 6.1 Accessibility: VoiceOver for live tracking (watch and iPhone)

The goal: a VoiceOver user can run a whole session (start, log sets, rest, PRs, end) without seeing the screen.

**Set logging**
- Weight and reps steppers are `accessibilityAdjustableAction` elements. Swipe up/down (or turn the Crown on watch) changes the value by one increment, and VoiceOver reads it in the display unit: "Weight, 80 kilograms, adjustable". Each element has one label + value, not separate digit/unit fragments.
- The "Log Set" button's label says what will be logged: "Log set 3: 80 kilograms, 8 reps".
- After a set is logged, `AccessibilityNotification.Announcement`: "Set 3 logged. Rest 90 seconds."
- PR hit: the announcement includes it ("New personal record: heaviest weight, 85 kilograms") alongside the haptic, so the badge isn't visual-only.
- Last-session line reads as a sentence: "Last time: 3 sets, 8 reps at 77.5 kilograms".
- Cardio fields: "Distance, 5.2 kilometers", "Pace, 5 minutes 30 seconds per kilometer" (spelled out with `Duration.formatted(.units(width: .wide))`, never "5:30").

**Rest timer**
- Countdown element value: "1 minute 10 seconds remaining". It does not re-announce every second.
- Spoken announcements at 10 seconds left and at zero ("Rest over"), plus the haptic. "Skip rest" is a labeled button.

**Session & navigation**
- Metrics page groups into one element: "Elapsed 42 minutes, heart rate 128, 310 calories" (`accessibilityElement(children: .combine)`).
- Vertical session pages have labels ("Current exercise: Bench Press, set 3 of 4", "Metrics", "Controls"). Pause/End have clear labels, and End needs a confirmation that VoiceOver also reads.
- Exercise switching in a session: an "Exercise 2 of 5: Incline Press" rotor-friendly list, and `accessibilityAction(named: "Next exercise")` on the current-exercise view.
- Logical focus order: exercise name → last time → weight → reps → Log Set.

**Charts & history**
- Each Swift Chart gets an `AXChartDescriptor` (audio graph + summary like "Estimated 1RM rose from 90 to 102 kilograms over 3 months").
- History rows read "Chest Day, Tuesday 18 November, 52 minutes, 14 sets, volume 6,200 kilograms".

**Also:** Dynamic Type via system text styles everywhere (the watch's big value text uses `.largeTitle` scaling with `minimumScaleFactor`), contrast checked on the dark theme, and no information carried by color alone (PRs get a badge icon + text).

**Verification:** an `accessibilityAudit()` UI test on the iPhone set-logger and history screens, plus a manual VoiceOver pass on watch at the end of Phases 2, 4 and 8 (listed in each phase's demo notes).

---

## 7. Phases & deliverables

Each phase ends with: build both targets green, `swift test` green, short demo notes. Each phase is one commit (once you OK committing).

| # | Phase | Deliverables | Demo |
|---|---|---|---|
| 0 | **Scaffold** | `project.yml` with all targets, entitlements, Info.plist keys, xcconfigs, `.gitignore`; WorkoutCore package with all models, sync fields, Calc, Units + tests | Both apps launch to empty shells; tests pass |
| 1 | Library + routines (iPhone) | seed ~80 built-in exercises; library browse/search/add custom; routines CRUD + reorder; default rest per exercise | Create "Chest Day" with 4 exercises |
| 2 | Watch live session | `WorkoutManager` (HK), start empty/routine, set logger with Crown + prefill, rest timer + haptic + actual rest, last performance line, notes, PR badge + haptic (local baseline), pause/end | Log a full session on watch; appears in Health |
| 3 | Watch ↔ iPhone sync | `PhoneConnectivity` / `WatchConnectivityService`, DTOs, LWW apply, snapshot (routines, exercises, last perf, PR baselines, units) | Routine made on phone appears on watch; watch session appears on phone |
| 4 | History, stats, PRs, charts | history list + detail; totals; volume charts; e1RM chart; PR list; compare view; iPhone live session screen | Charts populated from logged sessions |
| 5 | Body weight + Health | entry on both devices; anchored query import; write to Health; trend chart + MA + ranges | Weight from Health app shows in app and vice versa |
| 6 | Supabase | SQL migrations; Sign in with Apple; `SyncEngine` push/pull/restore; triggers; Settings status; **dashboard setup instructions + Secrets values for you** | Delete app, reinstall, sign in → data restored |
| 7 | SetGraph import + CSV export | **ask for sample → propose mapping → your confirmation → importer**; preview + error report; idempotent via `importKey`; CSV export via share sheet | Import your history; PRs/charts reflect it |
| 8 | Cardio GPS | route builder, live distance/pace/speed, indoor manual distance, cardio logging UI | Outdoor run logged with route in Health |

### Tests (WorkoutCoreTests, Swift Testing)
volume · e1RM (incl. reps = 1, zero/negative) · each of the 4 PR types + live detector · kg/lb, km/mi, pace/speed · CSV parser (quotes, commas, newlines in fields, BOM, bad rows reported) · SetGraph mapping · export round-trip · LWW (newer remote wins, older loses, tie keeps local, soft delete propagates) · moving average.
iOS/watch targets get a small test bundle only where logic can't live in the package (sync engine with a fake Supabase client).

---

## 8. Subagent execution plan

Parallel agents share one working tree but touch **disjoint directories**; `project.yml` is written once in Phase 0 with source globs so later agents only add files. Each agent builds with its own `-derivedDataPath` to avoid collisions. I review every agent's diff, run the full build + tests between waves, and fix integration seams myself.

| Wave | Agents (parallel) | Depends on |
|---|---|---|
| A | **Scaffold agent** — Phase 0 | approval |
| B | **iPhone-library agent** (Phase 1, `iOS/Features/Library,Routines`) · **Watch-session agent** (Phase 2, `Watch/`) · **Supabase-schema agent** (Phase 6 SQL + sync engine core w/ fake client, `supabase/`, `WorkoutCore/Sync`) | A |
| C | **Connectivity agent** (Phase 3) · **Stats agent** (Phase 4, `iOS/Features/History,Stats,Workout`) · **Body-weight agent** (Phase 5) | B |
| D | **Supabase-wiring agent** (Phase 6 auth + SyncEngine + Settings) · **Cardio-GPS agent** (Phase 8, `Watch/Features/Cardio`, `Watch/Services/LocationRoute`) | C (+ Supabase project for live test) |
| E | **Import/export agent** (Phase 7) | your CSV sample + confirmed mapping |
| F | **Review agent** (fresh eyes: correctness, RLS, sync edge cases) → fixes | E |

Each agent brief contains: this plan's relevant sections, the exact files/dirs it owns, the model/DTO contracts it must not change unilaterally, acceptance criteria, and the build/test commands.

---

## 9. Decisions & open items

Decided:
- **Mixed sessions: yes.** One `HKWorkoutSession` (strength), with each cardio exercise recorded as an HK workout activity inside it.
- **Bodyweight exercises:** only added weight is logged (0 when unweighted), so unweighted sets add 0 to volume and e1RM.
- **Git:** commit and push to `origin` (github.com/ritikahotwani/workout-tracking-app-watch-iPhone) after each phase.
- Defaults: Monday week start, 90 s default rest, warm-up sets not distinguished.

Open:
1. **Approval** of this data model + structure.
2. **SetGraph sample CSV**: needed before Phase 7.
3. **watchOS simulator runtime**: the CLI download failed (Apple server: "bad request"). Install it from Xcode › Settings › Components › watchOS 26. Until then watch code is compile-checked only.
