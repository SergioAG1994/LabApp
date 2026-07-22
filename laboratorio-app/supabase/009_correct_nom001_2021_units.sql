-- Corrección de nombres y unidades según el catálogo proporcionado por el laboratorio.
-- Ejecutar después de 008_nom001_2021_24h_template.sql.
-- También actualiza las OA creadas con la primera versión de la plantilla.

update public.analysis_order_rows
set label = case row_key
  when 'ph' then 'pH'
  when 'temperatura' then 'Temperatura'
  when 'materia_flotante' then 'MF'
  when 'solidos_sedimentables' then 'S. Sed'
  when 'cianuros' then 'CN'
  when 'cromo_vi' then 'Cr VI'
  else label
end,
unit = case row_key
  when 'ph' then 'U. de pH'
  when 'conductividad' then 'µS/cm'
  when 'temperatura' then '° C'
  when 'materia_flotante' then 'Sin unidades'
  when 'solidos_sedimentables' then 'ml/L'
  when 'dqo' then 'mgO2/L'
  when 'cianuros' then 'µg/L'
  when 'cromo_vi' then 'mg Cr6/L'
  else unit
end,
updated_at = now()
where row_key in ('ph', 'conductividad', 'temperatura', 'materia_flotante', 'solidos_sedimentables', 'dqo', 'cianuros', 'cromo_vi');
