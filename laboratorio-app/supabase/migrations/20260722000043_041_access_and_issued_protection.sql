-- Restrict application RPCs and serialize issuance with changes to its source data.
-- This does not add report snapshots or correction versions.
begin;

create or replace function public.get_client_by_number(p_client_number bigint)
returns public.clients
language plpgsql stable security definer set search_path = public as $$
declare v_client public.clients;
begin
  if auth.uid() is null or coalesce(public.current_role() in ('administrador', 'recepcion', 'revisor'), false) = false then
    raise exception 'No tienes permiso para consultar clientes';
  end if;
  select * into v_client from public.clients where client_number = p_client_number and active;
  return v_client;
end;
$$;

-- Internal helper. SECURITY DEFINER is essential: analysts cannot SELECT orders.
create or replace function public.lock_editable_analysis_order(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_order public.analysis_orders;
begin
  select * into v_order from public.analysis_orders where id = p_order_id for update;
  -- During an allowed cascading DELETE the parent is already gone.
  if not found then return; end if;
  if v_order.status = 'informe_emitido' or v_order.status_before_cancel = 'informe_emitido'
     or exists (select 1 from public.reports where order_id = p_order_id and issued_at is not null) then
    raise exception 'La orden de análisis ya fue exportada a informe y no puede modificarse sin iniciar una corrección de informe';
  end if;
end;
$$;

create or replace function public.prevent_exported_worksheet_changes()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_order_id uuid;
begin
  if tg_op = 'UPDATE' and (new.id is distinct from old.id
      or new.worksheet_id is distinct from old.worksheet_id
      or new.parameter_id is distinct from old.parameter_id) then
    raise exception 'No se puede cambiar la identidad ni la relación de un resultado';
  end if;
  select s.order_id into v_order_id
  from public.analysis_worksheets w join public.samples s on s.id = w.sample_id
  where w.id = case when tg_op = 'DELETE' then old.worksheet_id else new.worksheet_id end;
  perform public.lock_editable_analysis_order(v_order_id);
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create or replace function public.protect_analysis_source()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_order_id uuid;
begin
  if tg_table_name = 'samples' then
    if tg_op = 'UPDATE' and (new.id is distinct from old.id or new.order_id is distinct from old.order_id) then
      raise exception 'No se puede cambiar la identidad ni la orden de una muestra';
    end if;
    v_order_id := case when tg_op = 'DELETE' then old.order_id else new.order_id end;
  else
    if tg_op = 'UPDATE' and (new.id is distinct from old.id or new.sample_id is distinct from old.sample_id) then
      raise exception 'No se puede cambiar la identidad ni la muestra de una orden de análisis';
    end if;
    select order_id into v_order_id from public.samples
    where id = case when tg_op = 'DELETE' then old.sample_id else new.sample_id end;
  end if;
  perform public.lock_editable_analysis_order(v_order_id);
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create trigger samples_protect_issued_order before insert or update or delete on public.samples
for each row execute function public.protect_analysis_source();
create trigger worksheets_protect_issued_order before insert or update or delete on public.analysis_worksheets
for each row execute function public.protect_analysis_source();

-- Invoker security is deliberate here: current_user distinguishes ordinary DML
-- from the existing SECURITY DEFINER workflow RPCs. This is a database role,
-- not an application role or a caller-controlled session setting.
create or replace function public.protect_order_workflow()
returns trigger language plpgsql security invoker set search_path = public as $$
declare
  v_workflow_owner name;
  v_issued boolean;
begin
  select pg_get_userbyid(proowner) into v_workflow_owner from pg_proc
  where oid = 'public.issue_report(uuid,text,text)'::regprocedure;
  if tg_op = 'INSERT' then
    if new.status in ('informe_emitido', 'cancelada') or new.status_before_cancel is not null then
      raise exception 'Utiliza el proceso de emisión o baja para cambiar el estado';
    end if;
    return new;
  end if;
  v_issued := old.status = 'informe_emitido' or old.status_before_cancel = 'informe_emitido'
    or exists (select 1 from public.reports where order_id = old.id and issued_at is not null);
  if tg_op = 'DELETE' then
    if v_issued then raise exception 'No se puede eliminar una orden con informe emitido'; end if;
    return old;
  end if;
  if new.id is distinct from old.id then raise exception 'No se puede cambiar la identidad de una orden'; end if;
  if v_issued then
    -- Keep the existing authorized reissue/legacy restore paths, without
    -- permitting changes to the underlying order details or a cancellation.
    if current_user <> v_workflow_owner or new.status <> 'informe_emitido'
       or (to_jsonb(new) - array['status','status_before_cancel','cancelled_at','cancelled_by','issued_at','report_number','updated_at'])
          is distinct from
          (to_jsonb(old) - array['status','status_before_cancel','cancelled_at','cancelled_by','issued_at','report_number','updated_at']) then
      raise exception 'No se puede modificar una orden con informe emitido';
    end if;
  end if;
  if current_user <> v_workflow_owner and (
      (new.status is distinct from old.status and (new.status in ('informe_emitido', 'cancelada') or old.status = 'cancelada'))
      or new.status_before_cancel is distinct from old.status_before_cancel
      or new.cancelled_at is distinct from old.cancelled_at
      or new.cancelled_by is distinct from old.cancelled_by) then
    raise exception 'Utiliza el proceso de emisión, baja o restauración para cambiar el estado';
  end if;
  return new;
end;
$$;

drop trigger if exists analysis_orders_lock_exported_sampling on public.analysis_orders;
create trigger analysis_orders_protect_workflow before insert or update or delete on public.analysis_orders
for each row execute function public.protect_order_workflow();

create or replace function public.create_worksheet_for_sample(p_sample_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_worksheet_id uuid; v_package_id uuid; v_order_id uuid;
begin
  if auth.uid() is null or coalesce(public.current_role() in ('administrador', 'recepcion'), false) = false then
    raise exception 'No tienes permiso para generar órdenes de análisis';
  end if;
  select package_id, order_id into v_package_id, v_order_id from public.samples where id = p_sample_id;
  if v_package_id is null then raise exception 'La muestra no existe o no tiene paquete asignado'; end if;
  perform public.lock_editable_analysis_order(v_order_id);
  insert into public.analysis_worksheets (sample_id) values (p_sample_id)
  on conflict (sample_id) do update set updated_at = now() returning id into v_worksheet_id;
  insert into public.analysis_results (worksheet_id, parameter_id)
  select v_worksheet_id, pp.parameter_id from public.package_parameters pp where pp.package_id = v_package_id
  on conflict (worksheet_id, parameter_id) do nothing;
  return v_worksheet_id;
end;
$$;

create or replace function public.issue_report(p_order_id uuid, p_report_number text, p_pdf_path text default null)
returns public.reports language plpgsql security definer set search_path = public as $$
declare
  v_report public.reports;
  v_report_number text;
  v_sequence integer;
  v_year integer := extract(year from current_date)::integer;
begin
  if auth.uid() is null or not coalesce(public.current_role() in ('administrador', 'recepcion', 'revisor'), false) then
    raise exception 'No tienes permiso para emitir informes';
  end if;
  -- All result/sample/worksheet edits acquire this same lock. Validate only
  -- after acquiring it, so a concurrent save cannot invalidate issuance.
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
    perform pg_advisory_xact_lock(v_year + 100000);
    select coalesce(max(report_number::integer), 0) + 1
      into v_sequence
    from public.reports
    where report_year = v_year
      and report_number ~ '^[0-9]{4}$';
    if v_sequence > 9999 then
      raise exception 'Se agotó la numeración de informes para el año %', v_year;
    end if;
    v_report_number := lpad(v_sequence::text, 4, '0');
  elsif v_report_number !~ '^[0-9]{4}$' then
    raise exception 'El número de informe debe contener exactamente cuatro dígitos';
  end if;

  insert into public.reports (order_id, report_number, report_year, issued_at, issued_by, pdf_path)
  values (p_order_id, v_report_number, v_year, now(), auth.uid(), p_pdf_path)
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

revoke execute on function public.issue_report(uuid, text, text) from public, anon;
grant execute on function public.issue_report(uuid, text, text) to authenticated;

create or replace function public.delete_sample_entry_permanently(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not coalesce(public.current_role() in ('administrador', 'recepcion'), false) then
    raise exception 'No tienes permiso para eliminar registros definitivamente';
  end if;

  -- Check the report before deleting it, including legacy cancelled orders.
  perform public.lock_editable_analysis_order(p_order_id);
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

-- PostgreSQL grants new functions to PUBLIC by default. Remove anonymous access
-- for every privileged application function, including legacy entry points.
do $$
declare v_function record;
begin
  for v_function in
    select p.oid::regprocedure as signature from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef
  loop
    execute format('revoke execute on function %s from public, anon', v_function.signature);
  end loop;
end;
$$;
-- current_role is also called by RLS; retain authenticated execution explicitly.
grant execute on function public.current_role() to authenticated;
grant execute on function public.get_client_by_number(bigint) to authenticated;
grant execute on function public.create_worksheet_for_sample(uuid) to authenticated;
revoke execute on function public.lock_editable_analysis_order(uuid) from authenticated;
revoke execute on function public.prevent_exported_worksheet_changes() from authenticated;
revoke execute on function public.protect_analysis_source() from authenticated;
revoke execute on function public.protect_order_workflow() from public, anon, authenticated;

commit;
