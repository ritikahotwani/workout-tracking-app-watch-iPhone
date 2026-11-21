-- Free-text note on a workout session (SetGraph import "Notes", editable in session detail).
alter table public.workout_sessions add column note text;
