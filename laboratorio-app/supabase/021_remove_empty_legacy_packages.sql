-- Paquetes heredados sin parámetros ni muestras asociadas.
delete from public.analysis_packages ap
where ap.code in ('NOM-001', 'NOM-002', 'NOM-003')
  and not exists (select 1 from public.package_parameters pp where pp.package_id = ap.id)
  and not exists (select 1 from public.samples s where s.package_id = ap.id);
