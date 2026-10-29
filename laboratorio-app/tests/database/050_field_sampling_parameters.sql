begin;
insert into auth.users(id) values ('50000000-0000-0000-0000-000000000001');
update public.profiles set role='recepcion' where id='50000000-0000-0000-0000-000000000001';
select set_config('request.jwt.claim.sub','50000000-0000-0000-0000-000000000001',true);

insert into public.clients(id,name) values ('50000000-0000-0000-0000-000000000002','Field Sampling Test');
insert into public.analysis_packages(id,code,name) values
  ('50000000-0000-0000-0000-000000000003','FIELD-TEST','Field sampling test');
insert into public.package_parameters(package_id,parameter_id,display_order)
select '50000000-0000-0000-0000-000000000003',p.id,row_number() over(order by p.name)*10
from public.parameters p where p.name in ('CE','pH','Temperatura','MF');

insert into public.multi_packages(id,name,sample_count) values
  ('50000000-0000-0000-0000-000000000004','Field multipackage test',1);
insert into public.multi_package_items(multi_package_id,sample_position,parameter_id,display_order)
select '50000000-0000-0000-0000-000000000004',1,p.id,row_number() over(order by p.name)
from public.parameters p where p.name in ('CE','pH','Temperatura');

select pg_temp.assert((
  select count(*) = 4 and bool_and(base.par_form is not distinct from field.par_form
      and base.unit is not distinct from field.unit
      and base.method_reference is not distinct from field.method_reference)
  from (values ('CE','CE muestreo'),('pH','pH muestreo'),
               ('Temperatura','Temperatura muestreo'),('MF','MF muestreo')) pairs(base_name,field_name)
  join public.parameters base on base.name = pairs.base_name
  join public.parameters field on field.name = pairs.field_name
),'field variants retain formal names, units, and methods');

select pg_temp.assert(
  private.parameter_authorization_family((select id from public.parameters where name='CE'))
  = private.parameter_authorization_family((select id from public.parameters where name='CE muestreo')),
  'field sampling variant shares the canonical parameter authorization family'
);

create temp table field_sampling_orders(kind text primary key, order_id uuid);
grant select, insert on field_sampling_orders to authenticated;
set local role authenticated;
insert into field_sampling_orders
select 'package',(public.create_sample_entry_batch_auto_for_client(
  '50000000-0000-0000-0000-000000000002',
  jsonb_build_array(jsonb_build_object('package_id','50000000-0000-0000-0000-000000000003')),
  true,'FIELD-001','2089-10-01'
)).id;
insert into field_sampling_orders
select 'custom',(public.create_sample_entry_batch_auto_for_client(
  '50000000-0000-0000-0000-000000000002',
  jsonb_build_array(jsonb_build_object('parameter_ids',(
    select jsonb_agg(id order by name) from public.parameters where name in ('CE','pH','Temperatura','MF')
  ))),
  true,'FIELD-002','2089-10-01'
)).id;
insert into field_sampling_orders
select 'multi',(public.create_sample_entry_batch_auto_for_client(
  '50000000-0000-0000-0000-000000000002','[{}]'::jsonb,
  true,'FIELD-003','2089-10-01','50000000-0000-0000-0000-000000000004'
)).id;
reset role;

select pg_temp.assert((
  select array_agg(p.name order by p.name collate "C") = array['CE muestreo','MF muestreo','Temperatura muestreo','pH muestreo']
    and count(*) = 4
  from public.analysis_results r
  join public.analysis_worksheets w on w.id=r.worksheet_id
  join public.samples s on s.id=w.sample_id
  join public.analysis_orders o on o.id=s.order_id
  join public.parameters p on p.id=r.parameter_id
  join field_sampling_orders x on x.order_id=o.id
  where x.kind='package'
),'field package replaces all four base parameters and contains field floating matter');

select pg_temp.assert((
  select array_agg(p.name order by p.name collate "C") = array['CE muestreo','MF muestreo','Temperatura muestreo','pH muestreo']
    and count(*) = 4
  from public.analysis_results r
  join public.analysis_worksheets w on w.id=r.worksheet_id
  join public.samples s on s.id=w.sample_id
  join public.analysis_orders o on o.id=s.order_id
  join public.parameters p on p.id=r.parameter_id
  join field_sampling_orders x on x.order_id=o.id
  where x.kind='custom'
),'field custom selection maps variants and adds field floating matter');

select pg_temp.assert((
  select array_agg(p.name order by p.name collate "C") = array['CE muestreo','MF muestreo','Temperatura muestreo','pH muestreo']
    and count(*) = 4
  from public.analysis_results r
  join public.analysis_worksheets w on w.id=r.worksheet_id
  join public.samples s on s.id=w.sample_id
  join public.analysis_orders o on o.id=s.order_id
  join public.parameters p on p.id=r.parameter_id
  join field_sampling_orders x on x.order_id=o.id
  where x.kind='multi'
),'field multipackage maps variants and adds field floating matter');

insert into field_sampling_orders
select 'client_sampling',(public.create_sample_entry_batch_auto_for_client(
  '50000000-0000-0000-0000-000000000002',
  jsonb_build_array(jsonb_build_object('package_id','50000000-0000-0000-0000-000000000003')),
  false,null,'2089-10-02'
)).id;

select pg_temp.assert((
  select array_agg(p.name order by p.name collate "C") = array['CE','MF','Temperatura','pH']
    and count(*) = 4
  from public.analysis_results r
  join public.analysis_worksheets w on w.id=r.worksheet_id
  join public.samples s on s.id=w.sample_id
  join public.analysis_orders o on o.id=s.order_id
  join public.parameters p on p.id=r.parameter_id
  join field_sampling_orders x on x.order_id=o.id
  where x.kind='client_sampling'
),'client-sampled package keeps regular parameters');
insert into field_sampling_orders
select 'client_multi',(public.create_sample_entry_batch_auto_for_client(
  '50000000-0000-0000-0000-000000000002','[{}]'::jsonb,
  false,null,'2089-10-02','50000000-0000-0000-0000-000000000004'
)).id;

select pg_temp.assert((
  select array_agg(p.name order by p.name collate "C") = array['CE','Temperatura','pH'] and count(*) = 3
  from public.analysis_results r
  join public.analysis_worksheets w on w.id=r.worksheet_id
  join public.samples s on s.id=w.sample_id
  join public.parameters p on p.id=r.parameter_id
  join field_sampling_orders x on x.order_id=s.order_id
  where x.kind='client_multi'
),'client-sampled multipackage keeps regular parameters and does not add MF');
-- A CE authorization must allow reading AND saving CE muestreo, without
-- exposing or accepting writes to the other field parameters.
insert into auth.users(id) values ('50000000-0000-0000-0000-000000000011');
insert into public.laboratory_staff(id,full_name,initials,position_title,functions)
values ('50000000-0000-0000-0000-000000000012','Field Analyst','FA','Analyst',array['analista']);
update public.profiles set role='analista',laboratory_staff_id='50000000-0000-0000-0000-000000000012'
where id='50000000-0000-0000-0000-000000000011';
insert into public.staff_parameter_authorizations(staff_id,parameter_id,authorization_kind,method_reference,authorized_at)
select '50000000-0000-0000-0000-000000000012',id,'internal','ignored',current_date
from public.parameters where name='CE';
create temp table field_analyst_state as
select s.id as sample_id,r.id as forbidden_result_id
from public.samples s
join field_sampling_orders x on x.order_id=s.order_id and x.kind='package'
join public.analysis_worksheets w on w.sample_id=s.id
join public.analysis_results r on r.worksheet_id=w.id
join public.parameters p on p.id=r.parameter_id and p.name='MF muestreo';
grant select on field_analyst_state to authenticated;
select set_config('request.jwt.claim.sub','50000000-0000-0000-0000-000000000011',true);
set local role authenticated;
select pg_temp.assert((select count(*)=1 and min(label)='CE muestreo'
  from public.load_staff_sample_worksheet((select sample_id from field_analyst_state))),
  'analyst sees only their authorized field variant');
select public.save_analysis_worksheet(
  (select sample_id from field_analyst_state),
  (select max(worksheet_revision) from public.load_staff_sample_worksheet((select sample_id from field_analyst_state))),
  (select jsonb_agg(jsonb_build_object('id',id,'result_value','125.00','uncertainty',0.1))
   from public.load_staff_sample_worksheet((select sample_id from field_analyst_state)))
);
select pg_temp.assert((select count(*)=1 and bool_and(result_value='125.00')
  from public.load_staff_sample_worksheet((select sample_id from field_analyst_state))),
  'analyst can save field results using their base parameter authorization');
select pg_temp.assert_raises($q$
select public.save_analysis_worksheet(
  (select sample_id from field_analyst_state),
  (select max(worksheet_revision) from public.load_staff_sample_worksheet((select sample_id from field_analyst_state))),
  jsonb_build_array(jsonb_build_object('id',(select forbidden_result_id from field_analyst_state),'result_value','1'))
)$q$,'tus parámetros autorizados');
rollback;
