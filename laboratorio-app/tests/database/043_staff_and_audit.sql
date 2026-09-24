begin;
insert into auth.users(id) values
 ('43000000-0000-0000-0000-000000000001'),('43000000-0000-0000-0000-000000000002'),('43000000-0000-0000-0000-000000000003');
update public.profiles set role=case right(id::text,1) when '1' then 'recepcion'::public.app_role when '2' then 'analista'::public.app_role else 'revisor'::public.app_role end where id::text like '43000000%';
select set_config('request.jwt.claim.sub','43000000-0000-0000-0000-000000000001',true);
insert into public.laboratory_staff(id,full_name,initials,position_title,functions) values
 ('43000000-0000-0000-0000-000000000010','Analyst One','AO','Analyst',array['analista']),
 ('43000000-0000-0000-0000-000000000011','Reviewer One','RO','Reviewer',array['revisor']),
 ('43000000-0000-0000-0000-000000000012','Sampler One','SO','Sampler',array['muestreador']);
insert into public.clients(id,name) values('43000000-0000-0000-0000-000000000020','Audit client');
insert into public.parameters(id,name) values('43000000-0000-0000-0000-000000000030','Audit parameter 1'),('43000000-0000-0000-0000-000000000031','Audit parameter 2');
set local role authenticated;
select public.create_sample_entry_batch_auto_with_staff('43000000-0000-0000-0000-000000000020','[{"parameter_ids":["43000000-0000-0000-0000-000000000030","43000000-0000-0000-0000-000000000031"]}]',true,'SAMPLE-1','2087-01-01',p_sampler_staff_id=>'43000000-0000-0000-0000-000000000012');
select pg_temp.assert((select sampler_name='Sampler One' and sampler_staff_id='43000000-0000-0000-0000-000000000012' from public.analysis_orders where op_number='28701001'),'sampler canonical name and ID');
select pg_temp.assert_raises($q$select public.create_sample_entry_batch_auto_with_staff('43000000-0000-0000-0000-000000000020','[{"parameter_ids":["43000000-0000-0000-0000-000000000030"]}]',true,'SAMPLE-1','2087-01-01',p_sampler_staff_id=>'43000000-0000-0000-0000-000000000010')$q$,'muestreador activo');
select pg_temp.assert((select count(*)=1 from public.analysis_orders where client_id='43000000-0000-0000-0000-000000000020'),'invalid sampler rolls intake back');
reset role;
create temp table state as select s.id sample_id,w.id worksheet_id,w.revision original_revision from public.samples s join public.analysis_worksheets w on w.sample_id=s.id where s.sample_code='870101-0001';
create temp table payload as select jsonb_agg(jsonb_build_object('id',r.id,'result_value','1.25','uncertainty',0.01,'analyst_reference','12345','analyzed_at',current_date,'analyst_staff_id','43000000-0000-0000-0000-000000000010','released_by_staff_id','43000000-0000-0000-0000-000000000011','analyst_name','ignored','released_by','ignored') order by r.parameter_id) rows from public.analysis_results r join state s on s.worksheet_id=r.worksheet_id;
grant select,update on state,payload to authenticated;
set local role authenticated;
select pg_temp.assert(public.save_analysis_worksheet((select sample_id from state),(select original_revision from state),(select rows from payload),'2087-01-01')>(select original_revision from state),'atomic save advances revision');
select pg_temp.assert((select bool_and(analyst_name='AO' and released_by='RO') from public.analysis_results where worksheet_id=(select worksheet_id from state)),'derive credited initials');
select pg_temp.assert_raises($q$select public.save_analysis_worksheet((select sample_id from state),(select original_revision from state),(select rows from payload))$q$,'Recarga');
do $$
begin
 begin
  perform public.save_analysis_worksheet((select sample_id from state),(select original_revision from state),(select rows from payload));
  raise exception 'Expected stale SQLSTATE';
 exception when serialization_failure then null;
 end;
end $$;
select pg_temp.assert(not exists(select 1 from public.audit_events),'reception cannot read private audit');
select pg_temp.assert_raises($q$insert into public.audit_events(entity_type,action) values('forged','insert')$q$,'permission denied');
select pg_temp.assert_raises($q$delete from public.audit_events$q$,'permission denied');
select pg_temp.assert_raises($q$update public.audit_events set action='forged'$q$,'permission denied');
reset role;
update payload set rows=(select jsonb_agg(to_jsonb(r) order by r.parameter_id) from public.analysis_results r where worksheet_id=(select worksheet_id from state));
update state set original_revision=(select revision from public.analysis_worksheets where id=state.worksheet_id);
create temp table audit_count as select count(*) n from public.audit_events;
set local role authenticated;
-- The first valid row must roll back if a later row fails its numeric constraint.
select pg_temp.assert_raises($q$select public.save_analysis_worksheet((select sample_id from state),(select original_revision from state),(select jsonb_set(jsonb_set(rows,'{0,result_value}','"999"'),'{1,uncertainty}','-1') from payload),'2087-01-02')$q$,'check constraint');
select pg_temp.assert((select bool_and(result_value='1.25') from public.analysis_results where worksheet_id=(select worksheet_id from state)),'partial result changes rolled back');
select pg_temp.assert((select revision=original_revision from public.analysis_worksheets,state where id=worksheet_id),'failed save revision rolled back');
select pg_temp.assert((select sampled_at='2087-01-01' from public.analysis_orders where op_number='28701001'),'failed save date unchanged');
select pg_temp.assert_raises($q$select public.save_analysis_worksheet((select sample_id from state),(select original_revision from state),(select jsonb_set(rows,'{1,id}','"43000000-0000-0000-0000-000000000099"') from payload))$q$,'no pertenece');
select pg_temp.assert_raises($q$select public.save_analysis_worksheet((select sample_id from state),(select original_revision from state),(select jsonb_set(rows,'{1,id}',rows->0->'id') from payload))$q$,'una sola vez');
select pg_temp.assert_raises($q$select public.save_analysis_worksheet((select sample_id from state),(select original_revision from state),(select jsonb_set(jsonb_set(rows,'{0,analyst_staff_id}','null'),'{0,analyst_name}','"Made up"') from payload))$q$,'directorio');
reset role;
select pg_temp.assert((select count(*)=(select n from audit_count) from public.audit_events),'failed saves leave no audit fragments');
update public.laboratory_staff set active=false,full_name='Renamed analyst',initials='NEW' where id='43000000-0000-0000-0000-000000000010';
set local role authenticated;
select set_config('request.jwt.claim.sub','43000000-0000-0000-0000-000000000002',true);
-- Unchanged inactive credited identity stays valid and retains historical spelling.
select public.save_analysis_worksheet((select sample_id from state),(select original_revision from state),(select jsonb_set(rows,'{0,result_value}','"2.25"') from payload));
select pg_temp.assert((select bool_and(analyst_name='AO') from public.analysis_results where worksheet_id=(select worksheet_id from state)),'rename preserves credited text and ID');
select pg_temp.assert((select bool_and(worksheet_sampled_at='2087-01-01') from public.worksheet_results where sample_id=(select sample_id from state)),'analyst omitted sampled date does not clear it');
select pg_temp.assert(not exists(select 1 from public.clients),'analyst cannot see client');
select pg_temp.assert(not exists(select 1 from public.audit_events),'analyst cannot read client-bearing history');
reset role;
-- Stage compatibility: old clients can still write unlinked legacy text; every
-- such edit changes revision and is audited. New RPC preserves it unchanged.
update public.analysis_results set analyst_staff_id=null,analyst_name='Historic unknown' where worksheet_id=(select worksheet_id from state);
update payload set rows=(select jsonb_agg(to_jsonb(r) order by r.parameter_id) from public.analysis_results r where worksheet_id=(select worksheet_id from state));
update state set original_revision=(select revision from public.analysis_worksheets where id=state.worksheet_id);
set local role authenticated;
select public.save_analysis_worksheet((select sample_id from state),(select original_revision from state),(select jsonb_set(rows,'{0,result_value}','"3.25"') from payload));
select pg_temp.assert_raises($q$update public.analysis_results set analyst_staff_id='43000000-0000-0000-0000-000000000010' where worksheet_id=(select worksheet_id from state)$q$,'analista activo');
select pg_temp.assert_raises($q$update public.analysis_results set analyst_staff_id='43000000-0000-0000-0000-000000000012' where worksheet_id=(select worksheet_id from state)$q$,'analista activo');
select set_config('request.jwt.claim.sub','43000000-0000-0000-0000-000000000003',true);
select pg_temp.assert(exists(select 1 from public.audit_events where entity_type='analysis_results' and actor_id='43000000-0000-0000-0000-000000000002' and before_data->>'result_value'='2.25' and after_data->>'result_value'='3.25'),'audit actual actor separate from credited person');
select pg_temp.assert(exists(select 1 from public.audit_events where entity_type='laboratory_staff' and before_data->>'full_name'='Analyst One' and after_data->>'full_name'='Renamed analyst'),'personnel changes audited');
select pg_temp.assert(exists(select 1 from public.audit_events where entity_type='analysis_orders' and action='insert'),'order creation audited');
select public.issue_report((select order_id from public.samples where id=(select sample_id from state)),'0043');
select pg_temp.assert(exists(select 1 from public.audit_events where entity_type='reports' and action='insert' and actor_id='43000000-0000-0000-0000-000000000003'),'issuance audited');
select pg_temp.assert_raises($q$select public.save_analysis_worksheet((select sample_id from state),(select revision from public.analysis_worksheets where id=(select worksheet_id from state)),(select rows from payload))$q$,'exportada');
set local role anon;
select pg_temp.assert_raises($q$select public.save_analysis_worksheet(null,0,'[]')$q$,'permission denied');
select pg_temp.assert_raises($q$select * from public.audit_events$q$,'permission denied');
rollback;
