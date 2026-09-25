begin;
insert into auth.users(id) values('44000000-0000-0000-0000-000000000001');
update public.profiles set role='recepcion' where id='44000000-0000-0000-0000-000000000001';
select set_config('request.jwt.claim.sub','44000000-0000-0000-0000-000000000001',true);
insert into public.clients(id,name) values('44000000-0000-0000-0000-000000000002','Measurement client');
insert into public.parameters(id,name) values('44000000-0000-0000-0000-000000000003','Measurement'),('44000000-0000-0000-0000-000000000004','Qualitative');
select public.create_sample_entry_batch_auto_for_client('44000000-0000-0000-0000-000000000002','[{"parameter_ids":["44000000-0000-0000-0000-000000000003","44000000-0000-0000-0000-000000000004"]}]',false,null,'2089-01-01');
create temp table state as select s.id sample_id,w.id worksheet_id,w.revision original_revision from public.samples s join public.analysis_worksheets w on w.sample_id=s.id where s.sample_code='890101-0001';
create temp table cases(raw text,mode text,kind text,number numeric,qualifier text,description text);
insert into cases values
 ('0','auto','number',0,'eq',null),('-12.30','number','number',-12.30,'eq',null),
 ('<0.05','auto','number',0.05,'lt',null),(' <= +.005 ','number','number',0.005,'lte',null),
 ('>42','auto','number',42,'gt',null),('>=-.5','number','number',-0.5,'gte',null),
 ('≤12','number','number',12,'lte',null),('≥12','number','number',12,'gte',null),
 (E'\t<\n-.00001\r','number','number',-.00001,'lt',null),
 ('9007199254740993.123456789123456789','auto','number',9007199254740993.123456789123456789,'eq',null),
 ('not detected','auto','text',null,null,'not detected'),('42','text','text',null,null,'42'),
 ('  <0.05  ','text','text',null,null,'  <0.05  '),('1,234','auto','text',null,null,'1,234'),
 ('1e3','auto','text',null,null,'1e3'),('NaN','auto','text',null,null,'NaN'),
 ('Infinity','auto','text',null,null,'Infinity'),('1.','auto','text',null,null,'1.'),
 ('', 'number',null,null,null,null),(null,'text',null,null,null,null),
 (E' \t\n\r\f\013','auto',null,null,null,null),
 (repeat('9',100),'number','number',repeat('9',100)::numeric,'eq',null),
 (repeat('0',101),'auto','text',null,null,repeat('0',101)),
 ('<'||repeat(' ',126)||'1','number','number',1,'lt',null),
 ('<'||repeat(' ',127)||'1','auto','text',null,null,'<'||repeat(' ',127)||'1');
grant select on state,cases to authenticated;
set local role authenticated;
do $$ declare c record; actual public.analysis_results; begin
 for c in select * from cases loop
  update public.analysis_results set result_value=c.raw,result_input_kind=c.mode
   where worksheet_id=(select worksheet_id from state) and parameter_id='44000000-0000-0000-0000-000000000003' returning * into actual;
  perform pg_temp.assert(actual.result_value is not distinct from c.raw,'raw retained: '||coalesce(c.raw,'NULL'));
  perform pg_temp.assert(actual.result_type is not distinct from c.kind and actual.result_numeric is not distinct from c.number
   and actual.result_qualifier is not distinct from c.qualifier and actual.result_text is not distinct from c.description,'derived value: '||coalesce(c.raw,'NULL'));
 end loop;
end $$;
-- Invalid explicit numeric input never falls back silently to a descriptive value.
do $$ declare bad text; begin
 foreach bad in array array['1,234','1e3','NaN','Infinity','-Infinity','1.','--1','<','<=','==1','1 2',repeat('1',101),'<'||repeat(' ',127)||'1'] loop
  perform pg_temp.assert_raises(format('update public.analysis_results set result_input_kind=''number'',result_value=%L where worksheet_id=%L',bad,(select worksheet_id from state)),'Resultado numérico inválido');
 end loop;
end $$;
select pg_temp.assert_raises($q$update public.analysis_results set result_input_kind='invalid' where worksheet_id=(select worksheet_id from state)$q$,'Tipo de captura');
select pg_temp.assert_raises($q$update public.analysis_results set result_input_kind=null where worksheet_id=(select worksheet_id from state)$q$,'Tipo de captura');
update public.analysis_results set result_input_kind='auto',result_value='9007199254740993.123456789123456789' where worksheet_id=(select worksheet_id from state);
select pg_temp.assert((select bool_and(result_numeric='9007199254740993.123456789123456789' and pg_typeof(result_numeric)='text'::regtype) from public.worksheet_results where sample_id=(select sample_id from state)),'view returns exact numeric as text');
update public.analysis_results set result_numeric=999,result_qualifier='gt',result_text='forged',result_type='text' where worksheet_id=(select worksheet_id from state);
select pg_temp.assert((select bool_and(result_numeric=9007199254740993.123456789123456789 and result_qualifier='eq' and result_type='number' and result_text is null) from public.analysis_results where worksheet_id=(select worksheet_id from state)),'direct derived edits cannot desynchronize');
update public.analysis_results set result_value=' <0.05 ' where worksheet_id=(select worksheet_id from state);
select pg_temp.assert((select bool_and(result_numeric=.05 and result_qualifier='lt' and result_value=' <0.05 ') from public.analysis_results where worksheet_id=(select worksheet_id from state)),'legacy raw writes synchronized');
update public.analysis_results set result_input_kind='text',result_value='42' where worksheet_id=(select worksheet_id from state);
reset role;
create temp table payload as select jsonb_agg(to_jsonb(r)-'result_input_kind' order by r.parameter_id) rows from public.analysis_results r where worksheet_id=(select worksheet_id from state);
update state set original_revision=(select revision from public.analysis_worksheets where id=state.worksheet_id);
grant select on payload to authenticated;
set local role authenticated;
select public.save_analysis_worksheet((select sample_id from state),(select original_revision from state),(select rows from payload));
select pg_temp.assert((select bool_and(result_input_kind='text' and result_type='text' and result_text='42') from public.analysis_results where worksheet_id=(select worksheet_id from state)),'old RPC omission preserves explicit mode');
reset role;
update state set original_revision=(select revision from public.analysis_worksheets where id=state.worksheet_id);
create temp table before_rows as select to_jsonb(r) data from public.analysis_results r where worksheet_id=(select worksheet_id from state);
create temp table before_audit as select count(*) n from public.audit_events;
set local role authenticated;
select pg_temp.assert_raises($q$select public.save_analysis_worksheet((select sample_id from state),(select original_revision from state),(select jsonb_set(jsonb_set(jsonb_set(rows,'{0,result_value}','"100"'),'{1,result_input_kind}','"number"'),'{1,result_value}','"1,234"') from payload),'2089-02-02')$q$,'Resultado numérico inválido');
select pg_temp.assert((select revision=original_revision from public.analysis_worksheets,state where id=worksheet_id),'invalid later row leaves revision unchanged');
reset role;
select pg_temp.assert(not exists((select to_jsonb(r) from public.analysis_results r where worksheet_id=(select worksheet_id from state)) except (select data from before_rows)),'invalid later row rolls back raw/derived/timestamps');
select pg_temp.assert((select count(*)=(select n from before_audit) from public.audit_events),'invalid later row leaves no audit fragments');
select pg_temp.assert((select sampled_at is null from public.analysis_orders where op_number='28901001'),'invalid save does not write sampling date');
-- Issued-result guards cover added input mode/derivative fields as well.
update public.analysis_results set result_input_kind='number',result_value='1',uncertainty=.1,analyst_reference='12345',analyzed_at=current_date,analyst_name='Legacy analyst',released_by='Legacy reviewer' where worksheet_id=(select worksheet_id from state);
select public.issue_report((select order_id from public.samples where id=(select sample_id from state)),'0044');
set local role authenticated;
select pg_temp.assert_raises($q$update public.analysis_results set result_input_kind='text' where worksheet_id=(select worksheet_id from state)$q$,'exportada');
select pg_temp.assert_raises($q$update public.analysis_results set result_numeric=20 where worksheet_id=(select worksheet_id from state)$q$,'exportada');
rollback;
