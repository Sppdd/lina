-- Lina's accounts, plans and daily limits.
-- Every model call goes through the lina-ai Edge Function, which calls consume() before it spends anything.

-- Plans: how much of each kind of request a person gets per day (UTC).
create table if not exists public.plans (
  id text primary key,
  name text not null,
  checks_per_day int not null,
  commands_per_day int not null,
  searches_per_day int not null,
  images_per_day int not null,
  -- Longest text (characters) one request may send.
  max_input_chars int not null default 12000
);

insert into public.plans (id, name, checks_per_day, commands_per_day, searches_per_day, images_per_day)
values
  ('free', 'Free', 300, 40, 20, 5),
  ('plus', 'Plus', 2000, 400, 150, 40)
on conflict (id) do nothing;

-- One row per person. Created automatically when they first sign in.
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  plan text not null default 'free' references public.plans (id),
  -- Switch someone off without deleting them.
  blocked boolean not null default false,
  created_at timestamptz not null default now()
);

-- Daily counts per person and kind ('check', 'command', 'search', 'image').
create table if not exists public.usage (
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null default (now() at time zone 'utc')::date,
  kind text not null check (kind in ('check', 'command', 'search', 'image')),
  count int not null default 0,
  primary key (user_id, day, kind)
);

alter table public.plans enable row level security;
alter table public.profiles enable row level security;
alter table public.usage enable row level security;

-- People may read the plans, their own profile and their own usage. Nobody writes from the app:
-- profiles come from the trigger below, usage only from consume(), which the server calls.
drop policy if exists "plans are public" on public.plans;
create policy "plans are public" on public.plans for select to authenticated using (true);
drop policy if exists "own profile" on public.profiles;
create policy "own profile" on public.profiles for select to authenticated using ((select auth.uid()) = id);
drop policy if exists "own usage" on public.usage;
create policy "own usage" on public.usage for select to authenticated using ((select auth.uid()) = user_id);

-- A profile for every new account.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email) values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Counts `units` of `kind` for a person, if today's limit allows it, in one statement (safe under concurrency).
-- Returns {ok, used, limit, plan}. Only the server (service_role) may call it.
create or replace function public.consume(p_user uuid, p_kind text, p_units int default 1)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan public.plans;
  v_blocked boolean;
  v_limit int;
  v_used int;
  v_today date := (now() at time zone 'utc')::date;
begin
  -- Accounts made before this migration get their profile now.
  insert into public.profiles (id, email)
  select u.id, u.email from auth.users u where u.id = p_user
  on conflict (id) do nothing;

  select pr.blocked into v_blocked from public.profiles pr where pr.id = p_user;
  select pl.* into v_plan
  from public.plans pl join public.profiles pr on pr.plan = pl.id
  where pr.id = p_user;

  if v_plan.id is null then
    return jsonb_build_object('ok', false, 'reason', 'no_account');
  end if;
  if v_blocked then
    return jsonb_build_object('ok', false, 'reason', 'blocked', 'plan', v_plan.id);
  end if;

  v_limit := case p_kind
    when 'check' then v_plan.checks_per_day
    when 'command' then v_plan.commands_per_day
    when 'search' then v_plan.searches_per_day
    when 'image' then v_plan.images_per_day
  end;
  if v_limit is null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_kind');
  end if;

  insert into public.usage as u (user_id, day, kind, count)
  values (p_user, v_today, p_kind, p_units)
  on conflict (user_id, day, kind) do update
    set count = u.count + excluded.count
    where u.count + excluded.count <= v_limit
  returning u.count into v_used;

  if v_used is null or v_used > v_limit then
    -- Refused: the update didn't happen, or a first request was already over the limit (then take it back).
    if v_used is not null then
      delete from public.usage where user_id = p_user and day = v_today and kind = p_kind and count = v_used;
    end if;
    select coalesce((select count from public.usage where user_id = p_user and day = v_today and kind = p_kind), 0)
      into v_used;
    return jsonb_build_object('ok', false, 'reason', 'limit', 'used', v_used, 'limit', v_limit, 'plan', v_plan.id);
  end if;

  return jsonb_build_object('ok', true, 'used', v_used, 'limit', v_limit, 'plan', v_plan.id);
end;
$$;

-- Today's use with the plan's limits, for Settings → Account.
create or replace function public.usage_today(p_user uuid)
returns jsonb
language sql
security definer
set search_path = ''
stable
as $$
  with me as (
    select pl.* from public.profiles pr join public.plans pl on pl.id = pr.plan where pr.id = p_user
  ), kinds(kind, lim) as (
    select 'check', checks_per_day from me union all
    select 'command', commands_per_day from me union all
    select 'search', searches_per_day from me union all
    select 'image', images_per_day from me
  )
  select jsonb_build_object(
    'plan', coalesce((select id from me), 'free'),
    'usage', coalesce(jsonb_agg(jsonb_build_object(
      'kind', k.kind,
      'limit', k.lim,
      'used', coalesce((select u.count from public.usage u
                        where u.user_id = p_user and u.day = (now() at time zone 'utc')::date and u.kind = k.kind), 0)
    )), '[]'::jsonb)
  )
  from kinds k;
$$;

revoke all on function public.consume(uuid, text, int) from public, anon, authenticated;
revoke all on function public.usage_today(uuid) from public, anon, authenticated;
grant execute on function public.consume(uuid, text, int) to service_role;
grant execute on function public.usage_today(uuid) to service_role;
