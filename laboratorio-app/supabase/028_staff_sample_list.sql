create or replace function public.list_staff_samples()
returns table (
  order_id uuid,
  sample_id uuid,
  sample_code text,
  received_at date,
  due_date date,
  analysis_order_created_at timestamptz,
  total_results integer,
  captured_results integer,
  completion_percent integer
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null
     or public.current_role() not in ('administrador', 'recepcion', 'analista', 'revisor') then
    raise exception 'No tienes permiso para consultar muestras';
  end if;

  return query
  select
    ao.id as order_id,
    s.id as sample_id,
    s.sample_code,
    ao.received_at::date,
    ao.due_date::date,
    s.analysis_order_created_at,
    count(ar.id)::integer as total_results,
    count(ar.id) filter (
      where nullif(btrim(coalesce(ar.result_value, '')), '') is not null
    )::integer as captured_results,
    case
      when count(ar.id) = 0 then 0
      else round(
        100.0 * count(ar.id) filter (
          where nullif(btrim(coalesce(ar.result_value, '')), '') is not null
        ) / count(ar.id)
      )::integer
    end as completion_percent
  from public.samples s
  join public.analysis_orders ao on ao.id = s.order_id
  left join public.analysis_worksheets aw on aw.sample_id = s.id
  left join public.analysis_results ar on ar.worksheet_id = aw.id
  where ao.status <> 'cancelada'
  group by ao.id, s.id, s.sample_code, ao.received_at, ao.due_date,
           s.analysis_order_created_at
  order by ao.received_at desc, s.sample_code desc;
end;
$$;

revoke execute on function public.list_staff_samples() from public, anon;
grant execute on function public.list_staff_samples() to authenticated;
