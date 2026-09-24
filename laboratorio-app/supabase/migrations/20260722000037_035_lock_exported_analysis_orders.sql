-- Impide modificar una OA después de exportarla a informe.
-- El desbloqueo deberá hacerse posteriormente mediante el proceso formal de
-- corrección de informe, no mediante actualizaciones directas de resultados.

create or replace function public.prevent_exported_worksheet_changes()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_worksheet_id uuid;
  v_order_status public.order_status;
begin
  v_worksheet_id := case when tg_op = 'DELETE' then old.worksheet_id else new.worksheet_id end;

  select ao.status
    into v_order_status
  from public.analysis_worksheets aw
  join public.samples s on s.id = aw.sample_id
  join public.analysis_orders ao on ao.id = s.order_id
  where aw.id = v_worksheet_id;

  if v_order_status = 'informe_emitido' then
    raise exception 'La orden de análisis ya fue exportada a informe y no puede modificarse sin iniciar una corrección de informe';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists analysis_results_lock_exported_worksheet on public.analysis_results;
create trigger analysis_results_lock_exported_worksheet
before insert or update or delete on public.analysis_results
for each row execute function public.prevent_exported_worksheet_changes();

create or replace function public.prevent_exported_order_sampling_change()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if old.status = 'informe_emitido'
     and new.sampled_at is distinct from old.sampled_at then
    raise exception 'La orden de análisis ya fue exportada a informe y no puede modificarse sin iniciar una corrección de informe';
  end if;
  return new;
end;
$$;

drop trigger if exists analysis_orders_lock_exported_sampling on public.analysis_orders;
create trigger analysis_orders_lock_exported_sampling
before update on public.analysis_orders
for each row execute function public.prevent_exported_order_sampling_change();
