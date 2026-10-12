begin;
set local lock_timeout = '5s';
alter table public.laboratory_staff
  add column education text check (char_length(education) <= 500),
  add column joined_at date;

create table public.staff_parameter_authorizations (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.laboratory_staff(id),
  parameter_id uuid not null references public.parameters(id),
  authorization_kind text not null check (authorization_kind in ('internal','ema')),
  method_reference text not null check (btrim(method_reference) <> ''),
  authorized_at date not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(staff_id, parameter_id, authorization_kind, method_reference)
);
create index staff_authorizations_parameter_idx on public.staff_parameter_authorizations(parameter_id);
alter table public.staff_parameter_authorizations enable row level security;
revoke all on public.staff_parameter_authorizations from public, anon, authenticated;
grant select, insert, update on public.staff_parameter_authorizations to authenticated;
create policy "administrators manage personnel authorizations"
  on public.staff_parameter_authorizations for all to authenticated
  using (coalesce((select public.current_role()) = 'administrador', false))
  with check (coalesce((select public.current_role()) = 'administrador', false));

-- Capture the catalog method at authorization time. Later catalog edits must
-- not rewrite the historical method under which the person was authorized.
create function public.prepare_staff_authorization()
returns trigger language plpgsql security invoker set search_path = '' as $$
declare method text; admission date;
begin
  if tg_op = 'INSERT' then
    select nullif(btrim(p.method_reference),'') into method
      from public.parameters p where p.id=new.parameter_id and p.active;
    if method is null then raise exception 'Selecciona un parámetro activo con método registrado'; end if;
    new.method_reference := method;
  elsif new.staff_id is distinct from old.staff_id
    or new.parameter_id is distinct from old.parameter_id
    or new.authorization_kind is distinct from old.authorization_kind
    or new.method_reference is distinct from old.method_reference then
    raise exception 'El integrante, parámetro y método de una autorización no pueden reemplazarse';
  end if;
  select joined_at into admission from public.laboratory_staff where id=new.staff_id;
  if admission is not null and new.authorized_at < admission then
    raise exception 'La autorización no puede ser anterior al ingreso al laboratorio';
  end if;
  new.updated_at := now();
  return new;
end $$;
revoke all on function public.prepare_staff_authorization() from public, anon, authenticated;
create trigger prepare_staff_authorization before insert or update
  on public.staff_parameter_authorizations for each row execute function public.prepare_staff_authorization();
create trigger audit_staff_authorization after insert or update
  on public.staff_parameter_authorizations for each row execute function public.record_database_change();
create function public.validate_staff_admission()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if new.joined_at is not null and exists (
    select 1 from public.staff_parameter_authorizations a
    where a.staff_id=new.id and a.authorized_at < new.joined_at
  ) then raise exception 'La fecha de ingreso no puede ser posterior a una autorización registrada'; end if;
  new.updated_at := now();
  return new;
end $$;
revoke all on function public.validate_staff_admission() from public, anon, authenticated;
create trigger validate_staff_admission before update on public.laboratory_staff
  for each row execute function public.validate_staff_admission();
-- Existing personnel and issued analyses are left untouched. Actual admission
-- and authorization dates are entered by an administrator, never inferred.
commit;
