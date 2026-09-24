begin;
insert into auth.users(id) values('42000000-0000-0000-0000-000000000001');
update public.profiles set role='recepcion' where id='42000000-0000-0000-0000-000000000001';
select set_config('request.jwt.claim.sub','42000000-0000-0000-0000-000000000001',true);
insert into public.clients(id,name,branch) values
 ('42000000-0000-0000-0000-000000000002','Same client','North'),
 ('42000000-0000-0000-0000-000000000003','Same client','South'),
 ('42000000-0000-0000-0000-000000000004','Inactive client',null);
update public.clients set active=false where id='42000000-0000-0000-0000-000000000004';
insert into public.parameters(id,name) values('42000000-0000-0000-0000-000000000005','Reference test');
create function pg_temp.make_order(client_id uuid, day date default '2081-01-01') returns public.analysis_orders language sql as $$
 select public.create_sample_entry_batch_auto_for_client(client_id,'[{"parameter_ids":["42000000-0000-0000-0000-000000000005"]}]',false,null,day)
$$;
set local role authenticated;
select pg_temp.assert_raises($q$select public.next_document_number('order',2081)$q$,'permission denied');
select pg_temp.assert_raises($q$select * from public.document_counters$q$,'permission denied');
select pg_temp.assert_raises($q$select pg_temp.make_order('42000000-0000-0000-0000-000000000004')$q$,'cliente activo');
select pg_temp.assert_raises($q$select pg_temp.make_order('42000000-0000-0000-0000-000000000099')$q$,'cliente activo');
select pg_temp.assert_raises($q$select pg_temp.make_order('42000000-0000-0000-0000-000000000002','2100-01-01')$q$,'2000 a 2099');
select pg_temp.assert_raises($q$select public.create_sample_entry_batch_auto_for_client('42000000-0000-0000-0000-000000000002',null,false,null,'2081-01-01')$q$,'entre 1 y 20');
select pg_temp.assert((pg_temp.make_order('42000000-0000-0000-0000-000000000002')).op_number='28101001','first OP');
select pg_temp.assert((pg_temp.make_order('42000000-0000-0000-0000-000000000003','2081-02-02')).op_number='28102002','annual OP counter spans months');
select pg_temp.assert((select client_id='42000000-0000-0000-0000-000000000003' from public.analysis_orders where op_number='28102002'),'same-name branch selected by UUID');
select pg_temp.assert(exists(select 1 from public.samples where sample_code='810202-0002'),'sample counter spans months');
select pg_temp.assert_raises($q$insert into public.report_drafts(order_id,sample_id) select a.id,s.id from public.analysis_orders a,public.samples s where a.op_number='28101001' and s.sample_code='810202-0002'$q$,'report_drafts_sample_order_fk');
insert into public.report_drafts(order_id,sample_id) select order_id,id from public.samples where sample_code='810202-0002';
select public.cancel_sample_entry((select id from public.analysis_orders where op_number='28102002'));
select public.delete_sample_entry_permanently((select id from public.analysis_orders where op_number='28102002'));
select pg_temp.assert(not exists(select 1 from public.report_drafts),'draft cascade');
select pg_temp.assert((pg_temp.make_order('42000000-0000-0000-0000-000000000003')).op_number='28101003','deleted OP not reused');
select pg_temp.assert(exists(select 1 from public.samples where sample_code='810101-0003'),'deleted sample not reused');
select pg_temp.assert((pg_temp.make_order('42000000-0000-0000-0000-000000000002','2082-01-01')).op_number='28201001','year rolls over');
select pg_temp.assert(exists(select 1 from public.samples where sample_code='820101-0001'),'sample year rolls over');
select pg_temp.assert((public.create_sample_entry_batch_auto((select client_number::text from public.clients where id='42000000-0000-0000-0000-000000000003'),'[{"parameter_ids":["42000000-0000-0000-0000-000000000005"]}]',false,null,'2081-01-01')).client_id='42000000-0000-0000-0000-000000000003','old numeric RPC compatibility');
select pg_temp.assert_raises($q$select public.create_sample_entry_batch_auto('Same client','[]',false,null,'2081-01-01')$q$,'nombres ya no');
-- Manual sample imports advance the annual allocator, even across subsequent deletion.
select public.create_sample_entry_batch((select client_number::text from public.clients where id='42000000-0000-0000-0000-000000000002'),'[{"sample_number":"810303-0150","parameter_ids":["42000000-0000-0000-0000-000000000005"]}]',false,null,'2081-03-03');
select public.cancel_sample_entry((select order_id from public.samples where sample_code='810303-0150'));
select public.delete_sample_entry_permanently((select order_id from public.samples where sample_code='810303-0150'));
select pg_temp.make_order('42000000-0000-0000-0000-000000000002');
select pg_temp.assert(exists(select 1 from public.samples where sample_code='810101-0151'),'manual sample high mark retained');
update public.analysis_results set result_value='1',uncertainty=0.1,analyst_reference='12345',analyzed_at=current_date,analyst_name='AAA',released_by='BBB'
where worksheet_id in(select w.id from public.analysis_worksheets w join public.samples s on s.id=w.sample_id where s.sample_code in('810101-0001','810101-0003'));
select public.issue_report((select id from public.analysis_orders where op_number='28101001'),'0450');
-- Reissue still updates version 1 as before, but never lowers the high-water mark.
select public.issue_report((select id from public.analysis_orders where op_number='28101001'),'0440');
select pg_temp.assert((public.issue_report((select id from public.analysis_orders where op_number='28101003'),null)).report_number='0451','manual report advances automatic allocation');
select pg_temp.assert_raises($q$update public.analysis_results set result_value='2' where worksheet_id in(select w.id from public.analysis_worksheets w join public.samples s on s.id=w.sample_id where s.sample_code='810101-0001')$q$,'exportada');
reset role;
select pg_temp.assert(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('create_analysis_order','create_sample_entry') and has_function_privilege('authenticated',p.oid,'EXECUTE')),'old name APIs retired');
-- A privileged import/deletion also cannot make the automatic counter go backwards.
insert into public.reports(order_id,report_number,report_year) select id,'0600',2085 from public.analysis_orders where op_number='28201001';
delete from public.reports where report_year=2085;
select pg_temp.assert(public.next_document_number('report',2085)=601,'deleted report number retained');
select pg_temp.assert(public.next_document_number('report',2086)=1,'report year rollover');
select pg_temp.assert(public.next_document_number('order',2089,999)=1,'OP final capacity');
select pg_temp.assert_raises($q$select public.next_document_number('order',2089)$q$,'agotó');
select pg_temp.assert(public.next_document_number('sample',2089,9999)=1,'sample final capacity');
select pg_temp.assert_raises($q$select public.next_document_number('sample',2089)$q$,'agotó');
select pg_temp.assert(public.next_document_number('report',2089,9999)=1,'report final capacity');
select pg_temp.assert_raises($q$select public.next_document_number('report',2089)$q$,'agotó');
rollback;
