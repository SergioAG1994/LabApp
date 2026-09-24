-- Preserve the reported spelling while deriving exact, queryable measurements.
-- No report snapshots/versions are introduced. Catalog result_kind is a legacy
-- default, not an enforced restriction: qualitative tests also use 'number'.
begin;
set local lock_timeout = '5s';
alter table public.analysis_results
 add column result_input_kind text not null default 'auto' check(result_input_kind in ('auto','number','text')),
 add column result_type text check(result_type in ('number','text')),
 add column result_numeric numeric,
 add column result_qualifier text check(result_qualifier in ('eq','lt','lte','gt','gte')),
 add column result_text text;

-- Numeric grammar intentionally excludes commas, exponent notation, trailing
-- decimal points, infinities and NaN. Whitespace is ASCII space/tab/LF/CR/FF/VT.
-- Limit to 100 total digits (leading zeros included) and 128 trimmed characters;
-- PostgreSQL numeric keeps all accepted decimal places without floating rounding.
-- Auto mode preserves anything outside these limits as text; explicit number
-- rejects it. Raw result_value is never rewritten, including whitespace.
create function public.parse_analysis_result(raw_value text,input_kind text)
returns table(result_type text,result_numeric numeric,result_qualifier text,result_text text)
language plpgsql immutable set search_path=public as $$
declare cleaned text; parts text[]; digit_count integer;
begin
 if input_kind is null or input_kind not in ('auto','number','text') then
  raise exception 'Tipo de captura de resultado inválido';
 end if;
 cleaned:=btrim(raw_value,E' \t\n\r\f\013');
 if cleaned is null or cleaned='' then return next; return; end if;
 if input_kind<>'text' and length(cleaned)<=128 then
  parts:=regexp_match(cleaned,E'^(<=|>=|<|>|≤|≥)?[ \t\n\r\f\013]*([+-]?(?:[0-9]+(?:[.][0-9]+)?|[.][0-9]+))$');
  if parts is not null then
   digit_count:=length(regexp_replace(parts[2],'[^0-9]','','g'));
   if digit_count<=100 then
    result_type:='number'; result_numeric:=parts[2]::numeric;
    result_qualifier:=case parts[1] when '<' then 'lt' when '<=' then 'lte' when '≤' then 'lte'
     when '>' then 'gt' when '>=' then 'gte' when '≥' then 'gte' else 'eq' end;
    return next; return;
   end if;
  end if;
 end if;
 if input_kind='number' then
  raise exception 'Resultado numérico inválido: usa un decimal con punto, opcionalmente <, <=, >, >=, ≤ o ≥; máximo 100 dígitos y 128 caracteres';
 end if;
 result_type:='text'; result_text:=raw_value;
 return next;
end $$;
create function public.derive_analysis_result()
returns trigger language plpgsql security definer set search_path=public as $$
declare parsed record;
begin
 select * into parsed from public.parse_analysis_result(new.result_value,new.result_input_kind);
 new.result_type:=parsed.result_type;
 new.result_numeric:=parsed.result_numeric;
 new.result_qualifier:=parsed.result_qualifier;
 new.result_text:=parsed.result_text;
 return new;
end $$;
-- Run on every write, including attempts to forge just the derived fields.
create trigger results_derive_value before insert or update on public.analysis_results
 for each row execute function public.derive_analysis_result();

-- ALTER holds an exclusive table lock through this transaction. Suspend only
-- the four result triggers that would reject issued rows or add historical noise.
-- Derivation remains enabled. Failures roll back data and trigger state together.
alter table public.analysis_results disable trigger analysis_results_lock_exported_worksheet;
alter table public.analysis_results disable trigger results_credited_staff;
alter table public.analysis_results disable trigger results_advance_revision;
alter table public.analysis_results disable trigger record_change;
update public.analysis_results set result_input_kind='auto';
alter table public.analysis_results enable trigger analysis_results_lock_exported_worksheet;
alter table public.analysis_results enable trigger results_credited_staff;
alter table public.analysis_results enable trigger results_advance_revision;
alter table public.analysis_results enable trigger record_change;

alter table public.analysis_results add constraint analysis_results_value_shape check (
 case result_type
  when 'number' then result_numeric is not null and result_qualifier is not null and result_text is null
  when 'text' then result_numeric is null and result_qualifier is null and result_text is not null
  else result_type is null and result_numeric is null and result_qualifier is null and result_text is null
 end
);

create or replace view public.worksheet_results with (security_invoker=true) as
select w.id as worksheet_id,w.sample_id,w.status,
 r.id as id,coalesce(r.display_order,pp.display_order) as display_order,
 coalesce(pp.row_type,'result') as row_type,
 p.id as parameter_id,p.name as label,p.unit,p.method_reference,
 r.result_value,r.uncertainty,r.analyst_reference,r.analyst_id,r.released_by_id,r.analyst_name,r.released_by,
 r.analyzed_at,p.par_form,r.analyst_staff_id,r.released_by_staff_id,w.revision as worksheet_revision,
 public.worksheet_sampled_at(w.sample_id) as worksheet_sampled_at,
 r.result_input_kind,r.result_type,r.result_numeric::text as result_numeric,r.result_qualifier,r.result_text
from public.analysis_worksheets w
join public.analysis_results r on r.worksheet_id=w.id
join public.samples s on s.id=w.sample_id
join public.parameters p on p.id=r.parameter_id
left join public.package_parameters pp on pp.package_id=s.package_id and pp.parameter_id=r.parameter_id;

create or replace function public.save_analysis_worksheet(p_sample_id uuid,p_expected_revision bigint,p_rows jsonb,p_sampled_at date default null)
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
   result_value=entry->>'result_value',
   -- Old clients omit the mode. Preserve an explicit choice already on file.
   result_input_kind=case when entry ? 'result_input_kind' then entry->>'result_input_kind' else previous.result_input_kind end,
   analyst_reference=entry->>'analyst_reference',
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

-- The parser is data-independent; callers use only the existing save RPC/view.
revoke all on function public.parse_analysis_result(text,text),public.derive_analysis_result() from public,anon,authenticated;
commit;
