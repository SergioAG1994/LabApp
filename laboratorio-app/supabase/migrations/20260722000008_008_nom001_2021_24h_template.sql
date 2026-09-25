-- Primera plantilla operativa: NOM-001-SEMARNAT-2021, muestra compuesta de 24 h.
-- Ejecutar después de 007_restore_cancelled_entries.sql.
-- La lista definitiva de parámetros, métodos, unidades y decimales se ajustará en una migración posterior.

insert into public.analysis_packages (code, name)
values ('NOM-001-2021-24H', 'NOM-001-SEMARNAT-2021 · 24 horas')
on conflict (code) do update set name = excluded.name, active = true;

create table if not exists public.analysis_order_rows (
  id uuid primary key default gen_random_uuid(),
  sample_id uuid not null references public.samples(id) on delete cascade,
  row_key text not null,
  label text not null,
  unit text,
  row_type text not null default 'result' check (row_type in ('result', 'aggregate')),
  aggregation text,
  display_order integer not null,
  result_value text,
  result_date date,
  analyst_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (sample_id, row_key)
);

alter table public.analysis_order_rows enable row level security;

create policy "authenticated read analysis order rows"
on public.analysis_order_rows for select to authenticated using (true);

create policy "lab staff update analysis order rows"
on public.analysis_order_rows for update to authenticated
using (public.current_role() in ('administrador', 'recepcion', 'analista'))
with check (public.current_role() in ('administrador', 'recepcion', 'analista'));

create or replace function public.create_nom001_2021_24h_rows(p_sample_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_id uuid;
  v_package_code text;
begin
  if auth.uid() is null or public.current_role() not in ('administrador', 'recepcion') then
    raise exception 'No tienes permiso para generar órdenes de análisis';
  end if;

  select s.order_id, ap.code into v_order_id, v_package_code
  from public.samples s
  join public.analysis_orders ao on ao.id = s.order_id
  join public.analysis_packages ap on ap.id = ao.package_id
  where s.id = p_sample_id;

  if v_order_id is null then raise exception 'La muestra no existe'; end if;
  if v_package_code <> 'NOM-001-2021-24H' then
    raise exception 'Esta plantilla sólo corresponde a NOM-001-SEMARNAT-2021 de 24 horas';
  end if;

  insert into public.analysis_order_rows (sample_id, row_key, label, unit, row_type, aggregation, display_order)
  values
    (p_sample_id, 'ph', 'pH', 'U. de pH', 'result', null, 10),
    (p_sample_id, 'conductividad', 'Conductividad eléctrica', 'µS/cm', 'result', null, 20),
    (p_sample_id, 'temperatura', 'Temperatura', '° C', 'result', null, 30),
    (p_sample_id, 'materia_flotante', 'MF', 'Sin unidades', 'result', null, 40),
    (p_sample_id, 'solidos_sedimentables', 'S. Sed', 'ml/L', 'result', null, 50),
    (p_sample_id, 'dbo5', 'DBO5', 'mg/L', 'result', null, 60),
    (p_sample_id, 'dqo', 'DQO', 'mgO2/L', 'result', null, 70),
    (p_sample_id, 'sst', 'Sólidos suspendidos totales', 'mg/L', 'result', null, 80),
    (p_sample_id, 'arsenico', 'Arsénico', 'mg/L', 'result', null, 90),
    (p_sample_id, 'cadmio', 'Cadmio', 'mg/L', 'result', null, 100),
    (p_sample_id, 'cianuros', 'CN', 'µg/L', 'result', null, 110),
    (p_sample_id, 'cromo_vi', 'Cr VI', 'mg Cr6/L', 'result', null, 120),
    (p_sample_id, 'cobre', 'Cobre', 'mg/L', 'result', null, 130),
    (p_sample_id, 'mercurio', 'Mercurio', 'mg/L', 'result', null, 140),
    (p_sample_id, 'niquel', 'Níquel', 'mg/L', 'result', null, 150),
    (p_sample_id, 'plomo', 'Plomo', 'mg/L', 'result', null, 160),
    (p_sample_id, 'zinc', 'Zinc', 'mg/L', 'result', null, 170),
    (p_sample_id, 'gya_1', 'GyA (1)', 'mg/L', 'result', 'submuestra 1', 210),
    (p_sample_id, 'gya_2', 'GyA (2)', 'mg/L', 'result', 'submuestra 2', 220),
    (p_sample_id, 'gya_3', 'GyA (3)', 'mg/L', 'result', 'submuestra 3', 230),
    (p_sample_id, 'gya_4', 'GyA (4)', 'mg/L', 'result', 'submuestra 4', 240),
    (p_sample_id, 'gya_5', 'GyA (5)', 'mg/L', 'result', 'submuestra 5', 250),
    (p_sample_id, 'gya_6', 'GyA (6)', 'mg/L', 'result', 'submuestra 6', 260),
    (p_sample_id, 'gya_ponderado', 'GyA ponderado', 'mg/L', 'aggregate', 'ponderado', 270),
    (p_sample_id, 'ecoli_1', 'E. coli (1)', 'NMP/100 mL', 'result', 'submuestra 1', 310),
    (p_sample_id, 'ecoli_2', 'E. coli (2)', 'NMP/100 mL', 'result', 'submuestra 2', 320),
    (p_sample_id, 'ecoli_3', 'E. coli (3)', 'NMP/100 mL', 'result', 'submuestra 3', 330),
    (p_sample_id, 'ecoli_4', 'E. coli (4)', 'NMP/100 mL', 'result', 'submuestra 4', 340),
    (p_sample_id, 'ecoli_5', 'E. coli (5)', 'NMP/100 mL', 'result', 'submuestra 5', 350),
    (p_sample_id, 'ecoli_6', 'E. coli (6)', 'NMP/100 mL', 'result', 'submuestra 6', 360),
    (p_sample_id, 'ecoli_mg', 'E. coli MG', 'NMP/100 mL', 'aggregate', 'media geométrica', 370),
    (p_sample_id, 'col_fec_1', 'Col. fecales (1)', 'NMP/100 mL', 'result', 'submuestra 1', 410),
    (p_sample_id, 'col_fec_2', 'Col. fecales (2)', 'NMP/100 mL', 'result', 'submuestra 2', 420),
    (p_sample_id, 'col_fec_3', 'Col. fecales (3)', 'NMP/100 mL', 'result', 'submuestra 3', 430),
    (p_sample_id, 'col_fec_4', 'Col. fecales (4)', 'NMP/100 mL', 'result', 'submuestra 4', 440),
    (p_sample_id, 'col_fec_5', 'Col. fecales (5)', 'NMP/100 mL', 'result', 'submuestra 5', 450),
    (p_sample_id, 'col_fec_6', 'Col. fecales (6)', 'NMP/100 mL', 'result', 'submuestra 6', 460),
    (p_sample_id, 'col_fec_mg', 'Col. fecales MG', 'NMP/100 mL', 'aggregate', 'media geométrica', 470)
  on conflict (sample_id, row_key) do nothing;

  update public.samples set analysis_order_created_at = coalesce(analysis_order_created_at, now()) where id = p_sample_id;
end;
$$;

create or replace function public.create_sample_entry(
  p_client_name text, p_sampling_number text, p_sample_number text, p_package_code text,
  p_received_at date, p_sampled_at date default null, p_sampler_name text default null,
  p_quotation_number text default null, p_billing_details text default null, p_precaptured boolean default false
)
returns public.analysis_orders
language plpgsql security definer set search_path = public
as $$
declare
  v_client_id uuid; v_package_id uuid; v_order public.analysis_orders; v_sequence integer; v_prefix text; v_sample_id uuid;
begin
  if auth.uid() is null or public.current_role() not in ('administrador', 'recepcion') then raise exception 'No tienes permiso para crear entradas de muestra'; end if;
  if trim(coalesce(p_client_name, '')) = '' then raise exception 'El cliente es obligatorio'; end if;
  if trim(coalesce(p_sampling_number, '')) = '' then raise exception 'El número de muestreo es obligatorio'; end if;
  if trim(coalesce(p_sample_number, '')) = '' then raise exception 'El número de muestra es obligatorio'; end if;
  if p_received_at is null then raise exception 'La fecha de recepción es obligatoria'; end if;
  perform pg_advisory_xact_lock(extract(year from p_received_at)::integer);
  v_prefix := '2' || to_char(p_received_at, 'YY') || to_char(p_received_at, 'MM');
  if exists (select 1 from public.samples where sample_code = trim(p_sample_number)) then raise exception 'El número de muestra % ya existe', trim(p_sample_number); end if;
  select id into v_package_id from public.analysis_packages where code = p_package_code and active = true;
  if v_package_id is null then raise exception 'Tipo de análisis no válido'; end if;
  insert into public.clients (name) values (trim(p_client_name)) on conflict (name) do update set name = excluded.name returning id into v_client_id;
  select count(*) + 1 into v_sequence from public.analysis_orders where op_number ~ ('^2' || to_char(p_received_at, 'YY') || '[0-9]{5}$');
  if v_sequence > 999 then raise exception 'Se agotó el consecutivo anual de OP'; end if;
  insert into public.analysis_orders (op_number, client_id, package_id, sampling_number, sampler_name, quotation_number, billing_details, precaptured, received_at, sampled_at, due_date, created_by)
  values (v_prefix || lpad(v_sequence::text, 3, '0'), v_client_id, v_package_id, trim(p_sampling_number), nullif(trim(p_sampler_name), ''), nullif(trim(p_quotation_number), ''), nullif(trim(p_billing_details), ''), p_precaptured, p_received_at, p_sampled_at, public.calculate_due_date(p_received_at, 8), auth.uid())
  returning * into v_order;
  insert into public.samples (order_id, sample_code) values (v_order.id, trim(p_sample_number)) returning id into v_sample_id;
  if p_package_code = 'NOM-001-2021-24H' then perform public.create_nom001_2021_24h_rows(v_sample_id); end if;
  insert into public.audit_events (actor_id, entity_type, entity_id, action, after_data) values (auth.uid(), 'sample_intake', v_order.id, 'created', jsonb_build_object('op_number', v_order.op_number, 'sampling_number', p_sampling_number, 'sample_number', p_sample_number));
  return v_order;
end;
$$;

grant execute on function public.create_nom001_2021_24h_rows(uuid) to authenticated;
grant execute on function public.create_sample_entry(text, text, text, text, date, date, text, text, text, boolean) to authenticated;
