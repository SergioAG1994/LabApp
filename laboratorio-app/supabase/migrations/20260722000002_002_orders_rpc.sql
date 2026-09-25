-- Ejecutar después de schema.sql. Permite guardar la primera versión de OP reales.

alter table public.clients add constraint clients_name_unique unique (name);

create policy "reception manages clients"
on public.clients for all to authenticated
using (public.current_role() in ('administrador', 'recepcion'))
with check (public.current_role() in ('administrador', 'recepcion'));

insert into public.analysis_packages (code, name)
values
  ('NOM-001', 'NOM-001'),
  ('NOM-002', 'NOM-002'),
  ('NOM-003', 'NOM-003'),
  ('PERSONALIZADO', 'Personalizado')
on conflict (code) do nothing;

create or replace function public.create_analysis_order(
  p_client_name text,
  p_package_code text,
  p_sample_count integer,
  p_received_at date default current_date
)
returns public.analysis_orders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_client_id uuid;
  v_package_id uuid;
  v_order public.analysis_orders;
  v_next_number integer;
  v_index integer;
begin
  if auth.uid() is null or public.current_role() not in ('administrador', 'recepcion') then
    raise exception 'No tienes permiso para crear órdenes';
  end if;
  if trim(p_client_name) = '' then raise exception 'El cliente es obligatorio'; end if;
  if p_sample_count < 1 or p_sample_count > 20 then raise exception 'El número de muestras debe estar entre 1 y 20'; end if;

  insert into public.clients (name)
  values (trim(p_client_name))
  on conflict (name) do update set name = excluded.name
  returning id into v_client_id;

  select id into v_package_id from public.analysis_packages where code = p_package_code and active = true;
  if v_package_id is null then raise exception 'Tipo de análisis no válido'; end if;

  select count(*) + 1 into v_next_number
  from public.analysis_orders
  where extract(year from created_at at time zone 'America/Mexico_City') = extract(year from p_received_at);

  insert into public.analysis_orders (
    op_number, client_id, package_id, received_at, due_date, created_by
  ) values (
    format('OP-%s-%s', extract(year from p_received_at)::integer, lpad(v_next_number::text, 3, '0')),
    v_client_id, v_package_id, p_received_at, p_received_at + 18, auth.uid()
  ) returning * into v_order;

  for v_index in 1..p_sample_count loop
    insert into public.samples (order_id, sample_code)
    values (v_order.id, format('Muestra %s', v_index));
  end loop;

  insert into public.audit_events (actor_id, entity_type, entity_id, action, after_data)
  values (auth.uid(), 'analysis_order', v_order.id, 'created', jsonb_build_object('op_number', v_order.op_number));

  return v_order;
end;
$$;

grant execute on function public.create_analysis_order(text, text, integer, date) to authenticated;
