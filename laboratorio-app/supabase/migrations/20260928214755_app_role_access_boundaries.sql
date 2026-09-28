-- Define the three application access levels and keep operational staff data private.
begin;
set local lock_timeout = '5s';

do $$
begin
  if not exists (
       select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'analysis_worksheets' and column_name = 'revision'
     )
     or not exists (
       select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'analysis_results' and column_name = 'analyst_staff_id'
     )
     or not exists (
       select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'analysis_results' and column_name = 'result_input_kind'
     )
     or not exists (
       select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'analysis_orders' and column_name = 'sampler_staff_id'
     ) then
    raise exception 'Antes de aplicar estos permisos, aplica las migraciones de auditoría de personal y resultados estructurados (043 y 044).';
  end if;
end;
$$;

-- Older accounts used a separate reviewer role. Report issuance and reception
-- now belong to the same job, so preserve access by mapping those accounts to
-- reception before removing that role from the active policies.
update public.profiles
set role = 'recepcion'::public.app_role
where role = 'revisor'::public.app_role;

-- Profiles are visible to their owner and administrators. Only administrators
-- can assign access levels, and the check applies to the new row as well.
drop policy if exists "users read their profile" on public.profiles;
drop policy if exists "admins update profiles" on public.profiles;
create policy "users read their profile"
  on public.profiles for select to authenticated
  using (id = (select auth.uid()) or (select public.current_role()) = 'administrador');
create policy "admins update profiles"
  on public.profiles for update to authenticated
  using ((select public.current_role()) = 'administrador')
  with check ((select public.current_role()) = 'administrador');

-- Reception and administrators retain all work panels except personnel.
drop policy if exists "non analysts read client data" on public.clients;
drop policy if exists "authenticated can read operational data" on public.clients;
create policy "administration and reception read clients"
  on public.clients for select to authenticated
  using ((select public.current_role()) in ('administrador', 'recepcion'));

drop policy if exists "non analysts read orders" on public.analysis_orders;
drop policy if exists "authenticated can read orders" on public.analysis_orders;
create policy "administration and reception read orders"
  on public.analysis_orders for select to authenticated
  using ((select public.current_role()) in ('administrador', 'recepcion'));

drop policy if exists "authenticated can read samples" on public.samples;
-- The existing reception-manages-samples policy continues to grant this same
-- group all required sample operations.

drop policy if exists "authenticated can read reports" on public.reports;
create policy "administration and reception read reports"
  on public.reports for select to authenticated
  using ((select public.current_role()) in ('administrador', 'recepcion'));

-- Analysts do not need direct access to catalogs, client/order tables, or the
-- personnel directory. Their sample workspace is served by a narrow RPC below.
drop policy if exists "authenticated can read parameters" on public.parameters;
create policy "administration and reception read parameters"
  on public.parameters for select to authenticated
  using ((select public.current_role()) in ('administrador', 'recepcion'));

drop policy if exists "authenticated can read packages" on public.analysis_packages;
create policy "administration and reception read packages"
  on public.analysis_packages for select to authenticated
  using ((select public.current_role()) in ('administrador', 'recepcion'));

drop policy if exists "authenticated can read package parameters" on public.package_parameters;
create policy "administration and reception read package parameters"
  on public.package_parameters for select to authenticated
  using ((select public.current_role()) in ('administrador', 'recepcion'));

drop policy if exists "authenticated read samplers" on public.samplers;
create policy "administration and reception read samplers"
  on public.samplers for select to authenticated
  using ((select public.current_role()) in ('administrador', 'recepcion'));

drop policy if exists "staff read multi packages" on public.multi_packages;
drop policy if exists "authenticated read multi packages" on public.multi_packages;
create policy "administration and reception read multi packages"
  on public.multi_packages for select to authenticated
  using ((select public.current_role()) in ('administrador', 'recepcion'));

drop policy if exists "staff read multi package items" on public.multi_package_items;
drop policy if exists "authenticated read multi package items" on public.multi_package_items;
create policy "administration and reception read multi package items"
  on public.multi_package_items for select to authenticated
  using ((select public.current_role()) in ('administrador', 'recepcion'));

-- Analysts read and save worksheets through the authorized RPCs only. This
-- prevents direct Data API queries from exposing unrelated tables or orders.
drop policy if exists "analysts read worksheet results without client" on public.analysis_worksheets;
create policy "administration and reception read worksheets"
  on public.analysis_worksheets for select to authenticated
  using ((select public.current_role()) in ('administrador', 'recepcion'));

drop policy if exists "analysts read results" on public.analysis_results;
create policy "administration and reception read results"
  on public.analysis_results for select to authenticated
  using ((select public.current_role()) in ('administrador', 'recepcion'));

drop policy if exists "staff update results" on public.analysis_results;
create policy "administration and reception update results"
  on public.analysis_results for update to authenticated
  using ((select public.current_role()) in ('administrador', 'recepcion'))
  with check ((select public.current_role()) in ('administrador', 'recepcion'));

-- Personnel is an administrator-only panel. Other roles can use narrowly
-- scoped, active assignment lists needed by intake and worksheet workflows.
drop policy if exists "authenticated staff read laboratory personnel" on public.laboratory_staff;
drop policy if exists "administration creates laboratory personnel" on public.laboratory_staff;
drop policy if exists "administration updates laboratory personnel" on public.laboratory_staff;
create policy "administrators read laboratory personnel"
  on public.laboratory_staff for select to authenticated
  using ((select public.current_role()) = 'administrador');
create policy "administrators create laboratory personnel"
  on public.laboratory_staff for insert to authenticated
  with check ((select public.current_role()) = 'administrador');
create policy "administrators update laboratory personnel"
  on public.laboratory_staff for update to authenticated
  using ((select public.current_role()) = 'administrador')
  with check ((select public.current_role()) = 'administrador');
revoke all on public.laboratory_staff from anon, authenticated;
grant select, insert, update on public.laboratory_staff to authenticated;

drop policy if exists "report staff read drafts" on public.report_drafts;
drop policy if exists "report staff create drafts" on public.report_drafts;
drop policy if exists "report staff update drafts" on public.report_drafts;
create policy "administration and reception read drafts"
  on public.report_drafts for select to authenticated
  using ((select public.current_role()) in ('administrador', 'recepcion'));
create policy "administration and reception create drafts"
  on public.report_drafts for insert to authenticated
  with check ((select public.current_role()) in ('administrador', 'recepcion'));
create policy "administration and reception update drafts"
  on public.report_drafts for update to authenticated
  using ((select public.current_role()) in ('administrador', 'recepcion'))
  with check ((select public.current_role()) in ('administrador', 'recepcion'));

drop policy if exists "administrators and reviewers read audit history" on public.audit_events;
create policy "administrators read audit history"
  on public.audit_events for select to authenticated
  using ((select public.current_role()) = 'administrador');

-- Analysts may open only a sample worksheet after seeing it in their sample
-- panel. The definer function returns the existing safe view's result columns;
-- its explicit role and active-order checks guard the bypass of table RLS.
create or replace function public.load_staff_sample_worksheet(p_sample_id uuid)
returns setof public.worksheet_results
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null
     or (select public.current_role()) not in ('administrador', 'recepcion', 'analista') then
    raise exception 'No tienes permiso para consultar esta hoja de análisis';
  end if;

  if not exists (
    select 1
    from public.samples s
    join public.analysis_orders ao on ao.id = s.order_id
    where s.id = p_sample_id and ao.status <> 'cancelada'
  ) then
    raise exception 'La muestra no existe o no está disponible';
  end if;

  return query
    select wr.*
    from public.worksheet_results wr
    where wr.sample_id = p_sample_id
    order by wr.display_order;
end;
$$;

-- Return only active staff eligible for the requested operational assignment.
create or replace function public.list_assignable_staff(p_functions text[])
returns table (
  id uuid,
  full_name text,
  initials text,
  active boolean,
  functions text[]
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null
     or (select public.current_role()) not in ('administrador', 'recepcion', 'analista') then
    raise exception 'No tienes permiso para consultar personal asignable';
  end if;
  if p_functions is null or cardinality(p_functions) = 0
     or not (p_functions <@ array['analista', 'muestreador', 'revisor', 'responsable_autorizacion']::text[]) then
    raise exception 'Tipo de asignación no válido';
  end if;
  if (select public.current_role()) = 'analista'
     and not (p_functions <@ array['analista', 'revisor', 'responsable_autorizacion']::text[]) then
    raise exception 'Los analistas sólo pueden consultar asignaciones de análisis';
  end if;

  return query
    select ls.id, ls.full_name, ls.initials, ls.active, ls.functions
    from public.laboratory_staff ls
    where ls.active and ls.functions && p_functions
    order by ls.full_name;
end;
$$;

-- Report preview receives only the signatories already attributed to this
-- sample, rather than the laboratory's complete personnel directory.
create or replace function public.list_sample_report_staff(p_sample_id uuid)
returns table (
  id uuid,
  full_name text,
  initials text,
  position_title text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null
     or (select public.current_role()) not in ('administrador', 'recepcion') then
    raise exception 'No tienes permiso para consultar los datos del informe';
  end if;

  if not exists (
    select 1
    from public.samples s
    join public.analysis_orders ao on ao.id = s.order_id
    where s.id = p_sample_id and ao.status <> 'cancelada'
  ) then
    raise exception 'La muestra no existe o no está disponible';
  end if;

  return query
    with assigned_staff as (
      select ao.sampler_staff_id as staff_id
      from public.samples s
      join public.analysis_orders ao on ao.id = s.order_id
      where s.id = p_sample_id
      union
      select ar.analyst_staff_id as staff_id
      from public.analysis_worksheets aw
      join public.analysis_results ar on ar.worksheet_id = aw.id
      where aw.sample_id = p_sample_id
    )
    select ls.id, ls.full_name, ls.initials, ls.position_title
    from public.laboratory_staff ls
    join assigned_staff a on a.staff_id = ls.id
    order by ls.full_name;
end;
$$;

-- Keep the analyst sample list and worksheet-saving paths, but drop the retired
-- reviewer role from their authorization checks.
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
  where ao.status <> 'cancelada'
  group by ao.id, s.id, s.sample_code, s.analysis_label, ap.name, ap.code,
           ao.received_at, ao.due_date, s.analysis_order_created_at
  order by ao.received_at desc, s.sample_code desc;
end;
$$;

create or replace function public.worksheet_sampled_at(p_sample_id uuid)
returns date
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null
     or (select public.current_role()) not in ('administrador', 'recepcion', 'analista') then
    raise exception 'No tienes permiso para consultar muestras';
  end if;
  return (
    select ao.sampled_at
    from public.samples s
    join public.analysis_orders ao on ao.id = s.order_id
    where s.id = p_sample_id and ao.status <> 'cancelada'
  );
end;
$$;

create or replace function public.save_analysis_worksheet(
  p_sample_id uuid,
  p_expected_revision bigint,
  p_rows jsonb,
  p_sampled_at date default null
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  order_id uuid;
  worksheet public.analysis_worksheets;
  entry jsonb;
  previous public.analysis_results;
  role_name public.app_role;
begin
  role_name := public.current_role();
  if (select auth.uid()) is null
     or role_name not in ('administrador', 'recepcion', 'analista') then
    raise exception 'No tienes permiso para guardar resultados';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' or p_expected_revision is null then
    raise exception 'La hoja y su revisión son obligatorias';
  end if;

  select s.order_id into order_id from public.samples s where s.id = p_sample_id;
  if not found then raise exception 'La muestra no existe'; end if;
  perform public.lock_editable_analysis_order(order_id);

  begin
    select * into worksheet
    from public.analysis_worksheets
    where sample_id = p_sample_id
    for update nowait;
    perform 1 from public.analysis_results
      where worksheet_id = worksheet.id order by id for update nowait;
  exception when lock_not_available then
    raise exception 'La hoja tiene cambios concurrentes. Recarga antes de guardar' using errcode = '40001';
  end;

  if worksheet.id is null then raise exception 'La muestra no tiene hoja de resultados'; end if;
  if worksheet.revision <> p_expected_revision then
    raise exception 'La hoja cambió desde que la abriste. Recarga antes de guardar' using errcode = '40001';
  end if;
  if jsonb_array_length(p_rows) = 0
     or jsonb_array_length(p_rows) <> (select count(*) from public.analysis_results where worksheet_id = worksheet.id)
     or exists (select 1 from jsonb_array_elements(p_rows) x where jsonb_typeof(x) <> 'object' or nullif(x->>'id', '') is null)
     or (select count(distinct x->>'id') from jsonb_array_elements(p_rows) x) <> jsonb_array_length(p_rows) then
    raise exception 'Envía todos los resultados de la hoja una sola vez';
  end if;

  for entry in select value from jsonb_array_elements(p_rows) loop
    select * into previous
    from public.analysis_results
    where id = (entry->>'id')::uuid and worksheet_id = worksheet.id;
    if not found then raise exception 'El resultado no pertenece a esta hoja'; end if;
    if nullif(entry->>'analyst_staff_id', '') is null
       and nullif(btrim(entry->>'analyst_name'), '') is not null
       and (entry->>'analyst_name' is distinct from previous.analyst_name or previous.analyst_staff_id is not null) then
      raise exception 'Selecciona al analista del directorio';
    end if;
    if nullif(entry->>'released_by_staff_id', '') is null
       and nullif(btrim(entry->>'released_by'), '') is not null
       and (entry->>'released_by' is distinct from previous.released_by or previous.released_by_staff_id is not null) then
      raise exception 'Selecciona al revisor del directorio';
    end if;
    update public.analysis_results set
      uncertainty = nullif(entry->>'uncertainty', '')::numeric,
      result_value = entry->>'result_value',
      result_input_kind = case when entry ? 'result_input_kind' then entry->>'result_input_kind' else previous.result_input_kind end,
      analyst_reference = entry->>'analyst_reference',
      analyzed_at = nullif(entry->>'analyzed_at', '')::date,
      analyst_name = entry->>'analyst_name',
      released_by = entry->>'released_by',
      analyst_staff_id = nullif(entry->>'analyst_staff_id', '')::uuid,
      released_by_staff_id = nullif(entry->>'released_by_staff_id', '')::uuid
    where id = previous.id;
  end loop;

  if role_name in ('administrador', 'recepcion') then
    update public.analysis_orders
    set sampled_at = p_sampled_at
    where id = order_id and sampled_at is distinct from p_sampled_at;
  end if;

  return (select aw.revision from public.analysis_worksheets aw where aw.id = worksheet.id);
end;
$$;

create or replace function public.issue_report(p_order_id uuid, p_report_number text, p_pdf_path text default null)
returns public.reports
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_report public.reports;
  v_report_number text;
  v_sequence integer;
  v_year integer := extract(year from current_date)::integer;
begin
  if (select auth.uid()) is null
     or not coalesce((select public.current_role()) in ('administrador', 'recepcion'), false) then
    raise exception 'No tienes permiso para emitir informes';
  end if;
  perform 1 from public.analysis_orders where id = p_order_id for update;
  if not found then raise exception 'La orden no existe'; end if;
  if exists (select 1 from public.analysis_orders where id = p_order_id and status = 'cancelada') then
    raise exception 'No se puede emitir una orden cancelada';
  end if;
  if not public.order_results_complete(p_order_id) then
    raise exception 'Orden de análisis incompleta, revisar';
  end if;

  v_report_number := nullif(trim(coalesce(p_report_number, '')), '');
  if v_report_number is null then
    v_sequence := public.next_document_number('report', v_year);
    v_report_number := lpad(v_sequence::text, 4, '0');
  elsif v_report_number !~ '^[0-9]{4}$' then
    raise exception 'El número de informe debe contener exactamente cuatro dígitos';
  end if;

  insert into public.reports (order_id, report_number, report_year, issued_at, issued_by, pdf_path)
  values (p_order_id, v_report_number, v_year, now(), (select auth.uid()), p_pdf_path)
  on conflict (order_id, version) do update set
    report_number = excluded.report_number,
    report_year = excluded.report_year,
    issued_at = excluded.issued_at,
    issued_by = excluded.issued_by,
    pdf_path = excluded.pdf_path
  returning * into v_report;

  update public.analysis_orders
  set status = 'informe_emitido', issued_at = current_date,
      report_number = v_report_number, updated_at = now()
  where id = p_order_id;
  return v_report;
end;
$$;

-- The completeness helper is internal to report issuance; callers receive only
-- the resulting report workflow, not an oracle for arbitrary order IDs.
revoke all on function public.order_results_complete(uuid) from public, anon, authenticated;

revoke all on function public.list_staff_samples() from public, anon, authenticated;
revoke all on function public.load_staff_sample_worksheet(uuid) from public, anon, authenticated;
revoke all on function public.list_assignable_staff(text[]) from public, anon, authenticated;
revoke all on function public.list_sample_report_staff(uuid) from public, anon, authenticated;
revoke all on function public.worksheet_sampled_at(uuid) from public, anon, authenticated;
revoke all on function public.save_analysis_worksheet(uuid, bigint, jsonb, date) from public, anon, authenticated;
revoke all on function public.issue_report(uuid, text, text) from public, anon, authenticated;

grant execute on function public.list_staff_samples() to authenticated;
grant execute on function public.load_staff_sample_worksheet(uuid) to authenticated;
grant execute on function public.list_assignable_staff(text[]) to authenticated;
grant execute on function public.list_sample_report_staff(uuid) to authenticated;
grant execute on function public.worksheet_sampled_at(uuid) to authenticated;
grant execute on function public.save_analysis_worksheet(uuid, bigint, jsonb, date) to authenticated;
grant execute on function public.issue_report(uuid, text, text) to authenticated;

commit;
