begin;
insert into auth.users(id,email) values
 ('49000000-0000-0000-0000-000000000001','admin@test.invalid'),
 ('49000000-0000-0000-0000-000000000002','analyst@test.invalid'),
 ('49000000-0000-0000-0000-000000000003','reception@test.invalid'),
 ('49000000-0000-0000-0000-000000000004','other-admin@test.invalid');
update public.profiles set role='administrador' where id in ('49000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000004');
update public.profiles set role='recepcion',full_name='Natalia' where id='49000000-0000-0000-0000-000000000003';
insert into auth.sessions(id,user_id) values
 ('49000000-0000-0000-0000-000000000011','49000000-0000-0000-0000-000000000001'),
 ('49000000-0000-0000-0000-000000000012','49000000-0000-0000-0000-000000000002'),
 ('49000000-0000-0000-0000-000000000013','49000000-0000-0000-0000-000000000003'),
 ('49000000-0000-0000-0000-000000000014','49000000-0000-0000-0000-000000000001');
insert into public.laboratory_staff(id,full_name,initials,position_title,functions)
 values('49000000-0000-0000-0000-000000000020','Berenice','BER','Analyst',array['analista']);
update public.profiles set role='analista',full_name='Berenice',laboratory_staff_id='49000000-0000-0000-0000-000000000020'
 where id='49000000-0000-0000-0000-000000000002';
insert into public.parameters(id,name,method_reference) values
 ('49000000-0000-0000-0000-000000000030','Preview authorized','PREVIEW-METHOD'),
 ('49000000-0000-0000-0000-000000000031','Preview forbidden','PREVIEW-METHOD');
insert into public.staff_parameter_authorizations(staff_id,parameter_id,authorization_kind,method_reference,authorized_at)
 values('49000000-0000-0000-0000-000000000020','49000000-0000-0000-0000-000000000030','internal','ignored',current_date);
insert into public.clients(id,name) values('49000000-0000-0000-0000-000000000040','Preview client');
insert into public.analysis_orders(id,op_number,client_id,due_date)
 values('49000000-0000-0000-0000-000000000041','PREVIEW-1','49000000-0000-0000-0000-000000000040',current_date);
insert into public.samples(id,order_id,sample_code)
 values('49000000-0000-0000-0000-000000000042','49000000-0000-0000-0000-000000000041','PREVIEW-1');
insert into public.analysis_worksheets(id,sample_id)
 values('49000000-0000-0000-0000-000000000043','49000000-0000-0000-0000-000000000042');
insert into public.analysis_results(worksheet_id,parameter_id) values
 ('49000000-0000-0000-0000-000000000043','49000000-0000-0000-0000-000000000030'),
 ('49000000-0000-0000-0000-000000000043','49000000-0000-0000-0000-000000000031');

-- Emulates PostgREST's trusted, transaction-local request setup. Deliberately
-- restores the ACTOR before each request, just as JWT verification does.
create function pg_temp.preview_request(actor_suffix text, session_suffix text, path text, method text default 'POST', headers jsonb default '{}')
returns void language plpgsql as $$
begin
 perform set_config('request.jwt.claim.sub','49000000-0000-0000-0000-00000000000'||actor_suffix,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub','49000000-0000-0000-0000-00000000000'||actor_suffix,
   'role','authenticated','session_id','49000000-0000-0000-0000-00000000001'||session_suffix)::text,true);
 perform set_config('request.path',path,true);
 perform set_config('request.method',method,true);
 perform set_config('request.headers',headers::text,true);
 perform private.apply_user_preview();
end $$;

set local role anon;
select pg_temp.assert_raises($q$select public.start_user_preview('49000000-0000-0000-0000-000000000002')$q$,'permission denied');
reset role;
set local role authenticated;
select pg_temp.preview_request('3','3','/rpc/start_user_preview');
select pg_temp.assert_raises($q$select public.start_user_preview('49000000-0000-0000-0000-000000000002')$q$,'Sólo un administrador');
select pg_temp.preview_request('1','2','/rpc/start_user_preview');
select pg_temp.assert_raises($q$select public.start_user_preview('49000000-0000-0000-0000-000000000002')$q$,'sesión no es válida');
select pg_temp.preview_request('1','1','/rpc/start_user_preview');
select pg_temp.assert_raises($q$select public.start_user_preview('49000000-0000-0000-0000-000000000001')$q$,'otra cuenta válida');
select pg_temp.assert_raises($q$select public.start_user_preview('49000000-0000-0000-0000-000000000099')$q$,'otra cuenta válida');
select pg_temp.assert((public.start_user_preview('49000000-0000-0000-0000-000000000002')->>'fullName')='Berenice','preview returns observed account');
select pg_temp.assert(auth.uid()='49000000-0000-0000-0000-000000000001','starting preview keeps actor identity');

select pg_temp.preview_request('1','1','/parameters','GET');
select pg_temp.assert(auth.uid()='49000000-0000-0000-0000-000000000002','read applies observed identity without a user token');
select pg_temp.assert((select count(*)=1 from public.parameters),'analyst sees only authorized parameter through RLS');
select pg_temp.assert((select count(*)=0 from public.clients),'analyst cannot see client data');
select pg_temp.assert((select count(*)=1 from public.profiles),'analyst can read only own profile');
select pg_temp.assert_raises($q$select * from private.user_preview_sessions$q$,'permission denied');
-- Even if an entry point skips the pre-request hook, table triggers deny writes.
select pg_temp.preview_request('1','1','/rpc/get_user_preview');
select pg_temp.assert_raises($q$update public.parameters set name='changed' where id='49000000-0000-0000-0000-000000000030'$q$,'solo lectura');

select pg_temp.assert_raises($q$select pg_temp.preview_request('1','1','/rpc/save_analysis_worksheet','GET')$q$,'solo lectura');
select pg_temp.assert_raises($q$select pg_temp.preview_request('1','1','/rpc/issue_report','POST')$q$,'solo lectura');
select pg_temp.assert_raises($q$select pg_temp.preview_request('1','1','/parameters','PATCH')$q$,'solo lectura');
select pg_temp.assert_raises($q$select pg_temp.preview_request('1','1','/parameters','GET','{"x-user-preview":"wrong-id"}')$q$,'caducó o fue revocada');
select pg_temp.preview_request('1','1','/rpc/list_staff_samples');
select pg_temp.assert((select total_results=1 from public.list_staff_samples() where sample_code='PREVIEW-1'),'sample counts honor observed parameter authorizations');
select pg_temp.preview_request('1','1','/rpc/load_staff_sample_worksheet');
select pg_temp.assert((select count(*)=1 from public.load_staff_sample_worksheet('49000000-0000-0000-0000-000000000042')),'worksheet is filtered by observed analyst');
select pg_temp.preview_request('1','1','/rpc/get_user_preview');
select pg_temp.assert((public.get_user_preview()->>'role')='analista','control call still authenticates real administrator');
select pg_temp.preview_request('1','4','/parameters','GET');
select pg_temp.assert(auth.uid()='49000000-0000-0000-0000-000000000001','a new Auth session does not inherit preview');
select pg_temp.preview_request('1','1','/rpc/end_user_preview');
select public.end_user_preview();
select pg_temp.preview_request('1','1','/parameters','GET');
select pg_temp.assert(auth.uid()='49000000-0000-0000-0000-000000000001','exit restores administrator reads');
select pg_temp.assert((select count(*)>=2 from public.parameters),'administrator catalog restored');
select pg_temp.assert_raises($q$select pg_temp.preview_request('1','1','/parameters','GET','{"x-user-preview":"ended-id"}')$q$,'vista simulada terminó');

select pg_temp.preview_request('1','1','/rpc/start_user_preview');
select public.start_user_preview('49000000-0000-0000-0000-000000000003');
select pg_temp.preview_request('1','1','/clients','GET');
select pg_temp.assert(public.current_role()='recepcion','reception role is effective');
select pg_temp.assert((select count(*)>=1 from public.clients),'reception sees clients');
select pg_temp.assert((select count(*)=0 from public.laboratory_staff),'reception cannot read personnel');
select pg_temp.preview_request('1','1','/rpc/start_user_preview');
select public.start_user_preview('49000000-0000-0000-0000-000000000004');
select pg_temp.preview_request('1','1','/parameters','GET');
select pg_temp.assert(public.current_role()='administrador','another administrator can be observed');
select pg_temp.assert_raises($q$update public.parameters set name='changed' where id='49000000-0000-0000-0000-000000000030'$q$,'solo lectura');

-- Simulate a privileged revocation in a separate request without actor claims.
reset role;
select set_config('request.jwt.claims','{}',true);
select set_config('request.jwt.claim.sub','',true);
update public.profiles set role='recepcion' where id='49000000-0000-0000-0000-000000000001';
set local role authenticated;
select pg_temp.assert_raises($q$select pg_temp.preview_request('1','1','/parameters','GET')$q$,'caducó o fue revocada');
select pg_temp.preview_request('1','1','/rpc/end_user_preview');
select public.end_user_preview();
reset role;
select set_config('request.jwt.claims','{}',true);
select set_config('request.jwt.claim.sub','',true);
update public.profiles set role='administrador' where id='49000000-0000-0000-0000-000000000001';
set local role authenticated;
select pg_temp.preview_request('1','1','/rpc/start_user_preview');
select public.start_user_preview('49000000-0000-0000-0000-000000000002');
reset role;
select set_config('request.jwt.claims','{}',true);
update private.user_preview_sessions set expires_at=now()-interval '1 minute' where ended_at is null;
set local role authenticated;
select pg_temp.assert_raises($q$select pg_temp.preview_request('1','1','/parameters','GET')$q$,'caducó o fue revocada');
select pg_temp.preview_request('1','1','/rpc/get_user_preview');
select pg_temp.assert(public.get_user_preview() is null,'expired preview closes through status call');
reset role;
select pg_temp.assert((select count(*)=4 from public.audit_events where action='start_user_preview' and actor_id='49000000-0000-0000-0000-000000000001'),'every start is audited with real actor');
select pg_temp.assert((select count(*)=4 from public.audit_events where action='end_user_preview' and actor_id='49000000-0000-0000-0000-000000000001'),'every exit/replacement/expiry is audited');
rollback;
