-- Align worksheet assignments with the personnel selectors.
-- Application account roles and sampler attribution stay unchanged.
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
   if not found or not person.active or not (person.functions && array['analista','muestreador']) then raise exception 'Selecciona un analista activo o un muestreador activo'; end if;
   new.analyst_name:=person.initials;
  elsif tg_op='UPDATE' and new.analyst_staff_id is not null and new.analyst_name is distinct from old.analyst_name then
   raise exception 'Cambia el personal seleccionado para cambiar la atribución';
  end if;
  if new.released_by_staff_id is not null and (tg_op='INSERT' or new.released_by_staff_id is distinct from old.released_by_staff_id) then
   select * into person from public.laboratory_staff where id=new.released_by_staff_id for share;
   if not found or not person.active or not (person.functions && array['revisor','responsable_autorizacion','analista','muestreador']) then raise exception 'Selecciona personal activo para Libera'; end if;
   new.released_by:=person.initials;
  elsif tg_op='UPDATE' and new.released_by_staff_id is not null and new.released_by is distinct from old.released_by then
   raise exception 'Cambia el personal seleccionado para cambiar la atribución';
  end if;
 end if;
 new.updated_at:=clock_timestamp();
 return new;
end $$;

-- Samplers can also be credited as analysts or in Libera.
create or replace function public.list_assignable_staff(p_functions text[])
returns table (
  id uuid,
  full_name text,
  initials text,
  active boolean,
  functions text[]
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null
     or (select public.current_role()) not in ('administrador', 'recepcion', 'analista') then
    raise exception 'No tienes permiso para consultar personal asignable';
  end if;
  if p_functions is null or cardinality(p_functions) = 0
     or not (p_functions <@ array['analista', 'muestreador', 'revisor', 'responsable_autorizacion']::text[]) then
    raise exception 'Tipo de asignación no válido';
  end if;

  return query
    select ls.id, ls.full_name, ls.initials, ls.active, ls.functions
    from public.laboratory_staff ls
    where ls.active and ls.functions && p_functions
    order by ls.full_name;
end;
$$;
