-- LabAqua: esquema inicial. Ejecutar una sola vez en Supabase > SQL Editor.
create type public.app_role as enum ('administrador', 'recepcion', 'analista', 'revisor');
create type public.order_status as enum ('registrada', 'en_proceso', 'completa', 'en_revision', 'informe_emitido', 'cancelada');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  role public.app_role not null default 'recepcion',
  created_at timestamptz not null default now()
);

create table public.clients (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  contact_name text,
  email text,
  phone text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.parameters (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  unit text,
  method_reference text,
  decimal_places smallint not null default 2 check (decimal_places between 0 and 8),
  result_kind text not null default 'number' check (result_kind in ('number', 'text', 'less_than')),
  assigned_analyst_id uuid references public.profiles(id),
  active boolean not null default true
);

create table public.analysis_packages (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  active boolean not null default true
);

create table public.package_parameters (
  package_id uuid not null references public.analysis_packages(id) on delete cascade,
  parameter_id uuid not null references public.parameters(id),
  primary key (package_id, parameter_id)
);

create table public.analysis_orders (
  id uuid primary key default gen_random_uuid(),
  op_number text not null unique,
  client_id uuid not null references public.clients(id),
  package_id uuid references public.analysis_packages(id),
  sampling_number text,
  sampler_name text,
  received_at timestamptz not null default now(),
  due_date date not null,
  status public.order_status not null default 'registrada',
  notes text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.samples (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.analysis_orders(id) on delete cascade,
  sample_code text not null,
  sampling_point text,
  description text,
  unique (order_id, sample_code)
);

create table public.reports (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.analysis_orders(id),
  report_number text not null unique,
  version integer not null default 1,
  issued_at timestamptz,
  issued_by uuid references public.profiles(id),
  pdf_path text,
  unique (order_id, version)
);

create table public.audit_events (
  id bigint generated always as identity primary key,
  actor_id uuid references public.profiles(id),
  entity_type text not null,
  entity_id uuid,
  action text not null,
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name) values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', ''));
  return new;
end;
$$;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

create or replace function public.current_role() returns public.app_role language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid()
$$;

alter table public.profiles enable row level security;
alter table public.clients enable row level security;
alter table public.parameters enable row level security;
alter table public.analysis_packages enable row level security;
alter table public.package_parameters enable row level security;
alter table public.analysis_orders enable row level security;
alter table public.samples enable row level security;
alter table public.reports enable row level security;
alter table public.audit_events enable row level security;

create policy "authenticated can read operational data" on public.clients for select to authenticated using (true);
create policy "authenticated can read parameters" on public.parameters for select to authenticated using (true);
create policy "authenticated can read packages" on public.analysis_packages for select to authenticated using (true);
create policy "authenticated can read package parameters" on public.package_parameters for select to authenticated using (true);
create policy "authenticated can read orders" on public.analysis_orders for select to authenticated using (true);
create policy "authenticated can read samples" on public.samples for select to authenticated using (true);
create policy "authenticated can read reports" on public.reports for select to authenticated using (true);
create policy "users read their profile" on public.profiles for select to authenticated using (id = auth.uid() or public.current_role() = 'administrador');
create policy "admins update profiles" on public.profiles for update to authenticated using (public.current_role() = 'administrador');
create policy "reception creates orders" on public.analysis_orders for insert to authenticated with check (public.current_role() in ('administrador', 'recepcion'));
create policy "reception updates orders" on public.analysis_orders for update to authenticated using (public.current_role() in ('administrador', 'recepcion'));
create policy "reception manages samples" on public.samples for all to authenticated using (public.current_role() in ('administrador', 'recepcion')) with check (public.current_role() in ('administrador', 'recepcion'));
