begin;
insert into auth.users(id) values
  ('51000000-0000-0000-0000-000000000001'),
  ('51000000-0000-0000-0000-000000000002'),
  ('51000000-0000-0000-0000-000000000003');
update public.profiles set role='recepcion' where id='51000000-0000-0000-0000-000000000001';
update public.profiles set role='administrador' where id='51000000-0000-0000-0000-000000000002';
insert into public.laboratory_staff(id,full_name,initials,position_title,functions)
values ('51000000-0000-0000-0000-000000000009','Template Analyst','TA','Analyst',array['analista']);
update public.profiles set role='analista', laboratory_staff_id='51000000-0000-0000-0000-000000000009'
where id='51000000-0000-0000-0000-000000000003';
insert into public.clients(id,name) values ('51000000-0000-0000-0000-000000000004','Template test client');
insert into public.analysis_packages(id,code,name,package_type) values
 ('51000000-0000-0000-0000-000000000005','PERSONALIZADO-TEST-51','Custom test template','cliente'),
 ('51000000-0000-0000-0000-000000000006','STANDARD-TEST-51','Standard test package','cliente');
insert into public.package_parameters(package_id,parameter_id,display_order)
select '51000000-0000-0000-0000-000000000005',id,1 from public.parameters where name='pH';
insert into public.multi_packages(id,name,sample_count)
values ('51000000-0000-0000-0000-000000000007','Multi test template',1);
insert into public.multi_package_items(multi_package_id,sample_position,parameter_id,display_order)
select '51000000-0000-0000-0000-000000000007',1,id,1 from public.parameters where name='pH';

select pg_temp.assert(not has_function_privilege('anon','public.set_analysis_template_active(text,uuid,boolean)','EXECUTE'),
  'anonymous callers cannot run the template status RPC');
select set_config('request.jwt.claim.sub','51000000-0000-0000-0000-000000000003',true);
set local role authenticated;
select pg_temp.assert_raises($q$select public.set_analysis_template_active('custom','51000000-0000-0000-0000-000000000005',false)$q$,'No tienes permiso');
select pg_temp.assert_raises($q$select public.set_analysis_template_active('multi','51000000-0000-0000-0000-000000000007',false)$q$,'No tienes permiso');
select set_config('request.jwt.claim.sub','51000000-0000-0000-0000-000000000001',true);
select public.create_sample_entry_batch_auto_for_client('51000000-0000-0000-0000-000000000004',
  '[{"package_id":"51000000-0000-0000-0000-000000000005"}]',false,null,'2085-11-01');
select public.create_sample_entry_batch_auto_for_client('51000000-0000-0000-0000-000000000004',
  '[{}]',false,null,'2085-11-01','51000000-0000-0000-0000-000000000007');
select pg_temp.assert_raises($q$select public.set_analysis_template_active('custom','51000000-0000-0000-0000-000000000006',false)$q$,'No se encontró el análisis personalizado');
select pg_temp.assert(not public.set_analysis_template_active('custom','51000000-0000-0000-0000-000000000005',false),'reception deactivates a custom template');
select pg_temp.assert(not public.set_analysis_template_active('multi','51000000-0000-0000-0000-000000000007',false),'reception deactivates a multipackage');
select pg_temp.assert_raises($q$select public.create_sample_entry_batch_auto_for_client(
  '51000000-0000-0000-0000-000000000004','[{"package_id":"51000000-0000-0000-0000-000000000005"}]',false,null,'2085-11-01')$q$,'Paquete no válido');
select pg_temp.assert_raises($q$select public.create_sample_entry_batch_auto_for_client(
  '51000000-0000-0000-0000-000000000004','[{}]',false,null,'2085-11-01','51000000-0000-0000-0000-000000000007')$q$,'Multipaquete no válido');
select pg_temp.assert((select count(*)=2 from public.worksheet_results w join public.samples s on s.id=w.sample_id
  join public.analysis_orders o on o.id=s.order_id where o.client_id='51000000-0000-0000-0000-000000000004' and w.label='pH'),
  'previous worksheets retain their parameters after deactivation');
select pg_temp.assert(public.set_analysis_template_active('custom','51000000-0000-0000-0000-000000000005',true),'reception reactivates custom template');
select set_config('request.jwt.claim.sub','51000000-0000-0000-0000-000000000002',true);
select pg_temp.assert(public.set_analysis_template_active('multi','51000000-0000-0000-0000-000000000007',true),'administrator reactivates multipackage');
reset role;
select pg_temp.assert((select count(*)=4 from public.audit_events
  where entity_id in ('51000000-0000-0000-0000-000000000005','51000000-0000-0000-0000-000000000007')
  and action in ('deactivated','reactivated')), 'each status change is audited');

insert into public.analysis_packages(id,code,name,package_type,active) values
 ('51000000-0000-0000-0000-000000000015','PERSONALIZADO-UNUSED-51','Unused custom template','cliente',false);
insert into public.package_parameters(package_id,parameter_id,display_order)
select '51000000-0000-0000-0000-000000000015',id,1 from public.parameters where name='pH';
insert into public.multi_packages(id,name,sample_count)
values ('51000000-0000-0000-0000-000000000017','Unused multi template',1);
insert into public.multi_package_items(multi_package_id,sample_position,parameter_id,display_order)
select '51000000-0000-0000-0000-000000000017',1,id,1 from public.parameters where name='pH';

select pg_temp.assert(not has_function_privilege('anon','public.delete_analysis_template(text,uuid)','EXECUTE'),
  'anonymous callers cannot delete templates');
select set_config('request.jwt.claim.sub','51000000-0000-0000-0000-000000000003',true);
set local role authenticated;
select pg_temp.assert_raises($q$select public.delete_analysis_template('custom','51000000-0000-0000-0000-000000000015')$q$,'No tienes permiso');
select set_config('request.jwt.claim.sub','51000000-0000-0000-0000-000000000001',true);
select pg_temp.assert_raises($q$select public.delete_analysis_template('custom','51000000-0000-0000-0000-000000000006')$q$,'No se encontró una plantilla eliminable');
select pg_temp.assert_raises($q$select public.delete_analysis_template('custom','51000000-0000-0000-0000-000000000005')$q$,'vinculada a órdenes o muestras existentes');
select pg_temp.assert_raises($q$select public.delete_analysis_template('multi','51000000-0000-0000-0000-000000000007')$q$,'vinculada a órdenes o muestras existentes');
select public.delete_analysis_template('custom','51000000-0000-0000-0000-000000000015');
select set_config('request.jwt.claim.sub','51000000-0000-0000-0000-000000000002',true);
select public.delete_analysis_template('multi','51000000-0000-0000-0000-000000000017');
reset role;
select pg_temp.assert(not exists(select 1 from public.analysis_packages where id='51000000-0000-0000-0000-000000000015')
  and not exists(select 1 from public.package_parameters where package_id='51000000-0000-0000-0000-000000000015')
  and not exists(select 1 from public.multi_packages where id='51000000-0000-0000-0000-000000000017')
  and not exists(select 1 from public.multi_package_items where multi_package_id='51000000-0000-0000-0000-000000000017'),
  'unused templates and their own links are permanently removed');
select pg_temp.assert((select count(*)=2 from public.worksheet_results w join public.samples s on s.id=w.sample_id
  join public.analysis_orders o on o.id=s.order_id where o.client_id='51000000-0000-0000-0000-000000000004' and w.label='pH'),
  'attempted deletions preserve historical worksheets');
select pg_temp.assert((select count(*)=2 from public.audit_events where action='deleted'
  and (entity_id,actor_id) in (
    ('51000000-0000-0000-0000-000000000015','51000000-0000-0000-0000-000000000001'),
    ('51000000-0000-0000-0000-000000000017','51000000-0000-0000-0000-000000000002'))),
  'successful deletions retain audit evidence and the actual actors');
rollback;
