-- Add explicit field-sampling variants and select them whenever the laboratory
-- performs sampling. MF muestreo is included in every laboratory-sampled OA.
-- Deployment version matches the Supabase migration ledger.
begin;
set local lock_timeout = '5s';

update public.parameters field_parameter
set par_form = source_parameter.par_form,
    unit = source_parameter.unit,
    method_reference = source_parameter.method_reference,
    decimal_places = source_parameter.decimal_places,
    result_kind = source_parameter.result_kind,
    assigned_analyst_id = source_parameter.assigned_analyst_id,
    active = true
from public.parameters source_parameter
where source_parameter.name = 'pH'
  and field_parameter.name = 'pH muestreo';

insert into public.parameters (
  name, par_form, unit, method_reference, decimal_places, result_kind,
  assigned_analyst_id, active
)
select 'CE muestreo', par_form, unit, method_reference, decimal_places,
       result_kind, assigned_analyst_id, true
from public.parameters where name = 'CE'
on conflict (name) do update set
  par_form = excluded.par_form,
  unit = excluded.unit,
  method_reference = excluded.method_reference,
  decimal_places = excluded.decimal_places,
  result_kind = excluded.result_kind,
  active = true;

insert into public.parameters (
  name, par_form, unit, method_reference, decimal_places, result_kind,
  assigned_analyst_id, active
)
select 'Temperatura muestreo', par_form, unit, method_reference,
       decimal_places, result_kind, assigned_analyst_id, true
from public.parameters where name = 'Temperatura'
on conflict (name) do update set
  par_form = excluded.par_form,
  unit = excluded.unit,
  method_reference = excluded.method_reference,
  decimal_places = excluded.decimal_places,
  result_kind = excluded.result_kind,
  active = true;

insert into public.parameters (
  name, par_form, unit, method_reference, decimal_places, result_kind,
  assigned_analyst_id, active
)
select 'MF muestreo', par_form, unit, method_reference, decimal_places,
       result_kind, assigned_analyst_id, true
from public.parameters where name = 'MF'
on conflict (name) do update set
  par_form = excluded.par_form,
  unit = excluded.unit,
  method_reference = excluded.method_reference,
  decimal_places = excluded.decimal_places,
  result_kind = excluded.result_kind,
  active = true;

do $$
begin
  if not exists (select 1 from public.parameters where name = 'pH muestreo' and active) then
    raise exception 'No se encontró el parámetro activo pH muestreo';
  end if;
  if (select count(distinct name) from public.parameters
      where name in ('CE','Temperatura','MF') and active) <> 3 then
    raise exception 'Faltan parámetros base CE, Temperatura o MF';
  end if;
  if (select count(distinct name) from public.parameters
      where name in ('CE muestreo','Temperatura muestreo','MF muestreo') and active) <> 3 then
    raise exception 'No se pudieron crear los parámetros de muestreo';
  end if;
end;
$$;

create or replace function private.field_sampling_parameter_id(p_parameter_id uuid)
returns uuid
language sql stable security definer set search_path = '' as $$
  select coalesce((
    select field_parameter.id
    from public.parameters source_parameter
    join public.parameters field_parameter
      on field_parameter.name = case source_parameter.name
        when 'pH' then 'pH muestreo'
        when 'pH muestreo' then 'pH muestreo'
        when 'CE' then 'CE muestreo'
        when 'CE muestreo' then 'CE muestreo'
        when 'Temperatura' then 'Temperatura muestreo'
        when 'Temperatura muestreo' then 'Temperatura muestreo'
        when 'MF' then 'MF muestreo'
        when 'MF muestreo' then 'MF muestreo'
        else null
      end
     and field_parameter.active
    where source_parameter.id = p_parameter_id
    limit 1
  ), p_parameter_id)
$$;
revoke all on function private.field_sampling_parameter_id(uuid) from public, anon, authenticated;

-- Authorization is recorded against the laboratory's canonical parameter
-- (e.g. CE), while the worksheet uses its field-sampling variant (CE muestreo).
-- Treat both catalog rows as the same competency without duplicating personnel
-- authorization records or changing their historical dates/methods.
create or replace function private.parameter_authorization_family(p_parameter_id uuid)
returns text
language sql stable security definer set search_path = '' as $$
  select case p.name
    when 'pH' then 'pH'
    when 'pH muestreo' then 'pH'
    when 'CE' then 'CE'
    when 'CE muestreo' then 'CE'
    when 'Temperatura' then 'Temperatura'
    when 'Temperatura muestreo' then 'Temperatura'
    when 'MF' then 'MF'
    when 'MF muestreo' then 'MF'
    else 'parameter:' || p.id::text
  end
  from public.parameters p where p.id = p_parameter_id
$$;
revoke all on function private.parameter_authorization_family(uuid) from public, anon, authenticated;

create or replace function private.has_current_internal_parameter_authorization(p_parameter_id uuid)
returns boolean
language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and exists (
    select 1
    from public.profiles p
    join public.laboratory_staff s on s.id = p.laboratory_staff_id and s.active
    join public.staff_parameter_authorizations a on a.staff_id = p.laboratory_staff_id
    where p.id = (select auth.uid())
      and p.role = 'analista'::public.app_role
      and a.authorization_kind = 'internal'
      and a.authorized_at <= (now() at time zone 'America/Mexico_City')::date
      and private.parameter_authorization_family(a.parameter_id)
          = private.parameter_authorization_family(p_parameter_id)
  )
$$;
revoke all on function private.has_current_internal_parameter_authorization(uuid) from public, anon;
grant execute on function private.has_current_internal_parameter_authorization(uuid) to authenticated;

create or replace function private.ensure_field_sampling_result(p_worksheet_id uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  sample_row public.samples;
  field_mf_id uuid;
  next_display_order integer;
begin
  select s.* into sample_row
  from public.analysis_worksheets w
  join public.samples s on s.id = w.sample_id
  where w.id = p_worksheet_id;
  if not found or nullif(btrim(sample_row.sampling_number), '') is null
     or upper(btrim(sample_row.sampling_number)) = 'N/A' then
    return;
  end if;

  select id into field_mf_id from public.parameters
  where name = 'MF muestreo' and active;
  if field_mf_id is null or exists (
    select 1 from public.analysis_results
    where worksheet_id = p_worksheet_id and parameter_id = field_mf_id
  ) then
    return;
  end if;

  select greatest(
    coalesce((select max(r.display_order) from public.analysis_results r where r.worksheet_id = p_worksheet_id), 0),
    coalesce((select max(pp.display_order) from public.package_parameters pp where pp.package_id = sample_row.package_id), 0),
    coalesce((select max(mpi.display_order) from public.multi_package_items mpi
      where mpi.multi_package_id = sample_row.multi_package_id
        and mpi.sample_position = sample_row.multi_package_sample_position), 0)
  ) + 100 into next_display_order;

  insert into public.analysis_results (worksheet_id, parameter_id, display_order)
  values (p_worksheet_id, field_mf_id, next_display_order)
  on conflict (worksheet_id, parameter_id) do nothing;
end;
$$;
revoke all on function private.ensure_field_sampling_result(uuid) from public, anon, authenticated;

create or replace function public.create_worksheet_for_sample(p_sample_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_worksheet_id uuid;
  v_package_id uuid;
  v_order_id uuid;
  v_sampling_number text;
begin
  if auth.uid() is null or not coalesce(public.current_role() in ('administrador', 'recepcion'), false) then
    raise exception 'No tienes permiso para generar órdenes de análisis';
  end if;
  select package_id, order_id, sampling_number
    into v_package_id, v_order_id, v_sampling_number
  from public.samples where id = p_sample_id;
  if not found or v_package_id is null then
    raise exception 'La muestra no existe o no tiene paquete asignado';
  end if;
  perform public.lock_editable_analysis_order(v_order_id);
  insert into public.analysis_worksheets (sample_id)
  values (p_sample_id)
  on conflict (sample_id) do update set updated_at = now()
  returning id into v_worksheet_id;

  if nullif(btrim(v_sampling_number), '') is not null and upper(btrim(v_sampling_number)) <> 'N/A' then
    insert into public.analysis_results (worksheet_id, parameter_id, display_order)
    select v_worksheet_id, mapped.parameter_id, min(mapped.display_order)
    from (
      select private.field_sampling_parameter_id(pp.parameter_id) as parameter_id,
             pp.display_order
      from public.package_parameters pp
      where pp.package_id = v_package_id
    ) mapped
    group by mapped.parameter_id
    order by min(mapped.display_order) nulls last
    on conflict (worksheet_id, parameter_id) do nothing;
  else
    insert into public.analysis_results (worksheet_id, parameter_id, display_order)
    select v_worksheet_id, pp.parameter_id, pp.display_order
    from public.package_parameters pp
    where pp.package_id = v_package_id
    on conflict (worksheet_id, parameter_id) do nothing;
  end if;

  perform private.ensure_field_sampling_result(v_worksheet_id);
  return v_worksheet_id;
end;
$$;
revoke all on function public.create_worksheet_for_sample(uuid) from public, anon, authenticated;
grant execute on function public.create_worksheet_for_sample(uuid) to authenticated;

create or replace function public.create_sample_entry_batch_for_client(
  p_client_id uuid,
  p_samples jsonb,
  p_lab_sampling boolean,
  p_sampling_number text,
  p_received_at date,
  p_multi_package_id uuid default null,
  p_sampled_at date default null,
  p_sampler_name text default null,
  p_quotation_number text default null,
  p_billing_details text default null,
  p_precaptured boolean default false,
  p_auto_number boolean default false
)
returns public.analysis_orders
language plpgsql security definer set search_path = public as $$
declare
  v_client_id uuid;
  v_sample_sequence integer;
  v_order public.analysis_orders;
  v_sequence integer;
  v_prefix text;
  v_sampling_number text;
  v_sample jsonb;
  v_position integer;
  v_sample_id uuid;
  v_worksheet_id uuid;
  v_package_id uuid;
  v_analysis_label text;
  v_parameter text;
  v_parameter_id uuid;
  v_display_order integer;
  v_multi public.multi_packages;
begin
  if auth.uid() is null or not coalesce(public.current_role() in ('administrador', 'recepcion'), false) then
    raise exception 'No tienes permiso para crear entradas de muestra';
  end if;
  if p_client_id is null then raise exception 'El cliente es obligatorio'; end if;
  if p_received_at is null then raise exception 'La fecha de recepción es obligatoria'; end if;
  if p_samples is null or jsonb_typeof(p_samples) <> 'array'
     or jsonb_array_length(p_samples) not between 1 and 20 then
    raise exception 'La OP debe contener entre 1 y 20 muestras';
  end if;

  select id into v_client_id from public.clients where id = p_client_id and active;
  if v_client_id is null then raise exception 'No se encontró un cliente activo con esa referencia'; end if;

  v_sampling_number := case when p_lab_sampling
    then nullif(btrim(coalesce(p_sampling_number, '')), '') else 'N/A' end;
  if p_lab_sampling and v_sampling_number is null then
    raise exception 'El número de muestreo es obligatorio cuando muestrea el laboratorio';
  end if;

  if p_multi_package_id is not null then
    select * into v_multi from public.multi_packages where id = p_multi_package_id and active = true;
    if v_multi.id is null then raise exception 'Multipaquete no válido'; end if;
    if v_multi.sample_count <> jsonb_array_length(p_samples) then
      raise exception 'El multipaquete requiere % muestras', v_multi.sample_count;
    end if;
  end if;

  if p_auto_number then
    select jsonb_agg(value - 'sample_number' order by ordinality) into p_samples
    from jsonb_array_elements(p_samples) with ordinality;
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_samples) with ordinality a(value, ordinality)
    join jsonb_array_elements(p_samples) with ordinality b(value, ordinality)
      on a.value->>'sample_number' = b.value->>'sample_number' and a.ordinality < b.ordinality
  ) then raise exception 'Los números de muestra no pueden repetirse'; end if;
  if exists (select 1 from public.samples s join jsonb_array_elements(p_samples) x
      on s.sample_code = btrim(x.value->>'sample_number')) then
    raise exception 'Uno o más números de muestra ya existen';
  end if;
  if extract(year from p_received_at) not between 2000 and 2099 then
    raise exception 'La numeración actual admite fechas de 2000 a 2099';
  end if;
  v_sequence := public.next_document_number('order', extract(year from p_received_at)::integer);
  if p_auto_number then
    v_sample_sequence := public.next_document_number('sample', extract(year from p_received_at)::integer, jsonb_array_length(p_samples));
  end if;
  v_prefix := '2' || to_char(p_received_at, 'YY') || to_char(p_received_at, 'MM');

  insert into public.analysis_orders (
    op_number, client_id, multi_package_id, sampling_number, sampler_name,
    quotation_number, billing_details, precaptured, received_at, sampled_at,
    due_date, created_by
  ) values (
    v_prefix || lpad(v_sequence::text, 3, '0'), v_client_id, p_multi_package_id,
    v_sampling_number, nullif(btrim(p_sampler_name), ''),
    nullif(btrim(p_quotation_number), ''), nullif(btrim(p_billing_details), ''),
    p_precaptured, p_received_at, p_sampled_at,
    public.calculate_due_date(p_received_at, 8), auth.uid()
  ) returning * into v_order;

  for v_sample, v_position in
    select value, ordinality::integer from jsonb_array_elements(p_samples) with ordinality
  loop
    if p_auto_number then
      v_sample := v_sample || jsonb_build_object('sample_number', to_char(p_received_at,'YYMMDD') || '-' || lpad((v_sample_sequence+v_position-1)::text,4,'0'));
    end if;
    if nullif(btrim(coalesce(v_sample->>'sample_number', '')), '') is null then
      raise exception 'El número de la muestra % es obligatorio', v_position;
    end if;

    v_package_id := null;
    if p_multi_package_id is null and nullif(v_sample->>'package_id', '') is not null then
      select id, name into v_package_id, v_analysis_label
      from public.analysis_packages where id = (v_sample->>'package_id')::uuid and active = true;
      if v_package_id is null then raise exception 'Paquete no válido en la muestra %', v_position; end if;
    elsif p_multi_package_id is not null then
      v_analysis_label := v_multi.name || ' · Muestra ' || v_position;
    else
      v_analysis_label := 'Selección personalizada';
      if jsonb_typeof(v_sample->'parameter_ids') <> 'array'
         or jsonb_array_length(v_sample->'parameter_ids') = 0 then
        raise exception 'Selecciona parámetros para la muestra %', v_position;
      end if;
    end if;

    insert into public.samples (
      order_id, sample_code, package_id, sampling_number, multi_package_id,
      multi_package_sample_position, analysis_label
    ) values (
      v_order.id, btrim(v_sample->>'sample_number'), v_package_id, v_sampling_number,
      p_multi_package_id, case when p_multi_package_id is null then null else v_position end,
      v_analysis_label
    ) returning id into v_sample_id;

    if v_package_id is not null then
      -- The sample trigger normally creates this worksheet; calling the function
      -- also covers installations where that trigger was not yet installed.
      select id into v_worksheet_id from public.analysis_worksheets where sample_id = v_sample_id;
      if v_worksheet_id is null then
        v_worksheet_id := public.create_worksheet_for_sample(v_sample_id);
      end if;
      perform private.ensure_field_sampling_result(v_worksheet_id);
      update public.samples set analysis_order_created_at = coalesce(analysis_order_created_at, now())
      where id = v_sample_id;
    else
      insert into public.analysis_worksheets (sample_id, received_at)
      values (v_sample_id, p_received_at) returning id into v_worksheet_id;

      if p_multi_package_id is not null then
        insert into public.analysis_results (worksheet_id, parameter_id, display_order)
        select v_worksheet_id, selected.parameter_id, min(selected.display_order)
        from (
          select case when p_lab_sampling
                   then private.field_sampling_parameter_id(mpi.parameter_id)
                   else mpi.parameter_id end as parameter_id,
                 mpi.display_order
          from public.multi_package_items mpi
          join public.parameters p on p.id = mpi.parameter_id and p.active
          where mpi.multi_package_id = p_multi_package_id and mpi.sample_position = v_position
        ) selected
        group by selected.parameter_id
        order by min(selected.display_order)
        on conflict (worksheet_id, parameter_id) do nothing;
        if not found then raise exception 'La muestra % del multipaquete no tiene parámetros válidos', v_position; end if;
      else
        v_display_order := 0;
        for v_parameter in select jsonb_array_elements_text(v_sample->'parameter_ids')
        loop
          select p.id into v_parameter_id from public.parameters p
          where p.id = v_parameter::uuid and p.active;
          if not found then raise exception 'Parámetro inválido en la muestra %', v_position; end if;
          if p_lab_sampling then
            v_parameter_id := private.field_sampling_parameter_id(v_parameter_id);
          end if;
          if not exists (select 1 from public.analysis_results r
            where r.worksheet_id = v_worksheet_id and r.parameter_id = v_parameter_id) then
            v_display_order := v_display_order + 1;
            insert into public.analysis_results (worksheet_id, parameter_id, display_order)
            values (v_worksheet_id, v_parameter_id, v_display_order)
            on conflict (worksheet_id, parameter_id) do nothing;
          end if;
        end loop;
      end if;
      perform private.ensure_field_sampling_result(v_worksheet_id);
      update public.samples set analysis_order_created_at = now() where id = v_sample_id;
    end if;
  end loop;

  insert into public.audit_events (actor_id, entity_type, entity_id, action, after_data)
  values (auth.uid(), 'sample_intake', v_order.id, 'created_batch',
          jsonb_build_object('op_number', v_order.op_number,
                             'sample_count', jsonb_array_length(p_samples),
                             'multi_package_id', p_multi_package_id,
                             'lab_sampling', p_lab_sampling,
                             'client_id', v_client_id));
  return v_order;
end;
$$;

revoke all on function public.create_sample_entry_batch_for_client(uuid,jsonb,boolean,text,date,uuid,date,text,text,text,boolean,boolean) from public, anon, authenticated;


-- Keep worksheet reads and saves aligned for field variants.
create or replace function public.save_analysis_worksheet(
  p_sample_id uuid, p_expected_revision bigint, p_rows jsonb, p_sampled_at date default null
)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  order_id uuid; worksheet public.analysis_worksheets; entry jsonb; previous public.analysis_results;
  role_name public.app_role := (select public.current_role());
  v_analyst_staff_id uuid := (select private.current_analyst_staff_id());
  expected_rows integer;
begin
  if role_name is null or (select auth.uid()) is null or role_name not in ('administrador', 'recepcion', 'analista') then
    raise exception 'No tienes permiso para guardar resultados';
  end if;
  if role_name = 'analista' and v_analyst_staff_id is null then raise exception 'Tu cuenta no está vinculada con tu ficha de Personal'; end if;
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
    and (role_name <> 'analista' or (select private.has_current_internal_parameter_authorization(ar.parameter_id)));
  if expected_rows = 0 or jsonb_array_length(p_rows) <> expected_rows
     or exists (select 1 from jsonb_array_elements(p_rows) x where jsonb_typeof(x) <> 'object' or nullif(x->>'id', '') is null)
     or (select count(distinct x->>'id') from jsonb_array_elements(p_rows) x) <> jsonb_array_length(p_rows) then
    raise exception 'Envía todas las filas que tienes autorizadas, una sola vez';
  end if;
  for entry in select value from jsonb_array_elements(p_rows) loop
    select * into previous from public.analysis_results ar
    where ar.id = (entry->>'id')::uuid and ar.worksheet_id = worksheet.id
      and (role_name <> 'analista' or (select private.has_current_internal_parameter_authorization(ar.parameter_id)));
    if not found then raise exception 'Un resultado no pertenece a tus parámetros autorizados'; end if;
    if role_name = 'analista' then
      update public.analysis_results set
        uncertainty = nullif(entry->>'uncertainty', '')::numeric,
        result_value = entry->>'result_value',
        result_input_kind = case when entry ? 'result_input_kind' then entry->>'result_input_kind' else previous.result_input_kind end,
        analyst_reference = entry->>'analyst_reference', analyzed_at = nullif(entry->>'analyzed_at', '')::date,
        analyst_name = case
          when previous.analyst_staff_id = v_analyst_staff_id
            and nullif(btrim(previous.analyst_name), '') is not null then previous.analyst_name
          else (select s.initials from public.laboratory_staff s where s.id = v_analyst_staff_id)
        end,
        analyst_staff_id = v_analyst_staff_id
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
revoke all on function public.save_analysis_worksheet(uuid,bigint,jsonb,date) from public,anon,authenticated;
grant execute on function public.save_analysis_worksheet(uuid,bigint,jsonb,date) to authenticated;

commit;
