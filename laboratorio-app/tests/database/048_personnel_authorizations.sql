begin;
insert into auth.users(id) values ('48000000-0000-0000-0000-000000000001');
update public.profiles set role='administrador' where id='48000000-0000-0000-0000-000000000001';
select set_config('request.jwt.claim.sub','48000000-0000-0000-0000-000000000001',true);
insert into public.laboratory_staff(id,full_name,initials,position_title,functions)
values ('48000000-0000-0000-0000-000000000002','New personnel','T48','Analyst',array['analista']);
insert into public.parameters(id,name,method_reference)
values ('48000000-0000-0000-0000-000000000003','Personnel test parameter','METHOD-ONE');
set local role authenticated;
select pg_temp.assert((select joined_at is null and education is null from public.laboratory_staff where id='48000000-0000-0000-0000-000000000002'),'no invented personnel dates or degrees');
update public.laboratory_staff set joined_at='2026-10-11',education='Technical degree' where id='48000000-0000-0000-0000-000000000002';
insert into public.staff_parameter_authorizations(id,staff_id,parameter_id,authorization_kind,method_reference,authorized_at)
values ('48000000-0000-0000-0000-000000000004','48000000-0000-0000-0000-000000000002','48000000-0000-0000-0000-000000000003','internal','forged method','2026-10-15');
select pg_temp.assert((select method_reference='METHOD-ONE' from public.staff_parameter_authorizations where id='48000000-0000-0000-0000-000000000004'),'method comes from catalog');
update public.parameters set method_reference='METHOD-TWO' where id='48000000-0000-0000-0000-000000000003';
select pg_temp.assert((select method_reference='METHOD-ONE' from public.staff_parameter_authorizations where id='48000000-0000-0000-0000-000000000004'),'catalog edit preserves historical method');
insert into public.staff_parameter_authorizations(staff_id,parameter_id,authorization_kind,method_reference,authorized_at)
values ('48000000-0000-0000-0000-000000000002','48000000-0000-0000-0000-000000000003','ema','ignored','2026-12-01');
select pg_temp.assert((select count(*)=2 from public.staff_parameter_authorizations where staff_id='48000000-0000-0000-0000-000000000002'),'independent internal and EMA records');
select pg_temp.assert_raises($q$update public.staff_parameter_authorizations set authorized_at='2026-10-01' where id='48000000-0000-0000-0000-000000000004'$q$,'anterior al ingreso');
select pg_temp.assert_raises($q$update public.laboratory_staff set joined_at='2026-11-01' where id='48000000-0000-0000-0000-000000000002'$q$,'posterior a una autorización');
select pg_temp.assert_raises($q$update public.staff_parameter_authorizations set method_reference='other' where id='48000000-0000-0000-0000-000000000004'$q$,'no pueden reemplazarse');
reset role;
update public.profiles set role='recepcion' where id='48000000-0000-0000-0000-000000000001';
set local role authenticated;
select pg_temp.assert((select count(*)=0 from public.staff_parameter_authorizations),'reception cannot read personnel authorizations');
select pg_temp.assert_raises($q$insert into public.staff_parameter_authorizations(staff_id,parameter_id,authorization_kind,method_reference,authorized_at) values('48000000-0000-0000-0000-000000000002','48000000-0000-0000-0000-000000000003','internal','METHOD-TWO','2026-11-01')$q$,'row-level security');
reset role;
set local role anon;
select pg_temp.assert_raises('select * from public.staff_parameter_authorizations','permission denied');
rollback;
