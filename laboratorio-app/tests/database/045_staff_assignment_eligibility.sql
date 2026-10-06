begin;
insert into auth.users(id) values ('45000000-0000-0000-0000-000000000001');
update public.profiles set role='analista' where id='45000000-0000-0000-0000-000000000001';
select set_config('request.jwt.claim.sub','45000000-0000-0000-0000-000000000001',true);
insert into public.laboratory_staff(id,full_name,initials,position_title,functions) values
 ('45000000-0000-0000-0000-000000000010','Analyst','AN','Analyst',array['analista']),
 ('45000000-0000-0000-0000-000000000011','Sampler','SA','Sampler',array['muestreador']),
 ('45000000-0000-0000-0000-000000000012','Reviewer','RE','Reviewer',array['revisor']),
 ('45000000-0000-0000-0000-000000000013','Authorizer','AU','Authorizer',array['responsable_autorizacion']);
-- Exercise the production trigger with synthetic rows; no lab orders are needed.
create temp table staff_credit_probe (
 analyst_staff_id uuid, analyst_name text,
 released_by_staff_id uuid, released_by text, updated_at timestamptz
);
create trigger credit_probe before insert or update on staff_credit_probe
 for each row execute function public.validate_credited_staff();
grant select,insert,update,delete on staff_credit_probe to authenticated;
set local role authenticated;
select pg_temp.assert(exists(select 1 from public.list_assignable_staff(array['analista','muestreador','revisor','responsable_autorizacion']) where id='45000000-0000-0000-0000-000000000011'),'analyst account can load samplers');
insert into staff_credit_probe(analyst_staff_id,released_by_staff_id)
 select '45000000-0000-0000-0000-000000000011', id
 from public.list_assignable_staff(array['analista','muestreador','revisor','responsable_autorizacion'])
 where id::text like '45000000%';
select pg_temp.assert((select count(*)=4 and bool_and(analyst_name='SA') and count(distinct released_by)=4 from staff_credit_probe),'sampler accepted as analyst and all four functions accepted in Libera');
select pg_temp.assert_raises($q$insert into staff_credit_probe(analyst_staff_id) values('45000000-0000-0000-0000-000000000012')$q$,'analista activo');
select pg_temp.assert_raises($q$insert into staff_credit_probe(released_by_staff_id) values('45000000-0000-0000-0000-000000000099')$q$,'personal activo para Libera');
reset role;
update public.laboratory_staff set active=false where id='45000000-0000-0000-0000-000000000011';
set local role authenticated;
select pg_temp.assert(not exists(select 1 from public.list_assignable_staff(array['muestreador']) where id='45000000-0000-0000-0000-000000000011'),'inactive sampler excluded from selector');
select pg_temp.assert_raises($q$insert into staff_credit_probe(analyst_staff_id) values('45000000-0000-0000-0000-000000000011')$q$,'analista activo');
select pg_temp.assert_raises($q$insert into staff_credit_probe(released_by_staff_id) values('45000000-0000-0000-0000-000000000011')$q$,'personal activo para Libera');
-- Existing attribution remains usable after a personnel deactivation.
update staff_credit_probe set updated_at=clock_timestamp();
select pg_temp.assert((select bool_and(analyst_name='SA') from staff_credit_probe),'historical attribution preserved');
set local role anon;
select pg_temp.assert_raises($q$select * from public.list_assignable_staff(array['muestreador'])$q$,'permission denied');
rollback;
