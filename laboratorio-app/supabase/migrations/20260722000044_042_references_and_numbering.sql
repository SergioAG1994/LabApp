-- Stable client references, consistent drafts, and retained annual number counters.
-- Existing YY-based order/sample formats represent 2000–2099 only.
begin;
set local lock_timeout = '5s';
-- Block concurrent writes while auditing relationships and seeding counters.
lock table public.analysis_orders, public.samples, public.reports, public.report_drafts in share row exclusive mode;
do $$
declare bad_ids text;
begin
 select string_agg(d.id::text, ', ') into bad_ids from public.report_drafts d
 join public.samples s on s.id=d.sample_id where d.order_id<>s.order_id;
 if bad_ids is not null then
   raise exception 'Report drafts reference the wrong order. Reconcile before applying 042. Draft IDs: %', bad_ids;
 end if;
end $$;
alter table public.samples add constraint samples_id_order_unique unique(id, order_id);
alter table public.report_drafts add constraint report_drafts_sample_order_fk
 foreign key(sample_id, order_id) references public.samples(id, order_id) on delete cascade;

create table public.document_counters (
 document_type text not null check(document_type in ('order','sample','report')),
 document_year integer not null,
 last_number integer not null check(last_number between 0 and 9999),
 primary key(document_type, document_year),
 check(document_type <> 'order' or last_number <= 999)
);
alter table public.document_counters enable row level security;
revoke all on public.document_counters from public, anon, authenticated;

-- Retain the high-water mark even when records are subsequently deleted.
insert into public.document_counters
 select 'order', 2000+substring(op_number from 2 for 2)::integer,
 max(right(op_number,3)::integer) from public.analysis_orders
 where op_number ~ '^2[0-9]{7}$' group by 2;
insert into public.document_counters
 select 'sample', 2000+left(sample_code,2)::integer,
 max(right(sample_code,4)::integer) from public.samples
 where sample_code ~ '^[0-9]{6}-[0-9]{4}$' group by 2;
insert into public.document_counters
 select 'report', report_year, max(report_number::integer) from public.reports
 where report_number ~ '^[0-9]{4}$' group by report_year;

create function public.next_document_number(p_type text, p_year integer, p_count integer default 1)
returns integer language plpgsql security definer set search_path=public as $$
declare result integer; capacity integer;
begin
 capacity := case p_type when 'order' then 999 when 'sample' then 9999 when 'report' then 9999 end;
 if capacity is null or p_year is null or p_count is null or p_count<1 or p_count>capacity then
   raise exception 'Invalid document counter request';
 end if;
 insert into public.document_counters values(p_type,p_year,0) on conflict do nothing;
 update public.document_counters set last_number=last_number+p_count
 where document_type=p_type and document_year=p_year and last_number<=capacity-p_count
 returning last_number into result;
 if not found then raise exception 'Se agotó el consecutivo anual de % para % (máximo %)', p_type,p_year,capacity; end if;
 return result-p_count+1;
end $$;

-- Manual/imported identifiers also advance counters; ordinary users cannot reset them.
create function public.track_document_number()
returns trigger language plpgsql security definer set search_path=public as $$
declare kind text; yr integer; num integer;
begin
 if tg_table_name='analysis_orders' then
  if new.op_number ~ '^2[0-9]{7}$' then
   kind:='order'; yr:=2000+substring(new.op_number from 2 for 2)::integer; num:=right(new.op_number,3)::integer;
   end if;
 elsif tg_table_name='samples' then
  if new.sample_code ~ '^[0-9]{6}-[0-9]{4}$' then
   kind:='sample'; yr:=2000+left(new.sample_code,2)::integer; num:=right(new.sample_code,4)::integer;
   end if;
 elsif tg_table_name='reports' then
  if new.report_number ~ '^[0-9]{4}$' then
   kind:='report'; yr:=new.report_year; num:=new.report_number::integer;
  end if;
 end if;
 if kind is not null then
   insert into public.document_counters values(kind,yr,num)
   on conflict(document_type,document_year) do update
   set last_number=greatest(public.document_counters.last_number,excluded.last_number);
 end if;
 return new;
end $$;
create trigger orders_track_number after insert or update of op_number on public.analysis_orders for each row execute function public.track_document_number();
create trigger samples_track_number after insert or update of sample_code on public.samples for each row execute function public.track_document_number();
create trigger reports_track_number after insert or update of report_number,report_year on public.reports for each row execute function public.track_document_number();
revoke all on function public.next_document_number(text,integer,integer), public.track_document_number() from public,anon,authenticated;

create function public.create_sample_entry_batch_for_client(
  p_client_id uuid,
  p_samples jsonb,
  p_lab_sampling boolean,
  p_sampling_number text,
  p_received_at date,
  p_multi_package_id uuid default null,
  p_sampled_at date default null,
  p_sampler_name text default null,
  p_quotation_number text default null,
  p_billing_details text default null,
  p_precaptured boolean default false,
  p_auto_number boolean default false
)
returns public.analysis_orders
language plpgsql security definer set search_path = public as $$
declare
  v_client_id uuid;
  v_sample_sequence integer;
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
  if auth.uid() is null or not coalesce(public.current_role() in ('administrador', 'recepcion'), false) then
    raise exception 'No tienes permiso para crear entradas de muestra';
  end if;
  if p_client_id is null then
    raise exception 'El cliente es obligatorio';
  end if;
  if p_received_at is null then
    raise exception 'La fecha de recepción es obligatoria';
  end if;
  if p_samples is null or jsonb_typeof(p_samples) <> 'array'
     or jsonb_array_length(p_samples) not between 1 and 20 then
    raise exception 'La OP debe contener entre 1 y 20 muestras';
  end if;

  select id into v_client_id from public.clients where id=p_client_id and active;
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

  if p_auto_number then
    select jsonb_agg(value - 'sample_number' order by ordinality) into p_samples
    from jsonb_array_elements(p_samples) with ordinality;
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

  if extract(year from p_received_at) not between 2000 and 2099 then
    raise exception 'La numeración actual admite fechas de 2000 a 2099';
  end if;
  v_sequence := public.next_document_number('order', extract(year from p_received_at)::integer);
  if p_auto_number then
    v_sample_sequence := public.next_document_number('sample', extract(year from p_received_at)::integer, jsonb_array_length(p_samples));
  end if;
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
    if p_auto_number then
      v_sample := v_sample || jsonb_build_object('sample_number', to_char(p_received_at,'YYMMDD') || '-' || lpad((v_sample_sequence+v_position-1)::text,4,'0'));
    end if;
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

revoke all on function public.create_sample_entry_batch_for_client(uuid,jsonb,boolean,text,date,uuid,date,text,text,text,boolean,boolean) from public,anon,authenticated;

create or replace function public.create_sample_entry_batch_auto_for_client(
  p_client_id uuid,
  p_samples jsonb, p_lab_sampling boolean, p_sampling_number text, p_received_at date,
  p_multi_package_id uuid default null, p_sampled_at date default null,
  p_sampler_name text default null, p_quotation_number text default null,
  p_billing_details text default null, p_precaptured boolean default false
) returns public.analysis_orders language plpgsql security definer set search_path=public as $$
declare v_client_id uuid;
begin
  if auth.uid() is null or not coalesce(public.current_role() in ('administrador','recepcion'),false) then raise exception 'No tienes permiso para crear entradas de muestra'; end if;
  v_client_id:=p_client_id;
  return public.create_sample_entry_batch_for_client(v_client_id,p_samples,p_lab_sampling,p_sampling_number,p_received_at,p_multi_package_id,p_sampled_at,p_sampler_name,p_quotation_number,p_billing_details,p_precaptured,true);
end $$;
revoke all on function public.create_sample_entry_batch_auto_for_client(uuid,jsonb,boolean,text,date,uuid,date,text,text,text,boolean) from public,anon;
grant execute on function public.create_sample_entry_batch_auto_for_client(uuid,jsonb,boolean,text,date,uuid,date,text,text,text,boolean) to authenticated;

create or replace function public.create_sample_entry_batch_auto(
  p_client_name text,
  p_samples jsonb, p_lab_sampling boolean, p_sampling_number text, p_received_at date,
  p_multi_package_id uuid default null, p_sampled_at date default null,
  p_sampler_name text default null, p_quotation_number text default null,
  p_billing_details text default null, p_precaptured boolean default false
) returns public.analysis_orders language plpgsql security definer set search_path=public as $$
declare v_client_id uuid;
begin
  if auth.uid() is null or not coalesce(public.current_role() in ('administrador','recepcion'),false) then raise exception 'No tienes permiso para crear entradas de muestra'; end if;
  -- Compatibility for the currently deployed UI: accept only client numbers.
  if p_client_name is null or btrim(p_client_name) !~ '^[0-9]+$' then
    raise exception 'Selecciona el número de cliente y sucursal; los nombres ya no se aceptan';
  end if;
  select id into v_client_id from public.clients where client_number=btrim(p_client_name)::bigint and active;
  return public.create_sample_entry_batch_for_client(v_client_id,p_samples,p_lab_sampling,p_sampling_number,p_received_at,p_multi_package_id,p_sampled_at,p_sampler_name,p_quotation_number,p_billing_details,p_precaptured,true);
end $$;
revoke all on function public.create_sample_entry_batch_auto(text,jsonb,boolean,text,date,uuid,date,text,text,text,boolean) from public,anon;
grant execute on function public.create_sample_entry_batch_auto(text,jsonb,boolean,text,date,uuid,date,text,text,text,boolean) to authenticated;

create or replace function public.create_sample_entry_batch(
  p_client_name text,
  p_samples jsonb, p_lab_sampling boolean, p_sampling_number text, p_received_at date,
  p_multi_package_id uuid default null, p_sampled_at date default null,
  p_sampler_name text default null, p_quotation_number text default null,
  p_billing_details text default null, p_precaptured boolean default false
) returns public.analysis_orders language plpgsql security definer set search_path=public as $$
declare v_client_id uuid;
begin
  if auth.uid() is null or not coalesce(public.current_role() in ('administrador','recepcion'),false) then raise exception 'No tienes permiso para crear entradas de muestra'; end if;
  -- Compatibility for the currently deployed UI: accept only client numbers.
  if p_client_name is null or btrim(p_client_name) !~ '^[0-9]+$' then
    raise exception 'Selecciona el número de cliente y sucursal; los nombres ya no se aceptan';
  end if;
  select id into v_client_id from public.clients where client_number=btrim(p_client_name)::bigint and active;
  return public.create_sample_entry_batch_for_client(v_client_id,p_samples,p_lab_sampling,p_sampling_number,p_received_at,p_multi_package_id,p_sampled_at,p_sampler_name,p_quotation_number,p_billing_details,p_precaptured,false);
end $$;
revoke all on function public.create_sample_entry_batch(text,jsonb,boolean,text,date,uuid,date,text,text,text,boolean) from public,anon;
grant execute on function public.create_sample_entry_batch(text,jsonb,boolean,text,date,uuid,date,text,text,text,boolean) to authenticated;

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
    v_sequence := public.next_document_number('report',v_year);
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

-- Obsolete single-sample/name-based RPCs had already stopped working after
-- branch support removed name uniqueness. Explicitly retire every overload.
do $$
declare f record;
begin
 for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname in ('create_analysis_order','create_sample_entry') loop
   execute format('revoke all on function %s from public,anon,authenticated',f.signature);
 end loop;
end $$;
commit;
