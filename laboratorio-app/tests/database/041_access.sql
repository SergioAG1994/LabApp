begin;
insert into auth.users(id) values
 ('41000000-0000-0000-0000-000000000001'),
 ('41000000-0000-0000-0000-000000000002'),
 ('41000000-0000-0000-0000-000000000003'),
 ('41000000-0000-0000-0000-000000000004');
update public.profiles set role = case right(id::text,1) when '1' then 'administrador'::public.app_role when '2' then 'recepcion'::public.app_role when '3' then 'analista'::public.app_role else 'revisor'::public.app_role end where id::text like '41000000%';
select set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000002', true);
insert into public.clients(id,name) values ('41000000-0000-0000-0000-000000000010','Security fixture');
insert into public.parameters(id,name) values ('41000000-0000-0000-0000-000000000011','Security fixture parameter');
insert into public.analysis_packages(id,code,name) values ('41000000-0000-0000-0000-000000000012','SECURITY-FIXTURE','Security fixture');
insert into public.package_parameters(package_id,parameter_id) values ('41000000-0000-0000-0000-000000000012','41000000-0000-0000-0000-000000000011');
insert into public.analysis_orders(id,op_number,client_id,due_date) values
 ('41000000-0000-0000-0000-000000000020','SECURITY-1','41000000-0000-0000-0000-000000000010',current_date),
 ('41000000-0000-0000-0000-000000000021','SECURITY-2','41000000-0000-0000-0000-000000000010',current_date);
insert into public.samples(id,order_id,sample_code,package_id) values
 ('41000000-0000-0000-0000-000000000030','41000000-0000-0000-0000-000000000020','SECURITY-1','41000000-0000-0000-0000-000000000012'),
 ('41000000-0000-0000-0000-000000000031','41000000-0000-0000-0000-000000000021','SECURITY-2','41000000-0000-0000-0000-000000000012');

select pg_temp.assert(not exists (
 select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.prosecdef and has_function_privilege('anon',p.oid,'EXECUTE')
), 'anonymous cannot execute privileged public functions');
set local role anon;
select pg_temp.assert_raises($q$select public.get_client_by_number(1)$q$, 'permission denied');
select pg_temp.assert_raises($q$select public.create_worksheet_for_sample('41000000-0000-0000-0000-000000000030')$q$, 'permission denied');
reset role;

set local role authenticated;
select pg_temp.assert((public.get_client_by_number((select client_number from public.clients where id='41000000-0000-0000-0000-000000000010'))).name='Security fixture','reception client lookup');
select public.create_worksheet_for_sample('41000000-0000-0000-0000-000000000030');
select public.cancel_sample_entry('41000000-0000-0000-0000-000000000021');
select pg_temp.assert_raises($q$select public.issue_report('41000000-0000-0000-0000-000000000021','9998')$q$,'cancelada');
select public.restore_sample_entry('41000000-0000-0000-0000-000000000021');
select pg_temp.assert_raises($q$update public.analysis_orders set status='informe_emitido' where id='41000000-0000-0000-0000-000000000020'$q$, 'Utiliza');
select pg_temp.assert_raises($q$update public.analysis_orders set status='cancelada',status_before_cancel='registrada' where id='41000000-0000-0000-0000-000000000020'$q$, 'Utiliza');
select pg_temp.assert_raises($q$update public.samples set order_id='41000000-0000-0000-0000-000000000021' where id='41000000-0000-0000-0000-000000000030'$q$, 'No se puede cambiar');
select set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000003', true);
select pg_temp.assert(not exists(select 1 from public.analysis_orders),'analyst cannot see order');
select pg_temp.assert_raises($q$select public.get_client_by_number(1)$q$, 'No tienes permiso');
select pg_temp.assert_raises($q$select public.create_worksheet_for_sample('41000000-0000-0000-0000-000000000030')$q$, 'No tienes permiso');
update public.analysis_results set result_value='1.5',uncertainty=0.01,analyst_reference='12345',analyzed_at=current_date,analyst_name='AAA',released_by='BBB'
where worksheet_id in (select id from public.analysis_worksheets where sample_id='41000000-0000-0000-0000-000000000030');
select set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000004', true);
select public.issue_report('41000000-0000-0000-0000-000000000020','9999');
-- Current reissuance remains supported; this PR does not add report versioning.
select public.issue_report('41000000-0000-0000-0000-000000000020','9999');

do $$
declare user_suffix text;
begin
 foreach user_suffix in array array['1','2','3','4'] loop
  perform set_config('request.jwt.claim.sub','41000000-0000-0000-0000-00000000000'||user_suffix,true);
  perform pg_temp.assert_raises($q$update public.analysis_results set result_value='99' where worksheet_id in (select id from public.analysis_worksheets where sample_id='41000000-0000-0000-0000-000000000030')$q$, 'exportada');
  perform pg_temp.assert_raises($q$update public.analysis_results set worksheet_id=(select id from public.analysis_worksheets where sample_id='41000000-0000-0000-0000-000000000031') where worksheet_id in (select id from public.analysis_worksheets where sample_id='41000000-0000-0000-0000-000000000030')$q$, 'No se puede cambiar');
 end loop;
end $$;
select set_config('request.jwt.claim.sub','41000000-0000-0000-0000-000000000002',true);
select pg_temp.assert_raises($q$select public.cancel_sample_entry('41000000-0000-0000-0000-000000000020')$q$, 'informe emitido');
select pg_temp.assert_raises($q$update public.analysis_orders set status='registrada' where id='41000000-0000-0000-0000-000000000020'$q$, 'informe emitido');
select pg_temp.assert_raises($q$delete from public.samples where id='41000000-0000-0000-0000-000000000030'$q$, 'exportada');
select pg_temp.assert_raises($q$update public.samples set sampling_number='changed' where id='41000000-0000-0000-0000-000000000030'$q$, 'exportada');
select public.cancel_sample_entry('41000000-0000-0000-0000-000000000021');
select public.delete_sample_entry_permanently('41000000-0000-0000-0000-000000000021');
select pg_temp.assert(not exists(select 1 from public.analysis_orders where id='41000000-0000-0000-0000-000000000021'),'ordinary permanent deletion works');
reset role;
-- Trigger checks still work even where table policy normally denies the action.
select pg_temp.assert_raises($q$delete from public.analysis_worksheets where sample_id='41000000-0000-0000-0000-000000000030'$q$, 'exportada');
select pg_temp.assert_raises($q$delete from public.analysis_orders where id='41000000-0000-0000-0000-000000000020'$q$, 'informe emitido');
rollback;
