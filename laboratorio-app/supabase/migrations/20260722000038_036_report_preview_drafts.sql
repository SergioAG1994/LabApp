-- Borradores de pre-informe y numeración anual de cuatro dígitos.

create table if not exists public.report_drafts (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.analysis_orders(id) on delete cascade,
  sample_id uuid not null unique references public.samples(id) on delete cascade,
  sample_information text not null default '',
  sampled_at date,
  subsample_count smallint check (subsample_count is null or subsample_count in (4, 6)),
  subsample_results jsonb not null default '{}'::jsonb,
  updated_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists report_drafts_order_id_idx on public.report_drafts(order_id);

alter table public.report_drafts enable row level security;

drop policy if exists "report staff read drafts" on public.report_drafts;
create policy "report staff read drafts" on public.report_drafts
for select to authenticated
using ((select public.current_role()) in ('administrador', 'recepcion', 'revisor'));

drop policy if exists "report staff create drafts" on public.report_drafts;
create policy "report staff create drafts" on public.report_drafts
for insert to authenticated
with check ((select public.current_role()) in ('administrador', 'recepcion', 'revisor'));

drop policy if exists "report staff update drafts" on public.report_drafts;
create policy "report staff update drafts" on public.report_drafts
for update to authenticated
using ((select public.current_role()) in ('administrador', 'recepcion', 'revisor'))
with check ((select public.current_role()) in ('administrador', 'recepcion', 'revisor'));

grant select, insert, update on public.report_drafts to authenticated;

alter table public.reports add column if not exists report_year integer;

update public.reports
set report_year = extract(year from coalesce(issued_at, now()) at time zone 'America/Mexico_City')::integer
where report_year is null;

alter table public.reports
  alter column report_year set default (extract(year from current_date)::integer),
  alter column report_year set not null;

alter table public.reports drop constraint if exists reports_report_number_key;
create unique index if not exists reports_year_number_unique
on public.reports(report_year, report_number);

create or replace function public.issue_report(p_order_id uuid, p_report_number text, p_pdf_path text default null)
returns public.reports language plpgsql security definer set search_path = public as $$
declare
  v_report public.reports;
  v_report_number text;
  v_sequence integer;
  v_year integer := extract(year from current_date)::integer;
begin
  if auth.uid() is null or public.current_role() not in ('administrador', 'recepcion', 'revisor') then
    raise exception 'No tienes permiso para emitir informes';
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
