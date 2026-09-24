-- Emisión desde la OA. Ejecutar después de 012_reconcile_lab_domain.sql.

create or replace function public.order_results_complete(p_order_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.samples where order_id = p_order_id)
     and not exists (
       select 1 from public.samples s
       where s.order_id = p_order_id
         and (
           (exists (select 1 from public.analysis_order_rows lr where lr.sample_id = s.id)
            and exists (
              select 1 from public.analysis_order_rows lr
              where lr.sample_id = s.id and (
                nullif(trim(coalesce(lr.result_value, '')), '') is null
                or lr.uncertainty is null
                or nullif(trim(coalesce(lr.analyst_reference, '')), '') is null
                or lr.result_date is null
                or nullif(trim(coalesce(lr.analyst_name, '')), '') is null
                or nullif(trim(coalesce(lr.released_by, '')), '') is null
              )
            ))
           or
           (not exists (select 1 from public.analysis_order_rows lr where lr.sample_id = s.id)
            and exists (
              select 1 from public.analysis_worksheets w
              join public.analysis_results r on r.worksheet_id = w.id
              where w.sample_id = s.id and (
                nullif(trim(coalesce(r.result_value, '')), '') is null
                or r.uncertainty is null
                or nullif(trim(coalesce(r.analyst_reference, '')), '') is null
                or r.analyzed_at is null
                or r.analyst_id is null
                or r.released_by_id is null
              )
            ))
         )
     );
$$;

create or replace function public.issue_report(p_order_id uuid, p_report_number text, p_pdf_path text default null)
returns public.reports language plpgsql security definer set search_path = public as $$
declare v_report public.reports; v_report_number text; v_sequence integer;
begin
  if auth.uid() is null or public.current_role() not in ('administrador', 'recepcion', 'revisor') then
    raise exception 'No tienes permiso para emitir informes';
  end if;
  if not public.order_results_complete(p_order_id) then
    raise exception 'Orden de análisis incompleta, revisar';
  end if;
  v_report_number := nullif(trim(coalesce(p_report_number, '')), '');
  if v_report_number is null then
    perform pg_advisory_xact_lock(extract(year from current_date)::integer + 100000);
    select count(*) + 1 into v_sequence
    from public.reports where extract(year from issued_at at time zone 'America/Mexico_City') = extract(year from current_date);
    v_report_number := format('INF-%s-%s', extract(year from current_date)::integer, lpad(v_sequence::text, 3, '0'));
  end if;
  insert into public.reports (order_id, report_number, issued_at, issued_by, pdf_path)
  values (p_order_id, v_report_number, now(), auth.uid(), p_pdf_path)
  on conflict (order_id, version) do update set
    report_number = excluded.report_number, issued_at = excluded.issued_at,
    issued_by = excluded.issued_by, pdf_path = excluded.pdf_path
  returning * into v_report;
  update public.analysis_orders
  set status = 'informe_emitido', issued_at = current_date, report_number = v_report_number, updated_at = now()
  where id = p_order_id;
  return v_report;
end;
$$;
