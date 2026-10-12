-- Keep issued orders out of the open-samples list.
create or replace function public.list_staff_samples()
returns table (
  order_id uuid,
  sample_id uuid,
  sample_code text,
  analysis_label text,
  received_at date,
  due_date date,
  analysis_order_created_at timestamptz,
  total_results integer,
  captured_results integer,
  completion_percent integer
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null
     or (select public.current_role()) not in ('administrador', 'recepcion', 'analista') then
    raise exception 'No tienes permiso para consultar muestras';
  end if;

  return query
  select
    ao.id,
    s.id,
    s.sample_code,
    coalesce(nullif(btrim(s.analysis_label), ''), ap.name, ap.code, 'Sin análisis'),
    ao.received_at::date,
    ao.due_date::date,
    s.analysis_order_created_at,
    count(ar.id)::integer,
    count(ar.id) filter (where nullif(btrim(coalesce(ar.result_value, '')), '') is not null)::integer,
    case when count(ar.id) = 0 then 0 else round(
      100.0 * count(ar.id) filter (where nullif(btrim(coalesce(ar.result_value, '')), '') is not null) / count(ar.id)
    )::integer end
  from public.samples s
  join public.analysis_orders ao on ao.id = s.order_id
  left join public.analysis_packages ap on ap.id = s.package_id
  left join public.analysis_worksheets aw on aw.sample_id = s.id
  left join public.analysis_results ar on ar.worksheet_id = aw.id
  where ao.status not in ('cancelada', 'informe_emitido')
    and ao.report_number is null
  group by ao.id, s.id, s.sample_code, s.analysis_label, ap.name, ap.code,
           ao.received_at, ao.due_date, s.analysis_order_created_at
  order by ao.received_at desc, s.sample_code desc;
end;
$$;

revoke all on function public.list_staff_samples() from public, anon, authenticated;
grant execute on function public.list_staff_samples() to authenticated;

-- Minimal read-only metadata for already-issued samples. Analysts must not be
-- able to retrieve client data or open/download the final report from this view.
create or replace function public.list_completed_staff_samples()
returns table (
  sample_id uuid,
  sample_code text,
  received_at date,
  issued_at date,
  report_number text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null
     or (select public.current_role()) not in ('administrador', 'recepcion', 'analista') then
    raise exception 'No tienes permiso para consultar muestras terminadas';
  end if;

  return query
  select
    s.id,
    s.sample_code,
    ao.received_at::date,
    r.issued_at::date,
    r.report_number
  from public.samples s
  join public.analysis_orders ao on ao.id = s.order_id
  join public.reports r on r.order_id = ao.id
  where ao.status = 'informe_emitido'
    and r.issued_at is not null
    and nullif(btrim(r.report_number), '') is not null
  order by r.issued_at desc, s.sample_code desc;
end;
$$;

revoke all on function public.list_completed_staff_samples() from public, anon, authenticated;
grant execute on function public.list_completed_staff_samples() to authenticated;
