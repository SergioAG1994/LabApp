-- Flujo de recepción: una OP = una muestra = un número de muestreo = un informe futuro.
-- Ejecutar después de 002_orders_rpc.sql.

alter table public.analysis_orders
  add column if not exists billing_details text,
  add column if not exists quotation_number text,
  add column if not exists precaptured boolean not null default false,
  add column if not exists sampled_at date,
  add column if not exists report_number text;

alter table public.samples
  add column if not exists analysis_order_created_at timestamptz;

create or replace function public.calculate_due_date(p_received_at date, p_business_days integer default 8)
returns date
language plpgsql
immutable
as $$
declare
  v_date date := p_received_at;
  v_days integer := 0;
begin
  while v_days < p_business_days loop
    v_date := v_date + 1;
    if extract(isodow from v_date) < 6 then
      v_days := v_days + 1;
    end if;
  end loop;
  return v_date;
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
begin
  if auth.uid() is null or public.current_role() not in ('administrador', 'recepcion') then
    raise exception 'No tienes permiso para crear entradas de muestra';
  end if;
  if trim(coalesce(p_client_name, '')) = '' then raise exception 'El cliente es obligatorio'; end if;
  if trim(coalesce(p_sampling_number, '')) = '' then raise exception 'El número de muestreo es obligatorio'; end if;
  if trim(coalesce(p_sample_number, '')) = '' then raise exception 'El número de muestra es obligatorio'; end if;
  if p_received_at is null then raise exception 'La fecha de recepción es obligatoria'; end if;

  -- Evita que dos recepciones simultáneas generen el mismo consecutivo anual.
  perform pg_advisory_xact_lock(extract(year from p_received_at)::integer);
  v_prefix := '2' || to_char(p_received_at, 'YY') || to_char(p_received_at, 'MM');

  if exists (select 1 from public.samples where sample_code = trim(p_sample_number)) then
    raise exception 'El número de muestra % ya existe', trim(p_sample_number);
  end if;

  select id into v_package_id from public.analysis_packages where code = p_package_code and active = true;
  if v_package_id is null then raise exception 'Tipo de análisis no válido'; end if;

  insert into public.clients (name)
  values (trim(p_client_name))
  on conflict (name) do update set name = excluded.name
  returning id into v_client_id;

  -- El consecutivo se reinicia al cambiar de año y no al cambiar de mes.
  select count(*) + 1 into v_sequence
  from public.analysis_orders
  where op_number ~ ('^2' || to_char(p_received_at, 'YY') || '[0-9]{5}$');
  if v_sequence > 999 then raise exception 'Se agotó el consecutivo anual de OP'; end if;

  insert into public.analysis_orders (
    op_number, client_id, package_id, sampling_number, sampler_name, quotation_number,
    billing_details, precaptured, received_at, sampled_at, due_date, created_by
  ) values (
    v_prefix || lpad(v_sequence::text, 3, '0'),
    v_client_id, v_package_id, trim(p_sampling_number), nullif(trim(p_sampler_name), ''), nullif(trim(p_quotation_number), ''),
    nullif(trim(p_billing_details), ''), p_precaptured, p_received_at, p_sampled_at,
    public.calculate_due_date(p_received_at, 8), auth.uid()
  ) returning * into v_order;

  insert into public.samples (order_id, sample_code)
  values (v_order.id, trim(p_sample_number));

  insert into public.audit_events (actor_id, entity_type, entity_id, action, after_data)
  values (auth.uid(), 'sample_intake', v_order.id, 'created', jsonb_build_object(
    'op_number', v_order.op_number, 'sampling_number', p_sampling_number, 'sample_number', p_sample_number
  ));

  return v_order;
end;
$$;

grant execute on function public.create_sample_entry(text, text, text, text, date, date, text, text, text, boolean) to authenticated;
