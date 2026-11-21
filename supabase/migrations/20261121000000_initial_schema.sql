-- Workout tracker schema (PLAN §2.3). Columns mirror the CodingKeys in
-- Packages/WorkoutCore/Sources/WorkoutCore/Sync/DTO.swift exactly.
--
-- * id is client-generated; the primary key is (user_id, id) because built-in
--   exercises share deterministic IDs across users. Upserts use on_conflict=user_id,id.
-- * No foreign keys between app tables: rows may arrive in any order.
-- * server_updated_at is set by the server on every write and is used only as the
--   pull cursor (ordered by server_updated_at, id).
--   ponytail: now() is transaction start time, so a slow transaction can commit behind a cursor
--   that already passed it. Fine for one user's devices; use a commit-ordered cursor if writers multiply.
-- * Last-write-wins on updated_at is enforced server-side by a trigger.

create table public.exercises (
  id uuid not null,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  server_updated_at timestamptz not null default now(),
  name text not null,
  name_key text not null,
  muscle_group text not null check (muscle_group in
    ('chest', 'back', 'shoulders', 'biceps', 'triceps', 'legs', 'glutes', 'core', 'fullBody', 'cardio', 'other')),
  kind text not null check (kind in ('strength', 'cardio')),
  cardio_activity text check (cardio_activity in
    ('running', 'walking', 'cycling', 'rowing', 'elliptical', 'stairs', 'other')),
  is_built_in boolean not null default false,
  default_rest_seconds integer not null check (default_rest_seconds >= 0),
  primary key (user_id, id)
);

create table public.routines (
  id uuid not null,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  server_updated_at timestamptz not null default now(),
  name text not null,
  sort_order integer not null,
  primary key (user_id, id)
);

create table public.routine_exercises (
  id uuid not null,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  server_updated_at timestamptz not null default now(),
  routine_id uuid not null,
  exercise_id uuid not null,
  sort_order integer not null,
  target_sets integer not null,
  target_reps integer not null,
  rest_seconds integer,
  primary key (user_id, id)
);

create table public.workout_sessions (
  id uuid not null,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  server_updated_at timestamptz not null default now(),
  routine_id uuid,
  started_at timestamptz not null,
  ended_at timestamptz,
  paused_seconds double precision not null default 0,
  source text not null check (source in ('watch', 'phone', 'import')),
  active_calories double precision,
  avg_heart_rate double precision,
  healthkit_workout_id uuid,
  import_key text,
  primary key (user_id, id)
);

create table public.session_exercises (
  id uuid not null,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  server_updated_at timestamptz not null default now(),
  session_id uuid not null,
  exercise_id uuid not null,
  sort_order integer not null,
  note text,
  primary key (user_id, id)
);

create table public.set_entries (
  id uuid not null,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  server_updated_at timestamptz not null default now(),
  session_exercise_id uuid not null,
  sort_order integer not null,
  weight_kg double precision,
  reps integer,
  distance_meters double precision,
  duration_seconds double precision,
  rest_seconds double precision,
  completed_at timestamptz not null,
  import_key text,
  primary key (user_id, id)
);

create table public.body_weight_entries (
  id uuid not null,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  server_updated_at timestamptz not null default now(),
  date timestamptz not null,
  weight_kg double precision not null,
  healthkit_sample_id uuid,
  source text not null check (source in ('app', 'health', 'import')),
  primary key (user_id, id)
);

-- Foreign-key-ish lookups.
create index on public.routine_exercises (routine_id);
create index on public.routine_exercises (exercise_id);
create index on public.workout_sessions (routine_id);
create index on public.session_exercises (session_id);
create index on public.session_exercises (exercise_id);
create index on public.set_entries (session_exercise_id);

-- Shared trigger functions.

create function public.set_server_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.server_updated_at := now();
  return new;
end;
$$;

-- Last-write-wins: an older write keeps the stored row. Ownership never changes.
create function public.keep_newer() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.updated_at < old.updated_at then
    return old;
  end if;
  new.user_id := old.user_id;
  return new;
end;
$$;

-- Per-table: pull-cursor index, triggers, RLS. Triggers fire in name order, so
-- keep_newer runs before the stamp: a rejected (older) write still bumps
-- server_updated_at, which makes the pusher pull the winning row back and converge.
do $$
declare
  t text;
begin
  foreach t in array array['exercises', 'routines', 'routine_exercises', 'workout_sessions',
                           'session_exercises', 'set_entries', 'body_weight_entries']
  loop
    execute format('create index on public.%I (user_id, server_updated_at, id)', t);

    execute format('create trigger a_keep_newer before update on public.%I
                    for each row execute function public.keep_newer()', t);
    execute format('create trigger b_set_server_updated_at before insert or update on public.%I
                    for each row execute function public.set_server_updated_at()', t);

    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "select own" on public.%I for select to authenticated
                    using (user_id = (select auth.uid()))', t);
    execute format('create policy "insert own" on public.%I for insert to authenticated
                    with check (user_id = (select auth.uid()))', t);
    execute format('create policy "update own" on public.%I for update to authenticated
                    using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()))', t);
    -- No delete policy: soft deletes only (deleted_at).
  end loop;
end;
$$;
