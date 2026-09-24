---
paths:
  - "backend/supabase/migrations/**/*.sql"
  - "backend/supabase/seed/**/*.sql"
---

# Database Rules

- Every schema change is a migration file. Never edit an applied migration;
  add a new one. Filenames are `NNNN_snake_case.sql`, ordered.
- Every user-owned table has `user_id uuid not null references public.users(id)
  on delete cascade`.
- `alter table ... enable row level security;` goes in the SAME migration that
  creates the table, with an explicit policy per operation.
- Policies compare against `auth.uid()`. A `USING (true)` clause on a user-owned
  table is a defect.
- Timestamps are `timestamptz`, default `now()`, named `created_at` / `updated_at`.
  Use the shared `set_updated_at()` trigger rather than hand-rolling one.
- Money is `numeric(12,2)` plus a separate ISO-4217 `currency text`. Never float.
- Enumerations are Postgres enums or `check` constraints, never free text.
- Index every foreign key used for lookup, and every column used in an RLS policy.
- Seed data lives in `seed/` and never runs against production.
