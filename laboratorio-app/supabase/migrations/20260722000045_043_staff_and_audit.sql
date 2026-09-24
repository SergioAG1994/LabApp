-- Stable credited personnel, database change history, and atomic worksheet saves.
-- This does not freeze reports or introduce correction versions.
begin;
set local lock_timeout = '5s';
alter table public.analysis_results
 add column analyst_staff_id uuid references public.laboratory_staff(id),
 add column released_by_staff_id uuid references public.laboratory_staff(id);
alter table public.analysis_orders add column sampler_staff_id uuid references public.laboratory_staff(id);
alter table public.analysis_worksheets add column revision bigint not null default 0 check(revision >= 0);
create index analysis_results_analyst_staff_idx on public.analysis_results(analyst_staff_id);
create index analysis_results_released_staff_idx on public.analysis_results(released_by_staff_id);
create index analysis_orders_sampler_staff_idx on public.analysis_orders(sampler_staff_id);

-- Link only unique exact normalized names/initials, including inactive historical
-- personnel. Preserve the original spelling; never infer the signed-in actor.
-- Table locks taken by ALTER prevent concurrent edits during these short, scoped
-- guard suspensions. Any error rolls back both data and trigger state.
alter table public.analysis_results disable trigger analysis_results_lock_exported_worksheet;
alter table public.analysis_orders disable trigger analysis_orders_protect_workflow;
update public.analysis_results r set analyst_staff_id=(
 select (array_agg(s.id))[1] from public.laboratory_staff s
 where lower(btrim(r.analyst_name)) in (lower(btrim(s.full_name)),lower(btrim(s.initials)))
 having count(*)=1)
where nullif(btrim(r.analyst_name),'') is not null;
update public.analysis_results r set released_by_staff_id=(
 select (array_agg(s.id))[1] from public.laboratory_staff s
 where lower(btrim(r.released_by)) in (lower(btrim(s.full_name)),lower(btrim(s.initials)))
 having count(*)=1)
where nullif(btrim(r.released_by),'') is not null;
update public.analysis_orders o set sampler_staff_id=(
 select (array_agg(s.id))[1] from public.laboratory_staff s
 where lower(btrim(o.sampler_name)) in (lower(btrim(s.full_name)),lower(btrim(s.initials)))
 having count(*)=1)
where nullif(btrim(o.sampler_name),'') is not null;
alter table public.analysis_results enable trigger analysis_results_lock_exported_worksheet;
alter table public.analysis_orders enable trigger analysis_orders_protect_workflow;

create function public.validate_credited_staff()
returns trigger language plpgsql security definer set search_path=public as $$
declare person public.laboratory_staff;
begin
 if tg_table_name='analysis_orders' then
  if new.sampler_staff_id is not null and (tg_op='INSERT' or new.sampler_staff_id is distinct from old.sampler_staff_id) then
   select * into person from public.laboratory_staff where id=new.sampler_staff_id for share;
   if not found or not person.active or not ('muestreador'=any(person.functions)) then raise exception 'Selecciona un muestreador activo'; end if;
   new.sampler_name:=person.full_name;
  elsif tg_op='UPDATE' and new.sampler_staff_id is not null and new.sampler_name is distinct from old.sampler_name then
   raise exception 'Cambia el personal seleccionado para cambiar la atribución';
  end if;
 else
  if new.analyst_staff_id is not null and (tg_op='INSERT' or new.analyst_staff_id is distinct from old.analyst_staff_id) then
   select * into person from public.laboratory_staff where id=new.analyst_staff_id for share;
   if not found or not person.active or not ('analista'=any(person.functions)) then raise exception 'Selecciona un analista activo'; end if;
   new.analyst_name:=person.initials;
  elsif tg_op='UPDATE' and new.analyst_staff_id is not null and new.analyst_name is distinct from old.analyst_name then
   raise exception 'Cambia el personal seleccionado para cambiar la atribución';
  end if;
  if new.released_by_staff_id is not null and (tg_op='INSERT' or new.released_by_staff_id is distinct from old.released_by_staff_id) then
   select * into person from public.laboratory_staff where id=new.released_by_staff_id for share;
   if not found or not person.active or not (person.functions && array['revisor','responsable_autorizacion']) then raise exception 'Selecciona un revisor activo'; end if;
   new.released_by:=person.initials;
  elsif tg_op='UPDATE' and new.released_by_staff_id is not null and new.released_by is distinct from old.released_by then
   raise exception 'Cambia el personal seleccionado para cambiar la atribución';
  end if;
 end if;
 new.updated_at:=clock_timestamp();
 return new;
end $$;
create trigger results_credited_staff before insert or update on public.analysis_results for each row execute function public.validate_credited_staff();
create trigger orders_credited_staff before insert or update on public.analysis_orders for each row execute function public.validate_credited_staff();

-- Revision changes cover legacy direct saves too. A complete save may advance
-- more than once; callers treat revision as an opaque monotonic token.
create function public.advance_worksheet_revision()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 if tg_table_name='analysis_orders' then
  if new.sampled_at is distinct from old.sampled_at then
   update public.analysis_worksheets set revision=revision+1,updated_at=clock_timestamp()
    where sample_id in(select id from public.samples where order_id=new.id);
  end if;
 elsif tg_op <> 'UPDATE' or (to_jsonb(new)-'updated_at') is distinct from (to_jsonb(old)-'updated_at') then
  update public.analysis_worksheets set revision=revision+1,updated_at=clock_timestamp()
   where id=case when tg_op='DELETE' then old.worksheet_id else new.worksheet_id end;
 end if;
 return null;
end $$;
create trigger results_advance_revision after insert or update or delete on public.analysis_results for each row execute function public.advance_worksheet_revision();
create trigger sampling_advance_revision after update of sampled_at on public.analysis_orders for each row execute function public.advance_worksheet_revision();

-- A caller cannot forge the revision even if table grants are expanded later.
create function public.protect_worksheet_revision()
returns trigger language plpgsql security invoker set search_path=public as $$
begin
 if new.revision is distinct from old.revision and current_user <> pg_get_userbyid((select proowner from pg_proc where oid='public.advance_worksheet_revision()'::regprocedure)) then
  raise exception 'La revisión de la hoja sólo cambia al guardar sus datos';
 end if;
 return new;
end $$;
create trigger worksheets_protect_revision before update on public.analysis_worksheets for each row execute function public.protect_worksheet_revision();

-- Generic history stores complete old/new records. Restrict reads because order,
-- client and report payloads can include information hidden from analysts.
create function public.record_database_change()
returns trigger language plpgsql security definer set search_path=public as $$
declare before_row jsonb; after_row jsonb; row_id uuid;
begin
 if tg_op<>'INSERT' then before_row:=to_jsonb(old); end if;
 if tg_op<>'DELETE' then after_row:=to_jsonb(new); end if;
 if tg_op='UPDATE' and (before_row-array['updated_at','revision']) is not distinct from (after_row-array['updated_at','revision']) then return null; end if;
 row_id:=coalesce(after_row->>'id',before_row->>'id')::uuid;
 insert into public.audit_events(actor_id,entity_type,entity_id,action,before_data,after_data,created_at)
 values(auth.uid(),tg_table_name,row_id,lower(tg_op),before_row,after_row,clock_timestamp());
 return null;
end $$;
do $$
declare table_name text;
begin
 foreach table_name in array array['analysis_results','analysis_orders','analysis_worksheets','samples','reports','report_drafts','parameters','laboratory_staff','clients','analysis_packages','package_parameters','multi_packages','multi_package_items'] loop
  execute format('create trigger record_change after insert or update or delete on public.%I for each row execute function public.record_database_change()',table_name);
 end loop;
end $$;
revoke all on public.audit_events from public,anon,authenticated;
grant select on public.audit_events to authenticated;
create policy "administrators and reviewers read audit history" on public.audit_events for select to authenticated
 using ((select public.current_role()) in ('administrador','revisor'));
create index audit_events_entity_time_idx on public.audit_events(entity_type,entity_id,created_at desc);

create function public.worksheet_sampled_at(p_sample_id uuid)
returns date language plpgsql stable security definer set search_path=public as $$
begin
 if auth.uid() is null or not coalesce(public.current_role() in ('administrador','recepcion','analista','revisor'),false) then raise exception 'No tienes permiso para consultar muestras'; end if;
 return (select o.sampled_at from public.samples s join public.analysis_orders o on o.id=s.order_id where s.id=p_sample_id);
end $$;
create or replace view public.worksheet_results with (security_invoker=true) as
select w.id as worksheet_id,w.sample_id,w.status,
 r.id as id,coalesce(r.display_order,pp.display_order) as display_order,
 coalesce(pp.row_type,'result') as row_type,
 p.id as parameter_id,p.name as label,p.unit,p.method_reference,
 r.result_value,r.uncertainty,r.analyst_reference,r.analyst_id,r.released_by_id,r.analyst_name,r.released_by,
 r.analyzed_at,p.par_form,r.analyst_staff_id,r.released_by_staff_id,w.revision as worksheet_revision,
 public.worksheet_sampled_at(w.sample_id) as worksheet_sampled_at
from public.analysis_worksheets w
join public.analysis_results r on r.worksheet_id=w.id
join public.samples s on s.id=w.sample_id
join public.parameters p on p.id=r.parameter_id
left join public.package_parameters pp on pp.package_id=s.package_id and pp.parameter_id=r.parameter_id;

create function public.save_analysis_worksheet(p_sample_id uuid,p_expected_revision bigint,p_rows jsonb,p_sampled_at date default null)
returns bigint language plpgsql security definer set search_path=public as $$
declare order_id uuid; worksheet public.analysis_worksheets; entry jsonb; previous public.analysis_results; role_name public.app_role;
begin
 role_name:=public.current_role();
 if auth.uid() is null or not coalesce(role_name in ('administrador','recepcion','analista','revisor'),false) then raise exception 'No tienes permiso para guardar resultados'; end if;
 if jsonb_typeof(p_rows) is distinct from 'array' or p_expected_revision is null then raise exception 'La hoja y su revisión son obligatorias'; end if;
 select s.order_id into order_id from public.samples s where s.id=p_sample_id;
 if not found then raise exception 'La muestra no existe'; end if;
 -- Match issuance lock ordering; validate stale state only after acquiring it.
 perform public.lock_editable_analysis_order(order_id);
 -- Legacy direct UPDATE locks its result row before its BEFORE trigger can
 -- acquire the parent. Never wait on those child locks while holding the parent:
 -- abort cleanly so the old writer can finish and the user can reload/retry.
 begin
  select * into worksheet from public.analysis_worksheets where sample_id=p_sample_id for update nowait;
  perform 1 from public.analysis_results where worksheet_id=worksheet.id order by id for update nowait;
 exception when lock_not_available then
  raise exception 'La hoja tiene cambios concurrentes. Recarga antes de guardar' using errcode='40001';
 end;
 if worksheet.id is null then raise exception 'La muestra no tiene hoja de resultados'; end if;
 if worksheet.revision<>p_expected_revision then raise exception 'La hoja cambió desde que la abriste. Recarga antes de guardar' using errcode='40001'; end if;
 if jsonb_array_length(p_rows)=0 or jsonb_array_length(p_rows)<>(select count(*) from public.analysis_results where worksheet_id=worksheet.id)
    or exists(select 1 from jsonb_array_elements(p_rows) x where jsonb_typeof(x)<>'object' or nullif(x->>'id','') is null)
    or (select count(distinct x->>'id') from jsonb_array_elements(p_rows) x)<>jsonb_array_length(p_rows) then
  raise exception 'Envía todos los resultados de la hoja una sola vez';
 end if;
 for entry in select value from jsonb_array_elements(p_rows) loop
  select * into previous from public.analysis_results where id=(entry->>'id')::uuid and worksheet_id=worksheet.id;
  if not found then raise exception 'El resultado no pertenece a esta hoja'; end if;
  if nullif(entry->>'analyst_staff_id','') is null and nullif(btrim(entry->>'analyst_name'),'') is not null
    and (entry->>'analyst_name' is distinct from previous.analyst_name or previous.analyst_staff_id is not null) then raise exception 'Selecciona al analista del directorio'; end if;
  if nullif(entry->>'released_by_staff_id','') is null and nullif(btrim(entry->>'released_by'),'') is not null
    and (entry->>'released_by' is distinct from previous.released_by or previous.released_by_staff_id is not null) then raise exception 'Selecciona al revisor del directorio'; end if;
  update public.analysis_results set
   uncertainty=nullif(entry->>'uncertainty','')::numeric,
   result_value=entry->>'result_value',analyst_reference=entry->>'analyst_reference',
   analyzed_at=nullif(entry->>'analyzed_at','')::date,
   analyst_name=entry->>'analyst_name',released_by=entry->>'released_by',
   analyst_staff_id=nullif(entry->>'analyst_staff_id','')::uuid,
   released_by_staff_id=nullif(entry->>'released_by_staff_id','')::uuid
  where id=previous.id;
 end loop;
 -- Analysts never mutate order details; their omitted date is not a clear action.
 if role_name in ('administrador','recepcion','revisor') then
  update public.analysis_orders set sampled_at=p_sampled_at where id=order_id and sampled_at is distinct from p_sampled_at;
 end if;
 return (select revision from public.analysis_worksheets where id=worksheet.id);
end $$;

create function public.create_sample_entry_batch_auto_with_staff(
 p_client_id uuid,p_samples jsonb,p_lab_sampling boolean,p_sampling_number text,p_received_at date,
 p_multi_package_id uuid default null,p_sampled_at date default null,p_sampler_name text default null,
 p_quotation_number text default null,p_billing_details text default null,p_precaptured boolean default false,
 p_sampler_staff_id uuid default null
) returns public.analysis_orders language plpgsql security definer set search_path=public as $$
declare result public.analysis_orders;
begin
 if auth.uid() is null or not coalesce(public.current_role() in ('administrador','recepcion'),false) then raise exception 'No tienes permiso para crear entradas de muestra'; end if;
 if p_lab_sampling and p_sampler_staff_id is null and nullif(btrim(p_sampler_name),'') is not null then raise exception 'Selecciona al muestreador del directorio'; end if;
 if not p_lab_sampling and p_sampler_staff_id is not null then raise exception 'No selecciones muestreador cuando no muestrea el laboratorio'; end if;
 result:=public.create_sample_entry_batch_auto_for_client(p_client_id,p_samples,p_lab_sampling,p_sampling_number,p_received_at,p_multi_package_id,p_sampled_at,p_sampler_name,p_quotation_number,p_billing_details,p_precaptured);
 if p_sampler_staff_id is not null then
  update public.analysis_orders set sampler_staff_id=p_sampler_staff_id where id=result.id returning * into result;
 end if;
 return result;
end $$;
revoke all on function public.validate_credited_staff(),public.advance_worksheet_revision(),public.protect_worksheet_revision(),public.record_database_change() from public,anon,authenticated;
revoke all on function public.worksheet_sampled_at(uuid),public.save_analysis_worksheet(uuid,bigint,jsonb,date),public.create_sample_entry_batch_auto_with_staff(uuid,jsonb,boolean,text,date,uuid,date,text,text,text,boolean,uuid) from public,anon;
grant execute on function public.worksheet_sampled_at(uuid),public.save_analysis_worksheet(uuid,bigint,jsonb,date),public.create_sample_entry_batch_auto_with_staff(uuid,jsonb,boolean,text,date,uuid,date,text,text,text,boolean,uuid) to authenticated;
commit;
