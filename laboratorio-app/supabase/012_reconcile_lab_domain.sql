-- Conciliación con el modelo OP -> Muestra -> OA -> Resultado.
-- Ejecutar después de 011. Es aditiva: conserva las OP y plantillas históricas.

create type public.package_duration as enum ('instant', '12H', '24H');
create type public.worksheet_status as enum ('pendiente', 'completa', 'liberada');

alter table public.clients
  add column if not exists address text,
  add column if not exists rfc text,
  add column if not exists attention_to text;

create table if not exists public.samplers (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  active boolean not null default true
);

alter table public.analysis_packages
  add column if not exists package_type text not null default 'norma'
    check (package_type in ('norma', 'cliente')),
  add column if not exists duration public.package_duration;

create table if not exists public.multi_packages (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  active boolean not null default true
);

create table if not exists public.multi_package_items (
  multi_package_id uuid not null references public.multi_packages(id) on delete cascade,
  sample_position integer not null check (sample_position > 0),
  package_id uuid not null references public.analysis_packages(id),
  primary key (multi_package_id, sample_position)
);

alter table public.analysis_orders
  add column if not exists sampler_id uuid references public.samplers(id),
  add column if not exists multi_package_id uuid references public.multi_packages(id);

-- package_id, sampling_number y sampler_name se conservan para compatibilidad con la UI
-- anterior. En registros nuevos, el paquete y el muestreo viven en `samples`.
alter table public.samples
  add column if not exists package_id uuid references public.analysis_packages(id),
  add column if not exists sampling_number text,
  add column if not exists sampling_ph numeric,
  add column if not exists sampling_temperature numeric,
  add column if not exists sampling_floating_matter text;

update public.samples s
set package_id = ao.package_id,
    sampling_number = coalesce(s.sampling_number, ao.sampling_number)
from public.analysis_orders ao
where ao.id = s.order_id and s.package_id is null;

create table if not exists public.analysis_worksheets (
  id uuid primary key default gen_random_uuid(),
  sample_id uuid not null unique references public.samples(id) on delete cascade,
  status public.worksheet_status not null default 'pendiente',
  received_at date not null default current_date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.analysis_results (
  id uuid primary key default gen_random_uuid(),
  worksheet_id uuid not null references public.analysis_worksheets(id) on delete cascade,
  parameter_id uuid not null references public.parameters(id),
  uncertainty numeric,
  result_value text,
  analyst_reference text,
  analyst_id uuid references public.profiles(id),
  released_by_id uuid references public.profiles(id),
  analyzed_at date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (worksheet_id, parameter_id),
  check (uncertainty is null or uncertainty >= 0)
);

-- Cada muestra tiene OA y cada paquete genera sus resultados requeridos.
create or replace function public.create_worksheet_for_sample(p_sample_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_worksheet_id uuid; v_package_id uuid;
begin
  select package_id into v_package_id from public.samples where id = p_sample_id;
  if v_package_id is null then
    raise exception 'La muestra % no tiene paquete asignado', p_sample_id;
  end if;
  insert into public.analysis_worksheets (sample_id)
  values (p_sample_id)
  on conflict (sample_id) do update set updated_at = now()
  returning id into v_worksheet_id;
  insert into public.analysis_results (worksheet_id, parameter_id)
  select v_worksheet_id, pp.parameter_id
  from public.package_parameters pp
  where pp.package_id = v_package_id
  on conflict (worksheet_id, parameter_id) do nothing;
  return v_worksheet_id;
end;
$$;

create or replace function public.sync_sample_worksheet()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.package_id is not null then
    perform public.create_worksheet_for_sample(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists samples_create_worksheet on public.samples;
create trigger samples_create_worksheet
after insert or update of package_id on public.samples
for each row execute function public.sync_sample_worksheet();

-- Catálogo mínimo derivado de las filas existentes: permite que las plantillas
-- ya creadas también se comuniquen con el catálogo estándar de parámetros.
insert into public.parameters (name, unit, method_reference)
select distinct r.label, coalesce(r.unit, ''), 'pendiente'
from public.analysis_order_rows r
where not exists (select 1 from public.parameters p where p.name = r.label)
on conflict (name) do nothing;

insert into public.package_parameters (package_id, parameter_id)
select distinct s.package_id, p.id
from public.analysis_order_rows r
join public.samples s on s.id = r.sample_id
join public.parameters p on p.name = r.label
where s.package_id is not null
on conflict do nothing;

-- Crea OAs/resultados para muestras históricas y migra los valores capturados.
select public.create_worksheet_for_sample(s.id) from public.samples s where s.package_id is not null;

insert into public.analysis_results (
  worksheet_id, parameter_id, uncertainty, result_value, analyst_reference, analyzed_at
)
select w.id, p.id, r.uncertainty, r.result_value, r.analyst_reference, r.result_date
from public.analysis_order_rows r
join public.analysis_worksheets w on w.sample_id = r.sample_id
join public.parameters p on p.name = r.label
where r.result_value is not null
on conflict (worksheet_id, parameter_id) do update set
  uncertainty = excluded.uncertainty,
  result_value = excluded.result_value,
  analyst_reference = excluded.analyst_reference,
  analyzed_at = excluded.analyzed_at,
  updated_at = now();

create or replace view public.worksheet_results as
select w.id as worksheet_id, w.sample_id, w.status, p.id as parameter_id,
       p.name as parameter_name, p.unit, p.method_reference,
       r.id as result_id, r.result_value, r.uncertainty, r.analyst_reference,
       r.analyst_id, r.released_by_id, r.analyzed_at
from public.analysis_worksheets w
join public.analysis_results r on r.worksheet_id = w.id
join public.parameters p on p.id = r.parameter_id;

-- Un informe sólo se emite si no hay resultados requeridos pendientes en la OP.
create or replace function public.order_results_complete(p_order_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.samples where order_id = p_order_id)
     and not exists (
       select 1
       from public.samples s
       where s.order_id = p_order_id
         and (
           -- Las OAs históricas siguen siendo la fuente operativa mientras la UI
           -- especializada (NOM-001) no haya sido sustituida por worksheet_results.
           (exists (select 1 from public.analysis_order_rows lr where lr.sample_id = s.id)
            and exists (select 1 from public.analysis_order_rows lr where lr.sample_id = s.id and nullif(trim(coalesce(lr.result_value, '')), '') is null))
           or
           (not exists (select 1 from public.analysis_order_rows lr where lr.sample_id = s.id)
            and exists (
              select 1 from public.analysis_worksheets w
              join public.analysis_results r on r.worksheet_id = w.id
              where w.sample_id = s.id and nullif(trim(coalesce(r.result_value, '')), '') is null
            ))
         )
     );
$$;

create or replace function public.issue_report(p_order_id uuid, p_report_number text, p_pdf_path text default null)
returns public.reports language plpgsql security definer set search_path = public as $$
declare v_report public.reports;
begin
  if auth.uid() is null or public.current_role() not in ('administrador', 'recepcion', 'revisor') then
    raise exception 'No tienes permiso para emitir informes';
  end if;
  if not public.order_results_complete(p_order_id) then
    raise exception 'Orden de análisis incompleta, revisar';
  end if;
  insert into public.reports (order_id, report_number, issued_at, issued_by, pdf_path)
  values (p_order_id, trim(p_report_number), now(), auth.uid(), p_pdf_path)
  on conflict (order_id, version) do update set issued_at = excluded.issued_at, issued_by = excluded.issued_by, pdf_path = excluded.pdf_path
  returning * into v_report;
  update public.analysis_orders set status = 'informe_emitido', issued_at = current_date, report_number = trim(p_report_number), updated_at = now() where id = p_order_id;
  return v_report;
end;
$$;

-- Reemplaza la recepción heredada: el número de muestreo ya no es obligatorio
-- y, cuando existe, queda ligado a la muestra (no a toda la OP).
create or replace function public.create_sample_entry(
  p_client_name text, p_sampling_number text, p_sample_number text, p_package_code text,
  p_received_at date, p_sampled_at date default null, p_sampler_name text default null,
  p_quotation_number text default null, p_billing_details text default null, p_precaptured boolean default false
)
returns public.analysis_orders
language plpgsql security definer set search_path = public as $$
declare
  v_client_id uuid; v_package_id uuid; v_order public.analysis_orders;
  v_sequence integer; v_prefix text; v_sample_id uuid;
begin
  if auth.uid() is null or public.current_role() not in ('administrador', 'recepcion') then
    raise exception 'No tienes permiso para crear entradas de muestra';
  end if;
  if trim(coalesce(p_client_name, '')) = '' then raise exception 'El cliente es obligatorio'; end if;
  if trim(coalesce(p_sample_number, '')) = '' then raise exception 'El número de muestra es obligatorio'; end if;
  if p_received_at is null then raise exception 'La fecha de recepción es obligatoria'; end if;
  perform pg_advisory_xact_lock(extract(year from p_received_at)::integer);
  if exists (select 1 from public.samples where sample_code = trim(p_sample_number)) then
    raise exception 'El número de muestra % ya existe', trim(p_sample_number);
  end if;
  select id into v_package_id from public.analysis_packages where code = p_package_code and active = true;
  if v_package_id is null then raise exception 'Tipo de análisis no válido'; end if;
  insert into public.clients (name) values (trim(p_client_name))
  on conflict (name) do update set name = excluded.name returning id into v_client_id;
  select count(*) + 1 into v_sequence from public.analysis_orders
  where op_number ~ ('^2' || to_char(p_received_at, 'YY') || '[0-9]{5}$');
  if v_sequence > 999 then raise exception 'Se agotó el consecutivo anual de OP'; end if;
  v_prefix := '2' || to_char(p_received_at, 'YY') || to_char(p_received_at, 'MM');
  insert into public.analysis_orders (
    op_number, client_id, package_id, sampling_number, sampler_name, quotation_number,
    billing_details, precaptured, received_at, sampled_at, due_date, created_by
  ) values (
    v_prefix || lpad(v_sequence::text, 3, '0'), v_client_id, v_package_id,
    nullif(trim(p_sampling_number), ''), nullif(trim(p_sampler_name), ''), nullif(trim(p_quotation_number), ''),
    nullif(trim(p_billing_details), ''), p_precaptured, p_received_at, p_sampled_at,
    public.calculate_due_date(p_received_at, 8), auth.uid()
  ) returning * into v_order;
  insert into public.samples (order_id, sample_code, package_id, sampling_number)
  values (v_order.id, trim(p_sample_number), v_package_id, nullif(trim(p_sampling_number), ''))
  returning id into v_sample_id;
  if p_package_code = 'NOM-001-2021-24H' then perform public.create_nom001_2021_24h_rows(v_sample_id); end if;
  insert into public.audit_events (actor_id, entity_type, entity_id, action, after_data)
  values (auth.uid(), 'sample_intake', v_order.id, 'created', jsonb_build_object(
    'op_number', v_order.op_number, 'sample_number', p_sample_number, 'package_id', v_package_id
  ));
  return v_order;
end;
$$;

alter table public.samplers enable row level security;
alter table public.multi_packages enable row level security;
alter table public.multi_package_items enable row level security;
alter table public.analysis_worksheets enable row level security;
alter table public.analysis_results enable row level security;

create policy "authenticated read samplers" on public.samplers for select to authenticated using (true);
create policy "authenticated read multi packages" on public.multi_packages for select to authenticated using (true);
create policy "authenticated read multi package items" on public.multi_package_items for select to authenticated using (true);
create policy "analysts read worksheet results without client" on public.analysis_worksheets for select to authenticated using (true);
create policy "analysts read results" on public.analysis_results for select to authenticated using (true);
create policy "staff update results" on public.analysis_results for update to authenticated using (public.current_role() in ('administrador', 'recepcion', 'analista', 'revisor'));

-- La confidencialidad se aplica a nivel de tablas base, no sólo de pantalla.
drop policy if exists "authenticated can read operational data" on public.clients;
create policy "non analysts read client data" on public.clients for select to authenticated
using (public.current_role() in ('administrador', 'recepcion', 'revisor'));
drop policy if exists "authenticated can read orders" on public.analysis_orders;
create policy "non analysts read orders" on public.analysis_orders for select to authenticated
using (public.current_role() in ('administrador', 'recepcion', 'revisor'));

grant select on public.worksheet_results to authenticated;
grant execute on function public.create_worksheet_for_sample(uuid) to authenticated;
grant execute on function public.order_results_complete(uuid) to authenticated;
grant execute on function public.issue_report(uuid, text, text) to authenticated;
