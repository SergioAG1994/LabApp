-- Normaliza el modelo:
-- analysis_orders (OP) 1 -> N samples N -> 1 analysis_packages.
-- Ejecutar después de 015_seed_excel_analysis_packages.sql.

do $$
begin
  if exists (select 1 from public.samples where package_id is null) then
    raise exception 'No se puede normalizar: existen muestras sin paquete de análisis';
  end if;

  if exists (
    select 1
    from public.analysis_orders ao
    where not exists (
      select 1 from public.samples s where s.order_id = ao.id
    )
  ) then
    raise exception 'No se puede normalizar: existen OPs sin muestras';
  end if;
end;
$$;

alter table public.samples
  alter column package_id set not null;

create index if not exists samples_package_id_idx
  on public.samples (package_id);

comment on column public.samples.order_id is
  'OP que contiene la muestra; una OP puede contener una o más muestras.';

comment on column public.samples.package_id is
  'Paquete de análisis asignado a esta muestra.';

create or replace function public.create_nom001_2021_24h_rows(p_sample_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_package_code text;
begin
  if auth.uid() is null or public.current_role() not in ('administrador', 'recepcion') then
    raise exception 'No tienes permiso para generar órdenes de análisis';
  end if;

  select ap.code
  into v_package_code
  from public.samples s
  join public.analysis_packages ap on ap.id = s.package_id
  where s.id = p_sample_id;

  if v_package_code is null then
    raise exception 'La muestra no existe';
  end if;

  if v_package_code <> 'NOM-001-2021-24H' then
    raise exception 'Esta plantilla sólo corresponde a NOM-001-SEMARNAT-2021 de 24 horas';
  end if;

  perform public.ensure_nom001_2021_24h_exact_template(p_sample_id);

  update public.samples
  set analysis_order_created_at = coalesce(analysis_order_created_at, now())
  where id = p_sample_id;
end;
$$;

create or replace function public.keep_nom001_2021_24h_exact_rows()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.row_key in ('ph', 'cromo_vi') and exists (
    select 1
    from public.samples s
    join public.analysis_packages ap on ap.id = s.package_id
    where s.id = new.sample_id
      and ap.code = 'NOM-001-2021-24H'
  ) then
    perform public.ensure_nom001_2021_24h_exact_template(new.sample_id);
  end if;

  return new;
end;
$$;

create or replace function public.create_analysis_order(
  p_client_name text,
  p_package_code text,
  p_sample_count integer,
  p_received_at date default current_date
)
returns public.analysis_orders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_client_id uuid;
  v_package_id uuid;
  v_order public.analysis_orders;
  v_next_number integer;
  v_index integer;
begin
  if auth.uid() is null or public.current_role() not in ('administrador', 'recepcion') then
    raise exception 'No tienes permiso para crear órdenes';
  end if;

  if trim(coalesce(p_client_name, '')) = '' then
    raise exception 'El cliente es obligatorio';
  end if;

  if p_sample_count < 1 or p_sample_count > 20 then
    raise exception 'El número de muestras debe estar entre 1 y 20';
  end if;

  insert into public.clients (name)
  values (trim(p_client_name))
  on conflict (name) do update set name = excluded.name
  returning id into v_client_id;

  select id
  into v_package_id
  from public.analysis_packages
  where code = p_package_code
    and active = true;

  if v_package_id is null then
    raise exception 'Tipo de análisis no válido';
  end if;

  select count(*) + 1
  into v_next_number
  from public.analysis_orders
  where extract(year from created_at at time zone 'America/Mexico_City')
      = extract(year from p_received_at);

  insert into public.analysis_orders (
    op_number,
    client_id,
    received_at,
    due_date,
    created_by
  )
  values (
    format(
      'OP-%s-%s',
      extract(year from p_received_at)::integer,
      lpad(v_next_number::text, 3, '0')
    ),
    v_client_id,
    p_received_at,
    p_received_at + 18,
    auth.uid()
  )
  returning * into v_order;

  for v_index in 1..p_sample_count loop
    insert into public.samples (order_id, sample_code, package_id)
    values (v_order.id, format('Muestra %s', v_index), v_package_id);
  end loop;

  insert into public.audit_events (
    actor_id,
    entity_type,
    entity_id,
    action,
    after_data
  )
  values (
    auth.uid(),
    'analysis_order',
    v_order.id,
    'created',
    jsonb_build_object(
      'op_number', v_order.op_number,
      'sample_count', p_sample_count,
      'package_id', v_package_id
    )
  );

  return v_order;
end;
$$;

create or replace function public.create_sample_entry(
  p_client_name text,
  p_sampling_number text,
  p_sample_number text,
  p_package_code text,
  p_received_at date,
  p_sampled_at date default null,
  p_sampler_name text default null,
  p_quotation_number text default null,
  p_billing_details text default null,
  p_precaptured boolean default false
)
returns public.analysis_orders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_client_id uuid;
  v_package_id uuid;
  v_order public.analysis_orders;
  v_sequence integer;
  v_prefix text;
  v_sample_id uuid;
begin
  if auth.uid() is null or public.current_role() not in ('administrador', 'recepcion') then
    raise exception 'No tienes permiso para crear entradas de muestra';
  end if;

  if trim(coalesce(p_client_name, '')) = '' then
    raise exception 'El cliente es obligatorio';
  end if;

  if trim(coalesce(p_sample_number, '')) = '' then
    raise exception 'El número de muestra es obligatorio';
  end if;

  if p_received_at is null then
    raise exception 'La fecha de recepción es obligatoria';
  end if;

  perform pg_advisory_xact_lock(extract(year from p_received_at)::integer);

  if exists (
    select 1
    from public.samples
    where sample_code = trim(p_sample_number)
  ) then
    raise exception 'El número de muestra % ya existe', trim(p_sample_number);
  end if;

  select id
  into v_package_id
  from public.analysis_packages
  where code = p_package_code
    and active = true;

  if v_package_id is null then
    raise exception 'Tipo de análisis no válido';
  end if;

  insert into public.clients (name)
  values (trim(p_client_name))
  on conflict (name) do update set name = excluded.name
  returning id into v_client_id;

  select count(*) + 1
  into v_sequence
  from public.analysis_orders
  where op_number ~ ('^2' || to_char(p_received_at, 'YY') || '[0-9]{5}$');

  if v_sequence > 999 then
    raise exception 'Se agotó el consecutivo anual de OP';
  end if;

  v_prefix := '2' || to_char(p_received_at, 'YY') || to_char(p_received_at, 'MM');

  insert into public.analysis_orders (
    op_number,
    client_id,
    sampler_name,
    quotation_number,
    billing_details,
    precaptured,
    received_at,
    sampled_at,
    due_date,
    created_by
  )
  values (
    v_prefix || lpad(v_sequence::text, 3, '0'),
    v_client_id,
    nullif(trim(p_sampler_name), ''),
    nullif(trim(p_quotation_number), ''),
    nullif(trim(p_billing_details), ''),
    p_precaptured,
    p_received_at,
    p_sampled_at,
    public.calculate_due_date(p_received_at, 8),
    auth.uid()
  )
  returning * into v_order;

  insert into public.samples (
    order_id,
    sample_code,
    package_id,
    sampling_number
  )
  values (
    v_order.id,
    trim(p_sample_number),
    v_package_id,
    nullif(trim(p_sampling_number), '')
  )
  returning id into v_sample_id;

  if p_package_code = 'NOM-001-2021-24H' then
    perform public.create_nom001_2021_24h_rows(v_sample_id);
  end if;

  insert into public.audit_events (
    actor_id,
    entity_type,
    entity_id,
    action,
    after_data
  )
  values (
    auth.uid(),
    'sample_intake',
    v_order.id,
    'created',
    jsonb_build_object(
      'op_number', v_order.op_number,
      'sample_number', p_sample_number,
      'package_id', v_package_id
    )
  );

  return v_order;
end;
$$;

-- Conserva los valores históricos para poder revertir o auditar la transición,
-- pero elimina la relación incorrecta OP -> paquete.
alter table public.analysis_orders
  drop constraint if exists analysis_orders_package_id_fkey;

comment on column public.analysis_orders.package_id is
  'Obsoleto: valor histórico conservado sin FK. El paquete vigente vive en samples.package_id.';

grant execute on function public.create_analysis_order(text, text, integer, date)
  to authenticated;

grant execute on function public.create_nom001_2021_24h_rows(uuid)
  to authenticated;

grant execute on function public.create_sample_entry(
  text,
  text,
  text,
  text,
  date,
  date,
  text,
  text,
  text,
  boolean
) to authenticated;

revoke all on function public.create_analysis_order(text, text, integer, date)
  from public;

revoke all on function public.create_analysis_order(text, text, integer, date)
  from anon;

revoke all on function public.create_nom001_2021_24h_rows(uuid)
  from public;

revoke all on function public.create_nom001_2021_24h_rows(uuid)
  from anon;

revoke all on function public.create_sample_entry(
  text,
  text,
  text,
  text,
  date,
  date,
  text,
  text,
  text,
  boolean
) from public;

revoke all on function public.create_sample_entry(
  text,
  text,
  text,
  text,
  date,
  date,
  text,
  text,
  text,
  boolean
) from anon;

revoke all on function public.keep_nom001_2021_24h_exact_rows()
  from public;

revoke all on function public.keep_nom001_2021_24h_exact_rows()
  from anon;

revoke all on function public.keep_nom001_2021_24h_exact_rows()
  from authenticated;
