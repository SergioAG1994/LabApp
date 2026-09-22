-- Permite convertir una selección personalizada de parámetros en un paquete reutilizable.
begin;

create or replace function public.save_custom_analysis_package(
  p_name text,
  p_parameter_ids jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_package_id uuid;
  v_parameter_id text;
  v_display_order integer := 0;
  v_valid_parameter_count integer;
begin
  if auth.uid() is null
     or public.current_role() not in ('administrador', 'recepcion') then
    raise exception 'No tienes permiso para guardar paquetes personalizados';
  end if;

  if nullif(btrim(coalesce(p_name, '')), '') is null then
    raise exception 'El nombre del paquete es obligatorio';
  end if;

  if jsonb_typeof(p_parameter_ids) <> 'array'
     or jsonb_array_length(p_parameter_ids) = 0 then
    raise exception 'Selecciona al menos un parámetro';
  end if;

  if (select count(distinct value)
      from jsonb_array_elements_text(p_parameter_ids)) <> jsonb_array_length(p_parameter_ids) then
    raise exception 'Un parámetro no puede repetirse dentro del paquete';
  end if;

  if exists (
    select 1
    from public.analysis_packages
    where lower(btrim(name)) = lower(btrim(p_name))
      and active = true
  ) then
    raise exception 'Ya existe un paquete activo con ese nombre';
  end if;

  select count(*) into v_valid_parameter_count
  from public.parameters p
  join jsonb_array_elements_text(p_parameter_ids) selected(parameter_id)
    on p.id::text = selected.parameter_id
  where p.active = true;

  if v_valid_parameter_count <> jsonb_array_length(p_parameter_ids) then
    raise exception 'Uno o más parámetros no son válidos o están inactivos';
  end if;

  insert into public.analysis_packages (code, name, active, package_type)
  values (
    'PERSONALIZADO-' || upper(replace(gen_random_uuid()::text, '-', '')),
    btrim(p_name),
    true,
    'cliente'
  )
  returning id into v_package_id;

  for v_parameter_id in
    select value from jsonb_array_elements_text(p_parameter_ids)
  loop
    v_display_order := v_display_order + 1;
    insert into public.package_parameters (
      package_id, parameter_id, display_order, row_type
    ) values (
      v_package_id, v_parameter_id::uuid, v_display_order, 'result'
    );
  end loop;

  insert into public.audit_events (actor_id, entity_type, entity_id, action, after_data)
  values (
    auth.uid(),
    'analysis_package',
    v_package_id,
    'created',
    jsonb_build_object(
      'name', btrim(p_name),
      'package_type', 'cliente',
      'parameter_count', jsonb_array_length(p_parameter_ids)
    )
  );

  return v_package_id;
end;
$$;

revoke execute on function public.save_custom_analysis_package(text, jsonb) from public, anon;
grant execute on function public.save_custom_analysis_package(text, jsonb) to authenticated;

commit;
