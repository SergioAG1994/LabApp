-- Conserva el nombre formal del parámetro para el futuro informe de resultados.
-- `parameters.name` sigue siendo el nombre interno/corto usado por la OA.

begin;

set local lock_timeout = '5s';

alter table public.parameters
  add column if not exists par_form text;

comment on column public.parameters.par_form is
  'Nombre formal del parámetro para informes de resultados; se carga desde el catálogo fuente.';

create or replace view public.worksheet_results
with (security_invoker = true) as
select w.id as worksheet_id, w.sample_id, w.status,
       r.id as id, pp.display_order, pp.row_type,
       p.id as parameter_id, p.name as label, p.unit, p.method_reference,
       r.result_value, r.uncertainty, r.analyst_reference,
       r.analyst_id, r.released_by_id, r.analyst_name, r.released_by,
       r.analyzed_at, p.par_form
from public.analysis_worksheets w
join public.analysis_results r on r.worksheet_id = w.id
join public.samples s on s.id = w.sample_id
join public.package_parameters pp
  on pp.package_id = s.package_id
 and pp.parameter_id = r.parameter_id
join public.parameters p on p.id = r.parameter_id;

grant select on public.worksheet_results to authenticated;

commit;
