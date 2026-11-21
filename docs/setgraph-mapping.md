# SetGraph import mapping (confirmed by user 2026-11-21)

Two files from SetGraph's export, both UTF-8 (may have a BOM), comma-separated, dates `yyyy-MM-dd HH:mm:ss` in local time (no zone). Parse dates in `TimeZone.current`.

## Sets file: `Setgraph_Set_Export_*.csv`
Header: `Exercise,Date,Repetitions,Weight (lb),Weight (kg),Duration (seconds),Duration (formatted),Note,Label`

| Column | Use |
|---|---|
| Exercise | exercise name → match (see below) |
| Date | `SetEntry.completedAt` |
| Repetitions | `reps` (written as `10.0`; must be a whole number ≥ 0, else row is an error) |
| Weight (kg) | `weightKg`. `0` stays 0 (assisted/bodyweight). Empty → nil (reps-only). Ignore `Weight (lb)` (redundant). If kg is empty but lb is set, convert lb. |
| Duration (seconds) | `durationSeconds` if present (empty in sample) |
| Note | appended (`; `-joined, deduped) to that session's `SessionExercise.note` |
| Label, Duration (formatted) | ignored |

## Sessions file: `Setgraph_Sessions_Export_*.csv`
Header: `Activity Type,Start Date,End Date,Duration (seconds),Duration (formatted),Calories (kcal),Distance (meters),Source,Location,Notes,Custom Metadata`

Each row → `WorkoutSession` (source `.import`, `startedAt`, `endedAt`, `activeCalories` from Calories, `note` from Notes; `pausedSeconds` = max(0, (end−start) − Duration (seconds))).

- **Strength types:** `Strength Training`, `Functional Strength Training`, `Core Training`. Their exercises/sets come from the sets file.
- **Cardio types:** create one `SessionExercise` + one `SetEntry` with `durationSeconds` = Duration (seconds), `distanceMeters` = Distance (meters) if present. Exercise per type (match/create as cardio):
  `Walking`→Walking (walking) · `Cycling`→Outdoor Cycling if Location=Outdoor else Indoor Cycling (cycling) · `Elliptical`→Elliptical · `Stair Climbing`→Stair Climber (stairs) · `Running`→Outdoor Run if Location=Outdoor else Treadmill Run (running) · `Mixed Cardio`→"Mixed Cardio" (other) · `Yoga`→"Yoga" (other). Unknown type → custom cardio exercise named after the type (other).
- Source, Custom Metadata, Duration (formatted): ignored.

## Assigning sets to sessions
1. A set belongs to the session whose `[start, end]` contains its Date. If several match, prefer a strength-type session, then the shortest.
2. Sets in no session: sort by time; consecutive sets ≤ 90 min apart on the same calendar day form a synthetic strength session (`startedAt` = first set − 1 min, `endedAt` = last set).
3. Within a session, `SessionExercise` order = first appearance; `SetEntry.sortOrder` = time order within that exercise.
4. `restSeconds` on a set = gap to the next set in the same session (any exercise), only if 0 < gap ≤ 600 s; otherwise nil.
5. If a cardio-type session also contains sets, import those sets too (as extra session exercises after the cardio one).

## Exercise matching
1. Normalise: `Exercise.nameKey` (lowercase, trimmed, collapsed spaces).
2. Apply alias map (user approved merging obvious typos and pointing some names at built-ins; keys/values are nameKeys; target is the display name used if created):
   - dumbell shrugs → Dumbbell Shrugs
   - squats, squat → Back Squat (built-in)
   - dead lift → Deadlift
   - tricep push down, tricep pushdown → Triceps Pushdown (built-in)
   - chest press → Chest Press Machine (built-in)
   - leg extentions → Leg Extension
   - barbell shrugs → Barbell Shrug
   - seated incline db curl, seated inclined db curls → Incline Dumbbell Curl (built-in)
   - hammer curls, dumbbell hammer curl → Hammer Curl
   - dumbell side laterals, db side lateral raises → DB Side Lateral Raise
   - (keep `Side Lateral Raises` separate — possibly cable/machine)
3. Match nameKey against existing non-deleted exercises (built-in or custom). Else create a custom strength exercise.
4. Muscle group for created exercises: keyword rules on nameKey, first match wins, else `other`:
   - core: crunch, plank, knee raise, abs, ab 
   - legs: squat, leg press, leg extension, leg curl, lunge, calf, hack, adduct, abduct
   - glutes: hip thrust, glute
   - back: row, lat , pulldown, pull down, pullover, pull up, pullup, deadlift, shrug, scapula
   - chest: bench, chest press, pec, fly, flies, incline press, dumbbell press
   - shoulders: lateral, front raise, overhead press, shoulder press, face pull, rear delt, reverse pec
   - triceps: tricep, triceps, pushdown, push down, arm extension
   - biceps: curl
   Preview lists every created exercise with its group.

## Idempotency
- `WorkoutSession.importKey` = `setgraph:session:<Activity Type>|<Start Date raw>` (synthetic: `setgraph:session:synthetic|<first set Date raw>`).
- `SetEntry.importKey` = `setgraph:set:<nameKey raw>|<Date raw>|<Repetitions>|<Weight (kg)>|<n>` where n = occurrence index of that identical tuple in the file (so true duplicates within the file are preserved only once: n>0 rows are reported as "duplicate row, skipped").
- On import, skip any session/set whose importKey already exists (non-deleted). Re-importing the same files adds nothing.
- Cardio set importKey = `setgraph:cardio:<session importKey>`.

## Errors & preview
- Errors are reported per row: file, line number, reason (bad date, non-numeric reps, missing exercise name, end before start…). Never silently dropped.
- Preview before commit: sessions to add (strength/cardio/synthetic), sets to add, exercises matched vs created (with muscle group and alias merges), duplicates skipped, already-imported skipped, errors.
- Commit writes everything in one save; all rows `needsPush = true` so they back up to Supabase.
