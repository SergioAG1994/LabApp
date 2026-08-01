-- Mantiene el indicador histórico de OA alineado con la OA real.
begin;

create or replace function public.sync_sample_worksheet()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.package_id is not null then
    perform public.create_worksheet_for_sample(new.id);

    update public.samples
    set analysis_order_created_at = coalesce(analysis_order_created_at, now())
    where id = new.id;
  end if;

  return new;
end;
$$;

-- Corrige muestras ya existentes que tienen OA real, pero el indicador anterior vacío.
update public.samples s
set analysis_order_created_at = coalesce(s.analysis_order_created_at, w.created_at)
from public.analysis_worksheets w
where w.sample_id = s.id
  and s.analysis_order_created_at is null;

commit;
