begin;
set local lock_timeout = '5s';

create table public.staff_training_records (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.laboratory_staff(id),
  training_name text not null check (char_length(btrim(training_name)) between 1 and 300),
  instructor text not null check (char_length(btrim(instructor)) between 1 and 300),
  training_kind text not null check (training_kind in ('internal', 'external')),
  received_at date not null check (isfinite(received_at)),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index staff_training_staff_date_idx on public.staff_training_records(staff_id, received_at desc, id);
alter table public.staff_training_records enable row level security;
revoke all on public.staff_training_records from public, anon, authenticated;
grant select, insert, update on public.staff_training_records to authenticated;
create policy "administrators manage personnel training"
  on public.staff_training_records for all to authenticated
  using (coalesce((select public.current_role()) = 'administrador', false))
  with check (coalesce((select public.current_role()) = 'administrador', false));

create function public.prepare_staff_training()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.staff_id is distinct from old.staff_id then
    raise exception 'La capacitación no puede transferirse a otra persona';
  end if;
  new.training_name := btrim(new.training_name);
  new.instructor := btrim(new.instructor);
  new.updated_at := clock_timestamp();
  return new;
end $$;
revoke all on function public.prepare_staff_training() from public, anon, authenticated;
create trigger prepare_staff_training before insert or update
  on public.staff_training_records for each row execute function public.prepare_staff_training();
create trigger audit_staff_training after insert or update
  on public.staff_training_records for each row execute function public.record_database_change();

-- Training received before joining the laboratory is valid historical data.
-- Recording training does not grant internal or EMA authorizations.
commit;
