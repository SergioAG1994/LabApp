-- Consolidación definitiva: package_parameters define el paquete y
-- analysis_results guarda los resultados de cada OA.

alter table public.package_parameters
  add column if not exists display_order integer,
  add column if not exists row_type text not null default 'result'
    check (row_type in ('result', 'aggregate')),
  add column if not exists aggregation text;

update public.package_parameters pp
set display_order = r.display_order,
    row_type = r.row_type,
    aggregation = r.aggregation
from public.analysis_package_rows r
where r.package_id = pp.package_id
  and exists (
    select 1 from public.parameters p
    where p.id = pp.parameter_id and p.name = r.label
  );

alter table public.analysis_results
  add column if not exists analyst_name text,
  add column if not exists released_by text;

insert into public.analysis_results (
  worksheet_id, parameter_id, uncertainty, result_value,
  analyst_reference, analyzed_at, analyst_name, released_by
)
select w.id, p.id, lr.uncertainty, lr.result_value, lr.analyst_reference,
       lr.result_date, lr.analyst_name, lr.released_by
from public.analysis_order_rows lr
join public.analysis_worksheets w on w.sample_id = lr.sample_id
join public.parameters p on p.name = lr.label
on conflict (worksheet_id, parameter_id) do update set
  uncertainty = excluded.uncertainty,
  result_value = excluded.result_value,
  analyst_reference = excluded.analyst_reference,
  analyzed_at = excluded.analyzed_at,
  analyst_name = excluded.analyst_name,
  released_by = excluded.released_by,
  updated_at = now();

drop view if exists public.worksheet_results;
create or replace view public.worksheet_results with (security_invoker = true) as
select w.id as worksheet_id, w.sample_id, w.status,
       r.id as id, pp.display_order, pp.row_type, pp.aggregation,
       p.id as parameter_id, p.name as label, p.unit, p.method_reference,
       r.result_value, r.uncertainty, r.analyst_reference,
       r.analyst_id, r.released_by_id, r.analyst_name, r.released_by, r.analyzed_at
from public.analysis_worksheets w
join public.analysis_results r on r.worksheet_id = w.id
join public.samples s on s.id = w.sample_id
join public.package_parameters pp on pp.package_id = s.package_id and pp.parameter_id = r.parameter_id
join public.parameters p on p.id = r.parameter_id;

create or replace function public.order_results_complete(p_order_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.samples where order_id = p_order_id)
     and not exists (
       select 1
       from public.samples s
       join public.analysis_worksheets w on w.sample_id = s.id
       join public.analysis_results r on r.worksheet_id = w.id
       where s.order_id = p_order_id and (
         nullif(trim(coalesce(r.result_value, '')), '') is null
         or r.uncertainty is null
         or nullif(trim(coalesce(r.analyst_reference, '')), '') is null
         or r.analyzed_at is null
         or nullif(trim(coalesce(r.analyst_name, '')), '') is null
         or nullif(trim(coalesce(r.released_by, '')), '') is null
       )
     );
$$;

drop trigger if exists samples_create_template_rows on public.samples;
drop function if exists public.create_template_rows_for_sample();
drop function if exists public.create_analysis_order_rows_from_package(uuid);

drop table if exists public.analysis_package_rows;
drop table if exists public.analysis_order_rows;
