begin;
set local lock_timeout = '5s';
do $$
begin
  if to_regclass('public.staff_parameter_authorizations') is null
     or not exists (select 1 from information_schema.columns where table_schema='public' and table_name='analysis_worksheets' and column_name='revision')
     or not exists (select 1 from information_schema.columns where table_schema='public' and table_name='analysis_results' and column_name='analyst_staff_id')
     or not exists (select 1 from information_schema.columns where table_schema='public' and table_name='analysis_results' and column_name='result_input_kind') then
    raise exception 'Faltan migraciones requeridas: personal_authorizations, 043_staff_and_audit y 044_structured_results. Sincroniza primero el esquema remoto.';
  end if;
end;
$$;

alter table public.profiles
  add column laboratory_staff_id uuid references public.laboratory_staff(id) on delete restrict;
create unique index profiles_laboratory_staff_id_key
  on public.profiles(laboratory_staff_id) where laboratory_staff_id is not null;
alter table public.profiles
  add constraint profiles_staff_link_only_analyst
  check (laboratory_staff_id is null or role = 'analista'::public.app_role);

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create function private.current_analyst_staff_id()
returns uuid language sql stable security definer set search_path = '' as $$
  select p.laboratory_staff_id
  from public.profiles p
  where p.id = (select auth.uid())
    and p.role = 'analista'::public.app_role
$$;
revoke all on function private.current_analyst_staff_id() from public, anon;
grant execute on function private.current_analyst_staff_id() to authenticated;

create function private.has_current_internal_parameter_authorization(p_parameter_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and exists (
    select 1
    from public.profiles p
    join public.laboratory_staff s on s.id = p.laboratory_staff_id and s.active
    join public.staff_parameter_authorizations a on a.staff_id = p.laboratory_staff_id
    where p.id = (select auth.uid())
      and p.role = 'analista'::public.app_role
      and a.authorization_kind = 'internal'
      and a.parameter_id = p_parameter_id
      and a.authorized_at <= (now() at time zone 'America/Mexico_City')::date
  )
$$;
revoke all on function private.has_current_internal_parameter_authorization(uuid) from public, anon;
grant execute on function private.has_current_internal_parameter_authorization(uuid) to authenticated;

create function private.validate_profile_staff_link()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.role = 'analista'::public.app_role then
    if new.laboratory_staff_id is null or not exists (
      select 1 from public.laboratory_staff s
      where s.id = new.laboratory_staff_id and s.active and 'analista' = any(s.functions)
    ) then
      raise exception 'Vincula la cuenta con una persona activa del directorio cuya función sea Analista';
    end if;
  elsif new.laboratory_staff_id is not null then
    raise exception 'Solo las cuentas Analista pueden vincularse con una persona de laboratorio';
  end if;
  return new;
end;
$$;
revoke all on function private.validate_profile_staff_link() from public, anon, authenticated;
grant execute on function private.validate_profile_staff_link() to authenticated;
create trigger validate_profile_staff_link
  before insert or update of role, laboratory_staff_id on public.profiles
  for each row execute function private.validate_profile_staff_link();

-- An analyst can read only their own current internal authorizations. EMA
-- authorizations are intentionally excluded from execution permissions.
create policy "analysts read own current internal authorizations"
  on public.staff_parameter_authorizations for select to authenticated
  using (
    authorization_kind = 'internal'
    and authorized_at <= (now() at time zone 'America/Mexico_City')::date
    and staff_id = (select private.current_analyst_staff_id())
  );

-- Defense in depth for direct Data API access; analysts still use the narrow
-- worksheet RPC for their normal workflow.
create policy "analysts read authorized results"
  on public.analysis_results for select to authenticated
  using (
    (select public.current_role()) = 'analista'
    and (select private.has_current_internal_parameter_authorization(parameter_id))
  );
drop policy if exists "analysts read results" on public.analysis_results;
drop policy if exists "analysts read worksheet results without client" on public.analysis_worksheets;
create policy "analysts read worksheets with authorized results"
  on public.analysis_worksheets for select to authenticated
  using (
    (select public.current_role()) = 'analista'
    and exists (
      select 1 from public.analysis_results r
      where r.worksheet_id = analysis_worksheets.id
        and (select private.has_current_internal_parameter_authorization(r.parameter_id))
    )
  );
create policy "analysts read authorized parameters"
  on public.parameters for select to authenticated
  using (
    (select public.current_role()) = 'analista'
    and (select private.has_current_internal_parameter_authorization(id))
  );

create or replace function public.load_staff_sample_worksheet(p_sample_id uuid)
returns setof public.worksheet_results
language plpgsql stable security definer set search_path = '' as $$
declare role_name public.app_role := (select public.current_role());
begin
  if (role_name is null or (select auth.uid()) is null
     or role_name not in ('administrador', 'recepcion', 'analista') then
    raise exception 'No tienes permiso para consultar esta hoja de análisis';
  end if;
  if not exists (
    select 1 from public.samples s join public.analysis_orders ao on ao.id = s.order_id
    where s.id = p_sample_id and ao.status not in ('cancelada', 'informe_emitido')
      and ao.report_number is null
  ) then
    raise exception 'La muestra no existe o no está disponible';
  end if;
  return query
    select wr.* from public.worksheet_results wr
    where wr.sample_id = p_sample_id
      and (role_name <> 'analista' or (select private.has_current_internal_parameter_authorization(wr.parameter_id)))
    order by wr.display_order;
end;
$$;
revoke all on function public.load_staff_sample_worksheet(uuid) from public, anon, authenticated;
grant execute on function public.load_staff_sample_worksheet(uuid) to authenticated;

create or replace function public.list_staff_samples()
returns table (
  order_id uuid, sample_id uuid, sample_code text, analysis_label text,
  received_at date, due_date date, analysis_order_created_at timestamptz,
  total_results integer, captured_results integer, completion_percent integer
)
language plpgsql stable security definer set search_path = '' as $$
declare role_name public.app_role := (select public.current_role());
begin
  if role_name is null or (select auth.uid()) is null or role_name not in ('administrador', 'recepcion', 'analista') then
    raise exception 'No tienes permiso para consultar muestras';
  end if;
  return query
  select ao.id, s.id, s.sample_code,
    coalesce(nullif(btrim(s.analysis_label), ''), ap.name, ap.code, 'Sin análisis'),
    ao.received_at::date, ao.due_date::date, s.analysis_order_created_at,
    count(ar.id) filter (where role_name <> 'analista' or
      (select private.has_current_internal_parameter_authorization(ar.parameter_id)))::integer,
    count(ar.id) filter (where (role_name <> 'analista' or
      (select private.has_current_internal_parameter_authorization(ar.parameter_id)))
      and nullif(btrim(coalesce(ar.result_value, '')), '') is not null)::integer,
    case when count(ar.id) filter (where role_name <> 'analista' or
      (select private.has_current_internal_parameter_authorization(ar.parameter_id))) = 0 then 0
    else round(100.0 * count(ar.id) filter (where (role_name <> 'analista' or
      (select private.has_current_internal_parameter_authorization(ar.parameter_id)))
      and nullif(btrim(coalesce(ar.result_value, '')), '') is not null) /
      count(ar.id) filter (where role_name <> 'analista' or
      (select private.has_current_internal_parameter_authorization(ar.parameter_id))))::integer end
  from public.samples s
  join public.analysis_orders ao on ao.id = s.order_id
  left join public.analysis_packages ap on ap.id = s.package_id
  left join public.analysis_worksheets aw on aw.sample_id = s.id
  left join public.analysis_results ar on ar.worksheet_id = aw.id
  where ao.status not in ('cancelada', 'informe_emitido') and ao.report_number is null
    and (role_name <> 'analista' or exists (
      select 1 from public.analysis_results authorized_result
      where authorized_result.worksheet_id = aw.id
        and (select private.has_current_internal_parameter_authorization(authorized_result.parameter_id))
    ))
  group by ao.id, s.id, s.sample_code, s.analysis_label, ap.name, ap.code,
    ao.received_at, ao.due_date, s.analysis_order_created_at
  order by ao.received_at desc, s.sample_code desc;
end;
$$;
revoke all on function public.list_staff_samples() from public, anon, authenticated;
grant execute on function public.list_staff_samples() to authenticated;

create or replace function public.list_completed_staff_samples()
returns table (sample_id uuid, sample_code text, received_at date, issued_at date, report_number text)
language plpgsql stable security definer set search_path = '' as $$
declare role_name public.app_role := (select public.current_role());
begin
  if role_name is null or (select auth.uid()) is null or role_name not in ('administrador', 'recepcion', 'analista') then
    raise exception 'No tienes permiso para consultar muestras terminadas';
  end if;
  return query
  select s.id, s.sample_code, ao.received_at::date, r.issued_at::date, r.report_number
  from public.samples s
  join public.analysis_orders ao on ao.id = s.order_id
  join public.reports r on r.order_id = ao.id
  where ao.status = 'informe_emitido' and r.issued_at is not null
    and nullif(btrim(r.report_number), '') is not null
    and (role_name <> 'analista' or exists (
      select 1 from public.analysis_worksheets w
      join public.analysis_results ar on ar.worksheet_id = w.id
      where w.sample_id = s.id
        and (select private.has_current_internal_parameter_authorization(ar.parameter_id))
    ))
  order by r.issued_at desc, s.sample_code desc;
end;
$$;
revoke all on function public.list_completed_staff_samples() from public, anon, authenticated;
grant execute on function public.list_completed_staff_samples() to authenticated;

create or replace function public.list_assignable_staff(p_functions text[])
returns table (id uuid, full_name text, initials text, active boolean, functions text[])
language plpgsql stable security definer set search_path = '' as $$
declare role_name public.app_role := (select public.current_role());
begin
  if role_name is null or (select auth.uid()) is null or role_name not in ('administrador', 'recepcion', 'analista') then
    raise exception 'No tienes permiso para consultar personal asignable';
  end if;
  if p_functions is null or cardinality(p_functions) = 0 then
    raise exception 'Selecciona al menos una función';
  end if;
  return query
  select s.id, s.full_name, s.initials, s.active, s.functions
  from public.laboratory_staff s
  where s.active and s.functions && p_functions
    and (role_name <> 'analista' or s.id = (select private.current_analyst_staff_id()))
  order by s.full_name;
end;
$$;
revoke all on function public.list_assignable_staff(text[]) from public, anon, authenticated;
grant execute on function public.list_assignable_staff(text[]) to authenticated;

create or replace function public.save_analysis_worksheet(
  p_sample_id uuid, p_expected_revision bigint, p_rows jsonb, p_sampled_at date default null
)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  order_id uuid; worksheet public.analysis_worksheets; entry jsonb; previous public.analysis_results;
  role_name public.app_role := (select public.current_role());
  analyst_id uuid := (select private.current_analyst_staff_id());
  expected_rows integer;
begin
  if role_name is null or (select auth.uid()) is null or role_name not in ('administrador', 'recepcion', 'analista') then
    raise exception 'No tienes permiso para guardar resultados';
  end if;
  if role_name = 'analista' and analyst_id is null then raise exception 'Tu cuenta no está vinculada con tu ficha de Personal'; end if;
  if jsonb_typeof(p_rows) is distinct from 'array' or p_expected_revision is null then
    raise exception 'La hoja y su revisión son obligatorias';
  end if;
  select s.order_id into order_id from public.samples s where s.id = p_sample_id;
  if not found then raise exception 'La muestra no existe'; end if;
  perform public.lock_editable_analysis_order(order_id);
  begin
    select * into worksheet from public.analysis_worksheets where sample_id = p_sample_id for update nowait;
    perform 1 from public.analysis_results where worksheet_id = worksheet.id order by id for update nowait;
  exception when lock_not_available then
    raise exception 'La hoja tiene cambios concurrentes. Recarga antes de guardar' using errcode = '40001';
  end;
  if worksheet.id is null then raise exception 'La muestra no tiene hoja de resultados'; end if;
  if worksheet.revision <> p_expected_revision then
    raise exception 'La hoja cambió desde que la abriste. Recarga antes de guardar' using errcode = '40001';
  end if;
  select count(*)::integer into expected_rows from public.analysis_results ar
  where ar.worksheet_id = worksheet.id
    and (role_name <> 'analista' or exists (
      select 1 from public.staff_parameter_authorizations a
      where a.staff_id = analyst_id and a.parameter_id = ar.parameter_id
        and a.authorization_kind = 'internal' and a.authorized_at <= (now() at time zone 'America/Mexico_City')::date
    ));
  if expected_rows = 0 or jsonb_array_length(p_rows) <> expected_rows
     or exists (select 1 from jsonb_array_elements(p_rows) x where jsonb_typeof(x) <> 'object' or nullif(x->>'id', '') is null)
     or (select count(distinct x->>'id') from jsonb_array_elements(p_rows) x) <> jsonb_array_length(p_rows) then
    raise exception 'Envía todas las filas que tienes autorizadas, una sola vez';
  end if;
  for entry in select value from jsonb_array_elements(p_rows) loop
    select * into previous from public.analysis_results ar
    where ar.id = (entry->>'id')::uuid and ar.worksheet_id = worksheet.id
      and (role_name <> 'analista' or exists (
        select 1 from public.staff_parameter_authorizations a
        where a.staff_id = analyst_id and a.parameter_id = ar.parameter_id
          and a.authorization_kind = 'internal' and a.authorized_at <= (now() at time zone 'America/Mexico_City')::date
      ));
    if not found then raise exception 'Un resultado no pertenece a tus parámetros autorizados'; end if;
    if role_name = 'analista' then
      update public.analysis_results set
        uncertainty = nullif(entry->>'uncertainty', '')::numeric,
        result_value = entry->>'result_value',
        result_input_kind = case when entry ? 'result_input_kind' then entry->>'result_input_kind' else previous.result_input_kind end,
        analyst_reference = entry->>'analyst_reference', analyzed_at = nullif(entry->>'analyzed_at', '')::date,
        analyst_name = (select s.initials from public.laboratory_staff s where s.id = analyst_id),
        analyst_staff_id = analyst_id
      where id = previous.id;
    else
      if nullif(entry->>'analyst_staff_id', '') is null and nullif(btrim(entry->>'analyst_name'), '') is not null
         and (entry->>'analyst_name' is distinct from previous.analyst_name or previous.analyst_staff_id is not null) then
        raise exception 'Selecciona al analista del directorio';
      end if;
      if nullif(entry->>'released_by_staff_id', '') is null and nullif(btrim(entry->>'released_by'), '') is not null
         and (entry->>'released_by' is distinct from previous.released_by or previous.released_by_staff_id is not null) then
        raise exception 'Selecciona al revisor del directorio';
      end if;
      update public.analysis_results set
        uncertainty = nullif(entry->>'uncertainty', '')::numeric,
        result_value = entry->>'result_value',
        result_input_kind = case when entry ? 'result_input_kind' then entry->>'result_input_kind' else previous.result_input_kind end,
        analyst_reference = entry->>'analyst_reference', analyzed_at = nullif(entry->>'analyzed_at', '')::date,
        analyst_name = entry->>'analyst_name', released_by = entry->>'released_by',
        analyst_staff_id = nullif(entry->>'analyst_staff_id', '')::uuid,
        released_by_staff_id = nullif(entry->>'released_by_staff_id', '')::uuid
      where id = previous.id;
    end if;
  end loop;
  if role_name in ('administrador', 'recepcion') then
    update public.analysis_orders set sampled_at = p_sampled_at
    where id = order_id and sampled_at is distinct from p_sampled_at;
  end if;
  return (select aw.revision from public.analysis_worksheets aw where aw.id = worksheet.id);
end;
$$;
revoke all on function public.save_analysis_worksheet(uuid, bigint, jsonb, date) from public, anon, authenticated;
grant execute on function public.save_analysis_worksheet(uuid, bigint, jsonb, date) to authenticated;

commit;
