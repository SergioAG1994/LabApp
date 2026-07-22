-- Eliminación definitiva desde la bandeja de OPs eliminados.
create or replace function public.delete_sample_entry_permanently(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or public.current_role() not in ('administrador', 'recepcion') then
    raise exception 'No tienes permiso para eliminar registros definitivamente';
  end if;

  if not exists (select 1 from public.analysis_orders where id = p_order_id and status = 'cancelada') then
    raise exception 'Sólo se pueden eliminar definitivamente registros que estén en la bandeja de bajas';
  end if;

  delete from public.reports where order_id = p_order_id;
  delete from public.analysis_orders where id = p_order_id;

  insert into public.audit_events (actor_id, entity_type, entity_id, action)
  values (auth.uid(), 'sample_intake', p_order_id, 'permanently_deleted');
end;
$$;

grant execute on function public.delete_sample_entry_permanently(uuid) to authenticated;
