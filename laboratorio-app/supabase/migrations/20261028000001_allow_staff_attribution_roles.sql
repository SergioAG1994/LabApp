-- Analyst attribution may include samplers, and the reviewer field is attribution
-- only: any active laboratory staff member may be selected there.
begin;
set local lock_timeout = '5s';

create or replace function public.validate_credited_staff()
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
   if not found or not person.active or not (person.functions && array['analista','muestreador']) then raise exception 'Selecciona un analista o muestreador activo'; end if;
   new.analyst_name:=person.initials;
  elsif tg_op='UPDATE' and new.analyst_staff_id is not null and new.analyst_name is distinct from old.analyst_name then
   raise exception 'Cambia el personal seleccionado para cambiar la atribución';
  end if;
  if new.released_by_staff_id is not null and (tg_op='INSERT' or new.released_by_staff_id is distinct from old.released_by_staff_id) then
   select * into person from public.laboratory_staff where id=new.released_by_staff_id for share;
   if not found or not person.active then raise exception 'Selecciona un integrante activo del personal'; end if;
   new.released_by:=person.initials;
  elsif tg_op='UPDATE' and new.released_by_staff_id is not null and new.released_by is distinct from old.released_by then
   raise exception 'Cambia el personal seleccionado para cambiar la atribución';
  end if;
 end if;
 new.updated_at:=clock_timestamp();
 return new;
end $$;

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
  where s.active
    and ('revisor' = any(p_functions) or s.functions && p_functions)
    and (role_name <> 'analista' or s.id = (select private.current_analyst_staff_id()))
  order by s.full_name;
end;
$$;

commit;
