-- CycleCare — Supabase schema
-- Run this in the Supabase SQL Editor (Project → SQL Editor → New Query)

create extension if not exists "pgcrypto";

-- ============ COUPLES ============
create table couples (
  id uuid primary key default gen_random_uuid(),
  invite_code text unique not null default substr(md5(random()::text), 1, 8),
  created_at timestamptz default now()
);

-- ============ PROFILES (extends auth.users) ============
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  couple_id uuid references couples(id) on delete set null,
  share_enabled boolean default false,
  plan text default 'free' check (plan in ('free','premium')),
  plan_cycle text check (plan_cycle in ('monthly','yearly')),
  subscription_expires_at timestamptz,
  created_at timestamptz default now()
);

-- Auto-create a profile row whenever someone signs up
create or replace function handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, new.raw_user_meta_data->>'display_name');
  return new;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- Lock plan fields so only the service role (billing webhook) can change them —
-- never trust the client with these, even though RLS allows updating own profile.
revoke update (plan, plan_cycle, subscription_expires_at) on profiles from authenticated;

-- ============ CYCLE LOGS (private) ============
create table cycle_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  log_date date not null,
  symptoms text[] default '{}',
  created_at timestamptz default now()
);

-- ============ CHECKLIST ITEMS (shared within a couple) ============
create table checklist_items (
  id uuid primary key default gen_random_uuid(),
  couple_id uuid not null references couples(id) on delete cascade,
  label text not null,
  done boolean default false,
  is_custom boolean default false,
  created_by uuid references auth.users(id),
  created_at timestamptz default now()
);

-- ============ NOTES (shared within a couple — includes gestures & love notes) ============
create table notes (
  id uuid primary key default gen_random_uuid(),
  couple_id uuid not null references couples(id) on delete cascade,
  author_id uuid not null references auth.users(id),
  text text not null,
  is_gesture boolean default false,
  reactions jsonb default '{}'::jsonb,
  created_at timestamptz default now()
);

-- ============ SUBSCRIPTIONS (service-role only — never exposed to clients) ============
create table subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  play_purchase_token text,
  product_id text,
  status text check (status in ('active','canceled','expired','grace_period')),
  expires_at timestamptz,
  created_at timestamptz default now()
);

-- ================= ROW LEVEL SECURITY =================

alter table profiles enable row level security;
alter table couples enable row level security;
alter table cycle_logs enable row level security;
alter table checklist_items enable row level security;
alter table notes enable row level security;
alter table subscriptions enable row level security;
-- subscriptions gets NO policies below — only the service-role key (backend/webhook) can touch it.

-- --- profiles ---
create policy "view own or partner's profile"
  on profiles for select
  using (
    id = auth.uid()
    or couple_id = (select couple_id from profiles where id = auth.uid())
  );

create policy "update own profile"
  on profiles for update
  using (id = auth.uid());

-- --- couples ---
create policy "view own couple"
  on couples for select
  using (id = (select couple_id from profiles where id = auth.uid()));

create policy "create a couple"
  on couples for insert
  with check (true); -- anyone can create a couple row when generating an invite

-- --- cycle_logs ---
create policy "view own log, or partner's if they share"
  on cycle_logs for select
  using (
    user_id = auth.uid()
    or exists (
      select 1 from profiles me
      join profiles owner on owner.id = cycle_logs.user_id
      where me.id = auth.uid()
        and me.couple_id is not null
        and me.couple_id = owner.couple_id
        and owner.share_enabled = true
    )
  );

create policy "manage own log"
  on cycle_logs for insert with check (user_id = auth.uid());
create policy "update own log"
  on cycle_logs for update using (user_id = auth.uid());
create policy "delete own log"
  on cycle_logs for delete using (user_id = auth.uid());

-- --- checklist_items ---
create policy "couple can view checklist"
  on checklist_items for select
  using (couple_id = (select couple_id from profiles where id = auth.uid()));
create policy "couple can insert checklist items"
  on checklist_items for insert
  with check (couple_id = (select couple_id from profiles where id = auth.uid()));
create policy "couple can update checklist items"
  on checklist_items for update
  using (couple_id = (select couple_id from profiles where id = auth.uid()));
create policy "couple can delete checklist items"
  on checklist_items for delete
  using (couple_id = (select couple_id from profiles where id = auth.uid()));

-- --- notes ---
create policy "couple can view notes"
  on notes for select
  using (couple_id = (select couple_id from profiles where id = auth.uid()));
create policy "couple can insert notes"
  on notes for insert
  with check (couple_id = (select couple_id from profiles where id = auth.uid()));
create policy "couple can react to notes"
  on notes for update
  using (couple_id = (select couple_id from profiles where id = auth.uid()));
