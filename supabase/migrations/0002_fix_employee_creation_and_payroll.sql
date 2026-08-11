-- =====================================================================
-- FIX: employee creation losing values (department, salary) + payroll
--      skipping newly created employees because they have no salary
--      structure row.
--
-- Safe to run on your EXISTING project: every statement is idempotent
-- (IF NOT EXISTS / guarded DO blocks), so it will not touch or delete
-- any data you already have. Run this in Supabase -> SQL Editor.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. departments — make sure it exists with what the app expects
-- ---------------------------------------------------------------------
create table if not exists public.departments (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  created_at timestamptz not null default now()
);

alter table public.departments enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'departments'
      and policyname = 'departments_read_all_authenticated'
  ) then
    create policy departments_read_all_authenticated
      on public.departments for select
      to authenticated
      using (true);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'departments'
      and policyname = 'departments_admin_write'
  ) then
    create policy departments_admin_write
      on public.departments for all
      to authenticated
      using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'))
      with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. profiles — this is the table where values were silently going
--    missing. Make sure every column the app writes to actually exists,
--    and that employee_id + department_id behave correctly.
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists employee_id     text;
alter table public.profiles add column if not exists department_id  uuid references public.departments(id);
alter table public.profiles add column if not exists designation    text;
alter table public.profiles add column if not exists date_of_joining date;
alter table public.profiles add column if not exists phone          text;
alter table public.profiles add column if not exists status         text not null default 'active';

-- employee_id must be unique or two employees can silently collide
-- (this is very likely why some payroll rows look wrong/merged).
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'profiles_employee_id_key'
  ) then
    -- guard against pre-existing duplicate/blank employee_ids blocking the constraint
    if not exists (
      select employee_id from public.profiles
      where employee_id is not null
      group by employee_id having count(*) > 1
    ) then
      alter table public.profiles add constraint profiles_employee_id_key unique (employee_id);
    end if;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. Auto-create a profile row the instant a new auth user is created,
--    so there is never a moment where the user exists in auth but has
--    no row in profiles. The Edge Function's upsert() then fills in
--    role/employee_id/department_id/etc regardless of timing.
-- ---------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, role, status)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', new.email), 'employee', 'active')
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- 4. salary_structures — payroll's calculate_payroll() looks here first;
--    if a newly created employee has no row here, run-payroll.html shows
--    "Skipped: no salary structure" for them. Make sure the table +
--    constraints exist so the new create-employee flow can populate it.
-- ---------------------------------------------------------------------
create table if not exists public.salary_structures (
  id                uuid primary key default gen_random_uuid(),
  employee_id       uuid not null references public.profiles(id) on delete cascade,
  effective_from    date not null,
  basic             numeric not null default 0,
  hra               numeric not null default 0,
  da                numeric not null default 0,
  conveyance        numeric not null default 0,
  medical_allowance numeric not null default 0,
  special_allowance numeric not null default 0,
  other_allowances  numeric not null default 0,
  ctc_annual        numeric not null default 0,
  pf_applicable     boolean not null default true,
  esi_applicable    boolean not null default false,
  tax_regime        text not null default 'new',
  created_at        timestamptz not null default now(),
  unique (employee_id, effective_from)
);

alter table public.salary_structures enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'salary_structures'
      and policyname = 'salary_hr_admin_all'
  ) then
    create policy salary_hr_admin_all
      on public.salary_structures for all
      to authenticated
      using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('admin','hr')))
      with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('admin','hr')));
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'salary_structures'
      and policyname = 'salary_employee_read_own'
  ) then
    create policy salary_employee_read_own
      on public.salary_structures for select
      to authenticated
      using (employee_id = auth.uid());
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 5. Helper: current salary structure per employee (latest row whose
--    effective_from is on/before today). Payroll and profile pages can
--    use this instead of re-deriving "latest" logic in JS.
-- ---------------------------------------------------------------------
create or replace view public.current_salary_structures as
select distinct on (employee_id) *
from public.salary_structures
where effective_from <= current_date
order by employee_id, effective_from desc;
