begin;
set local lock_timeout = '5s';

-- Only reusable user-created templates may be retired here. No historical
-- order, sample, or parameter row is modified.
create function private.set_analysis_template_active(
  p_kind text, p_template_id uuid, p_active boolean
)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  previous_active boolean;
  template_name text;
  entity_kind text;
begin
  if (select auth.uid()) is null
     or not coalesce((select public.current_role()) in ('administrador', 'recepcion'), false) then
    raise exception 'No tienes permiso para administrar plantillas' using errcode = '42501';
  end if;
  if p_active is null or p_template_id is null then
    raise exception 'Indica la plantilla y su estado';
  end if;

  if p_kind = 'custom' then
    entity_kind := 'analysis_package';
    select active, name into previous_active, template_name
    from public.analysis_packages
    where id = p_template_id and starts_with(code, 'PERSONALIZADO-')
    for update;
    if not found then raise exception 'No se encontró el análisis personalizado'; end if;
    if previous_active = p_active then return p_active; end if;
    if p_active and exists (
      select 1 from public.analysis_packages
      where id <> p_template_id and active and lower(btrim(name)) = lower(btrim(template_name))
    ) then
      raise exception 'Ya existe un paquete activo con ese nombre';
    end if;
    update public.analysis_packages set active = p_active where id = p_template_id;
  elsif p_kind = 'multi' then
    entity_kind := 'multi_package';
    select active, name into previous_active, template_name
    from public.multi_packages where id = p_template_id for update;
    if not found then raise exception 'No se encontró el multipaquete'; end if;
    if previous_active = p_active then return p_active; end if;
    update public.multi_packages set active = p_active where id = p_template_id;
  else
    raise exception 'Tipo de plantilla no válido';
  end if;

  insert into public.audit_events (actor_id, entity_type, entity_id, action, before_data, after_data)
  values (auth.uid(), entity_kind, p_template_id,
    case when p_active then 'reactivated' else 'deactivated' end,
    jsonb_build_object('name', template_name, 'active', previous_active),
    jsonb_build_object('name', template_name, 'active', p_active));
  return p_active;
end;
$$;

-- Expose an invoker RPC; keep the privileged implementation out of the API schema.
create function public.set_analysis_template_active(
  p_kind text, p_template_id uuid, p_active boolean
)
returns boolean
language sql security invoker set search_path = '' as $$
  select private.set_analysis_template_active(p_kind, p_template_id, p_active)
$$;

revoke all on function private.set_analysis_template_active(text, uuid, boolean) from public, anon, authenticated;
revoke all on function public.set_analysis_template_active(text, uuid, boolean) from public, anon, authenticated;
grant usage on schema private to authenticated;
grant execute on function private.set_analysis_template_active(text, uuid, boolean) to authenticated;
grant execute on function public.set_analysis_template_active(text, uuid, boolean) to authenticated;
commit;
