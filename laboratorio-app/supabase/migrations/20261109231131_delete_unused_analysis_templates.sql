begin;
set local lock_timeout = '5s';

create function private.delete_analysis_template(p_kind text, p_template_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  template_name text;
  template_active boolean;
  entity_kind text;
begin
  if (select auth.uid()) is null
     or not coalesce((select public.current_role()) in ('administrador', 'recepcion'), false) then
    raise exception 'No tienes permiso para eliminar plantillas' using errcode = '42501';
  end if;

  -- The existing foreign keys protect historical orders even if an order is
  -- created concurrently. Only the template's own parameter links cascade.
  begin
    if p_kind = 'custom' then
      entity_kind := 'analysis_package';
      delete from public.analysis_packages
        where id = p_template_id and starts_with(code, 'PERSONALIZADO-')
        returning name, active into template_name, template_active;
    elsif p_kind = 'multi' then
      entity_kind := 'multi_package';
      delete from public.multi_packages where id = p_template_id
        returning name, active into template_name, template_active;
    else
      raise exception 'Tipo de plantilla no válido';
    end if;
    if not found then raise exception 'No se encontró una plantilla eliminable'; end if;
  exception when foreign_key_violation then
    raise exception 'Esta plantilla está vinculada a órdenes o muestras existentes. Puedes desactivarla para que no aparezca en altas nuevas.'
      using errcode = '23503';
  end;

  insert into public.audit_events (actor_id, entity_type, entity_id, action, before_data)
  values (auth.uid(), entity_kind, p_template_id, 'deleted',
    jsonb_build_object('name', template_name, 'active', template_active));
end;
$$;

create function public.delete_analysis_template(p_kind text, p_template_id uuid)
returns void language sql security invoker set search_path = '' as $$
  select private.delete_analysis_template(p_kind, p_template_id)
$$;

revoke all on function private.delete_analysis_template(text, uuid) from public, anon, authenticated;
revoke all on function public.delete_analysis_template(text, uuid) from public, anon, authenticated;
grant execute on function private.delete_analysis_template(text, uuid) to authenticated;
grant execute on function public.delete_analysis_template(text, uuid) to authenticated;
commit;
