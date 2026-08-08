-- Genera números de muestra AAMMDD-#### dentro de la misma transacción de alta.
begin;

set local lock_timeout = '5s';

create unique index if not exists samples_sample_code_unique
  on public.samples (sample_code);

create or replace function public.create_sample_entry_batch_auto(
  p_client_name text,
  p_samples jsonb,
  p_lab_sampling boolean,
  p_sampling_number text,
  p_received_at date,
  p_multi_package_id uuid default null,
  p_sampled_at date default null,
  p_sampler_name text default null,
  p_quotation_number text default null,
  p_billing_details text default null,
  p_precaptured boolean default false
)
returns public.analysis_orders
language plpgsql security definer set search_path = public as $$
declare
  v_year text;
  v_date_prefix text;
  v_sequence integer;
  v_sample jsonb;
  v_position integer;
  v_numbered_samples jsonb := '[]'::jsonb;
begin
  if auth.uid() is null or public.current_role() not in ('administrador', 'recepcion') then
    raise exception 'No tienes permiso para crear entradas de muestra';
  end if;
  if p_received_at is null then
    raise exception 'La fecha de recepción es obligatoria';
  end if;
  if jsonb_typeof(p_samples) <> 'array'
     or jsonb_array_length(p_samples) not between 1 and 20 then
    raise exception 'La OP debe contener entre 1 y 20 muestras';
  end if;

  v_year := to_char(p_received_at, 'YY');
  v_date_prefix := to_char(p_received_at, 'YYMMDD');

  -- La misma llave anual serializa altas simultáneas y evita consecutivos repetidos.
  perform pg_advisory_xact_lock(extract(year from p_received_at)::integer);

  select coalesce(max(substring(s.sample_code from 8 for 4)::integer), 0)
    into v_sequence
  from public.samples s
  where s.sample_code ~ ('^' || v_year || '[0-9]{4}-[0-9]{4}$');

  if v_sequence + jsonb_array_length(p_samples) > 9999 then
    raise exception 'Se agotó el consecutivo anual de muestras para %', extract(year from p_received_at)::integer;
  end if;

  for v_sample, v_position in
    select value, ordinality::integer
    from jsonb_array_elements(p_samples) with ordinality
  loop
    v_numbered_samples := v_numbered_samples || jsonb_build_array(
      (v_sample - 'sample_number') || jsonb_build_object(
        'sample_number',
        v_date_prefix || '-' || lpad((v_sequence + v_position)::text, 4, '0')
      )
    );
  end loop;

  return public.create_sample_entry_batch(
    p_client_name,
    v_numbered_samples,
    p_lab_sampling,
    p_sampling_number,
    p_received_at,
    p_multi_package_id,
    p_sampled_at,
    p_sampler_name,
    p_quotation_number,
    p_billing_details,
    p_precaptured
  );
end;
$$;

revoke execute on function public.create_sample_entry_batch_auto(
  text, jsonb, boolean, text, date, uuid, date, text, text, text, boolean
) from public, anon;
grant execute on function public.create_sample_entry_batch_auto(
  text, jsonb, boolean, text, date, uuid, date, text, text, text, boolean
) to authenticated;

commit;
