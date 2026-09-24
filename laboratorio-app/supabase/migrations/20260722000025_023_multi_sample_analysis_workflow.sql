-- OPs con varias muestras, paquetes distintos y multipaquetes reutilizables.
begin;

set local lock_timeout = '5s';

alter table public.multi_packages
  add column if not exists sample_count integer,
  add column if not exists created_by uuid references public.profiles(id),
  add column if not exists created_at timestamptz not null default now();

update public.multi_packages set sample_count = 1 where sample_count is null;
alter table public.multi_packages alter column sample_count set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'multi_packages_sample_count_check'
      and conrelid = 'public.multi_packages'::regclass
  ) then
    alter table public.multi_packages
      add constraint multi_packages_sample_count_check check (sample_count between 1 and 20);
  end if;
end $$;

create unique index if not exists multi_packages_name_unique
  on public.multi_packages (lower(name));

-- No existen registros históricos: se redefine como detalle parámetro/posición.
drop table if exists public.multi_package_items;
create table public.multi_package_items (
  multi_package_id uuid not null references public.multi_packages(id) on delete cascade,
  sample_position integer not null check (sample_position > 0),
  parameter_id uuid not null references public.parameters(id),
  display_order integer not null check (display_order > 0),
  primary key (multi_package_id, sample_position, parameter_id),
  unique (multi_package_id, sample_position, display_order)
);

create index multi_package_items_parameter_id_idx
  on public.multi_package_items (parameter_id);

alter table public.multi_package_items enable row level security;
create policy "staff read multi package items"
  on public.multi_package_items for select to authenticated
  using ((select public.current_role()) in ('administrador', 'recepcion', 'revisor'));

drop policy if exists "authenticated read multi packages" on public.multi_packages;
create policy "staff read multi packages"
  on public.multi_packages for select to authenticated
  using ((select public.current_role()) in ('administrador', 'recepcion', 'revisor'));

alter table public.samples alter column package_id drop not null;
alter table public.samples
  add column if not exists multi_package_id uuid references public.multi_packages(id),
  add column if not exists multi_package_sample_position integer,
  add column if not exists analysis_label text;

create index if not exists samples_multi_package_id_idx
  on public.samples (multi_package_id);

alter table public.analysis_results
  add column if not exists display_order integer;

drop view if exists public.worksheet_results;
create view public.worksheet_results with (security_invoker = true) as
select w.id as worksheet_id, w.sample_id, w.status,
       r.id as id, coalesce(r.display_order, pp.display_order) as display_order,
       coalesce(pp.row_type, 'result') as row_type,
       p.id as parameter_id, p.name as label, p.unit, p.method_reference,
       r.result_value, r.uncertainty, r.analyst_reference,
       r.analyst_id, r.released_by_id, r.analyst_name, r.released_by,
       r.analyzed_at, p.par_form
from public.analysis_worksheets w
join public.analysis_results r on r.worksheet_id = w.id
join public.samples s on s.id = w.sample_id
join public.parameters p on p.id = r.parameter_id
left join public.package_parameters pp
  on pp.package_id = s.package_id and pp.parameter_id = r.parameter_id;

grant select on public.worksheet_results to authenticated;

create or replace function public.save_multi_package(
  p_name text,
  p_sample_parameters jsonb
)
returns public.multi_packages
language plpgsql security definer set search_path = public as $$
declare
  v_multi public.multi_packages;
  v_sample jsonb;
  v_position integer;
  v_parameter text;
  v_order integer;
begin
  if auth.uid() is null or public.current_role() not in ('administrador', 'recepcion') then
    raise exception 'No tienes permiso para crear multipaquetes';
  end if;
  if nullif(trim(coalesce(p_name, '')), '') is null then
    raise exception 'El nombre del multipaquete es obligatorio';
  end if;
  if jsonb_typeof(p_sample_parameters) <> 'array'
     or jsonb_array_length(p_sample_parameters) not between 1 and 20 then
    raise exception 'El multipaquete debe contener entre 1 y 20 muestras';
  end if;

  insert into public.multi_packages (name, sample_count, created_by)
  values (trim(p_name), jsonb_array_length(p_sample_parameters), auth.uid())
  returning * into v_multi;

  for v_sample, v_position in
    select value, ordinality::integer
    from jsonb_array_elements(p_sample_parameters) with ordinality
  loop
    if jsonb_typeof(v_sample->'parameter_ids') <> 'array'
       or jsonb_array_length(v_sample->'parameter_ids') = 0 then
      raise exception 'La muestra % debe contener al menos un parámetro', v_position;
    end if;
    v_order := 0;
    for v_parameter in select jsonb_array_elements_text(v_sample->'parameter_ids')
    loop
      v_order := v_order + 1;
      insert into public.multi_package_items (
        multi_package_id, sample_position, parameter_id, display_order
      )
      select v_multi.id, v_position, p.id, v_order
      from public.parameters p
      where p.id = v_parameter::uuid and p.active = true;
      if not found then
        raise exception 'Parámetro inválido en la muestra %', v_position;
      end if;
    end loop;
  end loop;

  insert into public.audit_events (actor_id, entity_type, entity_id, action, after_data)
  values (auth.uid(), 'multi_package', v_multi.id, 'created',
          jsonb_build_object('name', v_multi.name, 'sample_count', v_multi.sample_count));
  return v_multi;
end;
$$;

revoke execute on function public.save_multi_package(text, jsonb) from public, anon;
grant execute on function public.save_multi_package(text, jsonb) to authenticated;

create or replace function public.create_sample_entry_batch(
  p_client_name text,
  p_samples jsonb,
  p_lab_sampling boolean,
  p_sampling_number text,
  p_received_at date,
  p_multi_package_id uuid default null,
  p_sampled_at date default null,
  p_sampler_name text default null,
  p_quotation_number text default null,
  p_billing_details text default null,
  p_precaptured boolean default false
)
returns public.analysis_orders
language plpgsql security definer set search_path = public as $$
declare
  v_client_id uuid;
  v_order public.analysis_orders;
  v_sequence integer;
  v_prefix text;
  v_sampling_number text;
  v_sample jsonb;
  v_position integer;
  v_sample_id uuid;
  v_worksheet_id uuid;
  v_package_id uuid;
  v_analysis_label text;
  v_parameter text;
  v_display_order integer;
  v_multi public.multi_packages;
begin
  if auth.uid() is null or public.current_role() not in ('administrador', 'recepcion') then
    raise exception 'No tienes permiso para crear entradas de muestra';
  end if;
  if nullif(trim(coalesce(p_client_name, '')), '') is null then
    raise exception 'El cliente es obligatorio';
  end if;
  if p_received_at is null then
    raise exception 'La fecha de recepción es obligatoria';
  end if;
  if jsonb_typeof(p_samples) <> 'array'
     or jsonb_array_length(p_samples) not between 1 and 20 then
    raise exception 'La OP debe contener entre 1 y 20 muestras';
  end if;

  v_sampling_number := case
    when p_lab_sampling then nullif(trim(coalesce(p_sampling_number, '')), '')
    else 'N/A'
  end;
  if p_lab_sampling and v_sampling_number is null then
    raise exception 'El número de muestreo es obligatorio cuando muestrea el laboratorio';
  end if;

  if p_multi_package_id is not null then
    select * into v_multi from public.multi_packages
    where id = p_multi_package_id and active = true;
    if v_multi.id is null then raise exception 'Multipaquete no válido'; end if;
    if v_multi.sample_count <> jsonb_array_length(p_samples) then
      raise exception 'El multipaquete requiere % muestras', v_multi.sample_count;
    end if;
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_samples) with ordinality a(value, ordinality)
    join jsonb_array_elements(p_samples) with ordinality b(value, ordinality)
      on a.value->>'sample_number' = b.value->>'sample_number'
     and a.ordinality < b.ordinality
  ) then raise exception 'Los números de muestra no pueden repetirse'; end if;

  if exists (
    select 1 from public.samples s
    join jsonb_array_elements(p_samples) x
      on s.sample_code = trim(x.value->>'sample_number')
  ) then raise exception 'Uno o más números de muestra ya existen'; end if;

  perform pg_advisory_xact_lock(extract(year from p_received_at)::integer);
  insert into public.clients (name) values (trim(p_client_name))
  on conflict (name) do update set name = excluded.name returning id into v_client_id;

  select count(*) + 1 into v_sequence from public.analysis_orders
  where op_number ~ ('^2' || to_char(p_received_at, 'YY') || '[0-9]{5}$');
  if v_sequence > 999 then raise exception 'Se agotó el consecutivo anual de OP'; end if;
  v_prefix := '2' || to_char(p_received_at, 'YY') || to_char(p_received_at, 'MM');

  insert into public.analysis_orders (
    op_number, client_id, multi_package_id, sampling_number, sampler_name,
    quotation_number, billing_details, precaptured, received_at, sampled_at,
    due_date, created_by
  ) values (
    v_prefix || lpad(v_sequence::text, 3, '0'), v_client_id, p_multi_package_id,
    v_sampling_number, nullif(trim(p_sampler_name), ''),
    nullif(trim(p_quotation_number), ''), nullif(trim(p_billing_details), ''),
    p_precaptured, p_received_at, p_sampled_at,
    public.calculate_due_date(p_received_at, 8), auth.uid()
  ) returning * into v_order;

  for v_sample, v_position in
    select value, ordinality::integer from jsonb_array_elements(p_samples) with ordinality
  loop
    if nullif(trim(coalesce(v_sample->>'sample_number', '')), '') is null then
      raise exception 'El número de la muestra % es obligatorio', v_position;
    end if;

    v_package_id := null;
    if p_multi_package_id is null and nullif(v_sample->>'package_id', '') is not null then
      select id, name into v_package_id, v_analysis_label
      from public.analysis_packages
      where id = (v_sample->>'package_id')::uuid and active = true;
      if v_package_id is null then raise exception 'Paquete no válido en la muestra %', v_position; end if;
    elsif p_multi_package_id is not null then
      v_analysis_label := v_multi.name || ' · Muestra ' || v_position;
    else
      v_analysis_label := 'Selección personalizada';
      if jsonb_typeof(v_sample->'parameter_ids') <> 'array'
         or jsonb_array_length(v_sample->'parameter_ids') = 0 then
        raise exception 'Selecciona parámetros para la muestra %', v_position;
      end if;
    end if;

    insert into public.samples (
      order_id, sample_code, package_id, sampling_number, multi_package_id,
      multi_package_sample_position, analysis_label
    ) values (
      v_order.id, trim(v_sample->>'sample_number'), v_package_id, v_sampling_number,
      p_multi_package_id, case when p_multi_package_id is null then null else v_position end,
      v_analysis_label
    ) returning id into v_sample_id;

    if v_package_id is null then
      insert into public.analysis_worksheets (sample_id, received_at)
      values (v_sample_id, p_received_at) returning id into v_worksheet_id;

      if p_multi_package_id is not null then
        insert into public.analysis_results (worksheet_id, parameter_id, display_order)
        select v_worksheet_id, mpi.parameter_id, mpi.display_order
        from public.multi_package_items mpi
        where mpi.multi_package_id = p_multi_package_id
          and mpi.sample_position = v_position
        order by mpi.display_order;
        if not found then raise exception 'La muestra % del multipaquete no tiene parámetros', v_position; end if;
      else
        v_display_order := 0;
        for v_parameter in select jsonb_array_elements_text(v_sample->'parameter_ids')
        loop
          v_display_order := v_display_order + 1;
          insert into public.analysis_results (worksheet_id, parameter_id, display_order)
          select v_worksheet_id, p.id, v_display_order
          from public.parameters p
          where p.id = v_parameter::uuid and p.active = true;
          if not found then raise exception 'Parámetro inválido en la muestra %', v_position; end if;
        end loop;
      end if;
      update public.samples set analysis_order_created_at = now() where id = v_sample_id;
    end if;
  end loop;

  insert into public.audit_events (actor_id, entity_type, entity_id, action, after_data)
  values (auth.uid(), 'sample_intake', v_order.id, 'created_batch',
          jsonb_build_object('op_number', v_order.op_number,
                             'sample_count', jsonb_array_length(p_samples),
                             'multi_package_id', p_multi_package_id,
                             'lab_sampling', p_lab_sampling));
  return v_order;
end;
$$;

revoke execute on function public.create_sample_entry_batch(
  text, jsonb, boolean, text, date, uuid, date, text, text, text, boolean
) from public, anon;
grant execute on function public.create_sample_entry_batch(
  text, jsonb, boolean, text, date, uuid, date, text, text, text, boolean
) to authenticated;

commit;
