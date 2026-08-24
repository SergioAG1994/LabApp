-- Permite varias sucursales por razón social sin sobrescribir clientes existentes.
begin;

set local lock_timeout = '5s';

alter table public.clients
  drop constraint if exists clients_name_unique;

drop index if exists public.clients_name_unique;

create unique index if not exists clients_name_branch_unique
  on public.clients (
    lower(btrim(name)),
    lower(coalesce(nullif(btrim(branch), ''), ''))
  );

create or replace function public.create_client(
  p_name text,
  p_contact_name text default null,
  p_email text default null,
  p_phone text default null,
  p_address text default null,
  p_rfc text default null,
  p_attention_to text default null,
  p_branch text default null
)
returns public.clients
language plpgsql
security definer
set search_path = public
as $$
declare
  v_client public.clients;
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_branch text := nullif(btrim(coalesce(p_branch, '')), '');
begin
  if auth.uid() is null or public.current_role() not in ('administrador', 'recepcion') then
    raise exception 'No tienes permiso para dar de alta clientes';
  end if;
  if v_name is null then
    raise exception 'El nombre del cliente es obligatorio';
  end if;
  if exists (
    select 1
    from public.clients c
    where lower(btrim(c.name)) = lower(v_name)
      and lower(coalesce(nullif(btrim(c.branch), ''), '')) = lower(coalesce(v_branch, ''))
  ) then
    raise exception 'Ya existe el cliente % con la sucursal %', v_name, coalesce(v_branch, 'sin especificar');
  end if;

  insert into public.clients (
    name, branch, contact_name, email, phone, address, rfc, attention_to
  ) values (
    v_name, v_branch, nullif(btrim(p_contact_name), ''), nullif(btrim(p_email), ''),
    nullif(btrim(p_phone), ''), nullif(btrim(p_address), ''), nullif(btrim(p_rfc), ''),
    nullif(btrim(p_attention_to), '')
  )
  returning * into v_client;

  return v_client;
exception
  when unique_violation then
    raise exception 'Ya existe el cliente % con la sucursal %', v_name, coalesce(v_branch, 'sin especificar');
end;
$$;

revoke execute on function public.create_client(text, text, text, text, text, text, text, text)
  from public, anon;
grant execute on function public.create_client(text, text, text, text, text, text, text, text)
  to authenticated;

create or replace function public.create_sample_entry_batch(
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
  v_client_id uuid;
  v_client_matches integer;
  v_order public.analysis_orders;
  v_sequence integer;
  v_prefix text;
  v_sampling_number text;
  v_sample jsonb;
  v_position integer;
  v_sample_id uuid;
  v_worksheet_id uuid;
  v_package_id uuid;
  v_analysis_label text;
  v_parameter text;
  v_display_order integer;
  v_multi public.multi_packages;
begin
  if auth.uid() is null or public.current_role() not in ('administrador', 'recepcion') then
    raise exception 'No tienes permiso para crear entradas de muestra';
  end if;
  if nullif(btrim(coalesce(p_client_name, '')), '') is null then
    raise exception 'El cliente es obligatorio';
  end if;
  if p_received_at is null then
    raise exception 'La fecha de recepción es obligatoria';
  end if;
  if jsonb_typeof(p_samples) <> 'array'
     or jsonb_array_length(p_samples) not between 1 and 20 then
    raise exception 'La OP debe contener entre 1 y 20 muestras';
  end if;

  if btrim(p_client_name) ~ '^[0-9]+$' then
    select c.id into v_client_id
    from public.clients c
    where c.client_number = btrim(p_client_name)::bigint
      and c.active = true;
  else
    select count(*), min(c.id)
      into v_client_matches, v_client_id
    from public.clients c
    where lower(btrim(c.name)) = lower(btrim(p_client_name))
      and c.active = true;
    if v_client_matches > 1 then
      raise exception 'La razón social tiene varias sucursales; selecciona el número de cliente';
    end if;
  end if;
  if v_client_id is null then
    raise exception 'No se encontró un cliente activo con esa referencia';
  end if;

  v_sampling_number := case
    when p_lab_sampling then nullif(btrim(coalesce(p_sampling_number, '')), '')
    else 'N/A'
  end;
  if p_lab_sampling and v_sampling_number is null then
    raise exception 'El número de muestreo es obligatorio cuando muestrea el laboratorio';
  end if;

  if p_multi_package_id is not null then
    select * into v_multi from public.multi_packages
    where id = p_multi_package_id and active = true;
    if v_multi.id is null then raise exception 'Multipaquete no válido'; end if;
    if v_multi.sample_count <> jsonb_array_length(p_samples) then
      raise exception 'El multipaquete requiere % muestras', v_multi.sample_count;
    end if;
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_samples) with ordinality a(value, ordinality)
    join jsonb_array_elements(p_samples) with ordinality b(value, ordinality)
      on a.value->>'sample_number' = b.value->>'sample_number'
     and a.ordinality < b.ordinality
  ) then raise exception 'Los números de muestra no pueden repetirse'; end if;

  if exists (
    select 1 from public.samples s
    join jsonb_array_elements(p_samples) x
      on s.sample_code = btrim(x.value->>'sample_number')
  ) then raise exception 'Uno o más números de muestra ya existen'; end if;

  perform pg_advisory_xact_lock(extract(year from p_received_at)::integer);

  select count(*) + 1 into v_sequence from public.analysis_orders
  where op_number ~ ('^2' || to_char(p_received_at, 'YY') || '[0-9]{5}$');
  if v_sequence > 999 then raise exception 'Se agotó el consecutivo anual de OP'; end if;
  v_prefix := '2' || to_char(p_received_at, 'YY') || to_char(p_received_at, 'MM');

  insert into public.analysis_orders (
    op_number, client_id, multi_package_id, sampling_number, sampler_name,
    quotation_number, billing_details, precaptured, received_at, sampled_at,
    due_date, created_by
  ) values (
    v_prefix || lpad(v_sequence::text, 3, '0'), v_client_id, p_multi_package_id,
    v_sampling_number, nullif(btrim(p_sampler_name), ''),
    nullif(btrim(p_quotation_number), ''), nullif(btrim(p_billing_details), ''),
    p_precaptured, p_received_at, p_sampled_at,
    public.calculate_due_date(p_received_at, 8), auth.uid()
  ) returning * into v_order;

  for v_sample, v_position in
    select value, ordinality::integer from jsonb_array_elements(p_samples) with ordinality
  loop
    if nullif(btrim(coalesce(v_sample->>'sample_number', '')), '') is null then
      raise exception 'El número de la muestra % es obligatorio', v_position;
    end if;

    v_package_id := null;
    if p_multi_package_id is null and nullif(v_sample->>'package_id', '') is not null then
      select id, name into v_package_id, v_analysis_label
      from public.analysis_packages
      where id = (v_sample->>'package_id')::uuid and active = true;
      if v_package_id is null then raise exception 'Paquete no válido en la muestra %', v_position; end if;
    elsif p_multi_package_id is not null then
      v_analysis_label := v_multi.name || ' · Muestra ' || v_position;
    else
      v_analysis_label := 'Selección personalizada';
      if jsonb_typeof(v_sample->'parameter_ids') <> 'array'
         or jsonb_array_length(v_sample->'parameter_ids') = 0 then
        raise exception 'Selecciona parámetros para la muestra %', v_position;
      end if;
    end if;

    insert into public.samples (
      order_id, sample_code, package_id, sampling_number, multi_package_id,
      multi_package_sample_position, analysis_label
    ) values (
      v_order.id, btrim(v_sample->>'sample_number'), v_package_id, v_sampling_number,
      p_multi_package_id, case when p_multi_package_id is null then null else v_position end,
      v_analysis_label
    ) returning id into v_sample_id;

    if v_package_id is null then
      insert into public.analysis_worksheets (sample_id, received_at)
      values (v_sample_id, p_received_at) returning id into v_worksheet_id;

      if p_multi_package_id is not null then
        insert into public.analysis_results (worksheet_id, parameter_id, display_order)
        select v_worksheet_id, mpi.parameter_id, mpi.display_order
        from public.multi_package_items mpi
        where mpi.multi_package_id = p_multi_package_id
          and mpi.sample_position = v_position
        order by mpi.display_order;
        if not found then raise exception 'La muestra % del multipaquete no tiene parámetros', v_position; end if;
      else
        v_display_order := 0;
        for v_parameter in select jsonb_array_elements_text(v_sample->'parameter_ids')
        loop
          v_display_order := v_display_order + 1;
          insert into public.analysis_results (worksheet_id, parameter_id, display_order)
          select v_worksheet_id, p.id, v_display_order
          from public.parameters p
          where p.id = v_parameter::uuid and p.active = true;
          if not found then raise exception 'Parámetro inválido en la muestra %', v_position; end if;
        end loop;
      end if;
      update public.samples set analysis_order_created_at = now() where id = v_sample_id;
    end if;
  end loop;

  insert into public.audit_events (actor_id, entity_type, entity_id, action, after_data)
  values (auth.uid(), 'sample_intake', v_order.id, 'created_batch',
          jsonb_build_object('op_number', v_order.op_number,
                             'sample_count', jsonb_array_length(p_samples),
                             'multi_package_id', p_multi_package_id,
                             'lab_sampling', p_lab_sampling,
                             'client_id', v_client_id));
  return v_order;
end;
$$;

revoke execute on function public.create_sample_entry_batch(
  text, jsonb, boolean, text, date, uuid, date, text, text, text, boolean
) from public, anon;
grant execute on function public.create_sample_entry_batch(
  text, jsonb, boolean, text, date, uuid, date, text, text, text, boolean
) to authenticated;

commit;
