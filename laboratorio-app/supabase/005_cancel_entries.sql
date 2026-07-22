-- Baja lógica de una entrada: preserva la evidencia y el historial de auditoría.
alter table public.analysis_orders
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid references public.profiles(id);

create or replace function public.cancel_sample_entry(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or public.current_role() not in ('administrador', 'recepcion') then
    raise exception 'No tienes permiso para dar de baja registros';
  end if;

  update public.analysis_orders
  set status = 'cancelada', cancelled_at = now(), cancelled_by = auth.uid(), updated_at = now()
  where id = p_order_id and status <> 'cancelada';

  if not found then raise exception 'La entrada no existe o ya fue dada de baja'; end if;

  insert into public.audit_events (actor_id, entity_type, entity_id, action)
  values (auth.uid(), 'sample_intake', p_order_id, 'cancelled');
end;
$$;

grant execute on function public.cancel_sample_entry(uuid) to authenticated;
