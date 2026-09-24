-- Plantilla exacta de las capturas de la hoja "NOM 001 2021".
-- Ejecutar después de 010_analysis_order_row_details.sql.

create or replace function public.ensure_nom001_2021_24h_exact_template(p_sample_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  -- No forman parte de la hoja visible de NOM 001 2021.
  delete from public.analysis_order_rows
  where sample_id = p_sample_id and row_key in ('ph', 'cromo_vi');

  insert into public.analysis_order_rows (sample_id, row_key, label, unit, row_type, aggregation, display_order)
  with catalog(row_key, label, unit, row_type, aggregation, display_order) as (values
    ('cobre', 'Cu', 'mg/L', 'result', null, 10),
    ('arsenico', 'As', 'mg/L', 'result', null, 20),
    ('cadmio', 'Cd', 'mg/L', 'result', null, 30),
    ('conductividad', 'CE', 'µS/cm', 'result', null, 40),
    ('cianuros', 'CN', 'µg/L', 'result', null, 50),
    ('cloruros', 'Cloruros', 'mg/L', 'result', null, 60),
    ('col_fec_mg', 'Col fec MG', 'NMP/100mL', 'aggregate', 'media geométrica', 70),
    ('col_fec_1', 'Col fec (1)', 'NMP/100mL', 'result', 'submuestra 1', 80),
    ('col_fec_2', 'Col fec (2)', 'NMP/100mL', 'result', 'submuestra 2', 90),
    ('col_fec_3', 'Col fec (3)', 'NMP/100mL', 'result', 'submuestra 3', 100),
    ('col_fec_4', 'Col fec (4)', 'NMP/100mL', 'result', 'submuestra 4', 110),
    ('col_fec_5', 'Col fec (5)', 'NMP/100mL', 'result', 'submuestra 5', 120),
    ('col_fec_6', 'Col fec (6)', 'NMP/100mL', 'result', 'submuestra 6', 130),
    ('cr', 'Cr', 'mg/L', 'result', null, 140),
    ('dbo5', 'DBO5', 'mg/L', 'result', null, 150),
    ('dqo', 'DQO', 'mgO2/L', 'result', null, 160),
    ('ecoli_mg', 'E. coli MG', 'NMP/100mL', 'aggregate', 'media geométrica', 170),
    ('ecoli_1', 'E. coli (1)', 'NMP/100mL', 'result', 'submuestra 1', 180),
    ('ecoli_2', 'E. coli (2)', 'NMP/100mL', 'result', 'submuestra 2', 190),
    ('ecoli_3', 'E. coli (3)', 'NMP/100mL', 'result', 'submuestra 3', 200),
    ('ecoli_4', 'E. coli (4)', 'NMP/100mL', 'result', 'submuestra 4', 210),
    ('ecoli_5', 'E. coli (5)', 'NMP/100mL', 'result', 'submuestra 5', 220),
    ('ecoli_6', 'E. coli (6)', 'NMP/100mL', 'result', 'submuestra 6', 230),
    ('gya_ponderado', 'GyA ponderado', 'mg/L', 'aggregate', 'ponderado', 240),
    ('gya_1', 'GyA (1)', 'mg/L', 'result', 'submuestra 1', 250),
    ('gya_2', 'GyA (2)', 'mg/L', 'result', 'submuestra 2', 260),
    ('gya_3', 'GyA (3)', 'mg/L', 'result', 'submuestra 3', 270),
    ('gya_4', 'GyA (4)', 'mg/L', 'result', 'submuestra 4', 280),
    ('gya_5', 'GyA (5)', 'mg/L', 'result', 'submuestra 5', 290),
    ('gya_6', 'GyA (6)', 'mg/L', 'result', 'submuestra 6', 300),
    ('hh', 'HH', 'H/L', 'result', null, 310),
    ('materia_flotante', 'MF', 'Sin unidades', 'result', null, 320),
    ('mercurio', 'Hg', 'mg/L', 'result', null, 330),
    ('niquel', 'Ni', 'mg/L', 'result', null, 340),
    ('no3', 'NO3', 'mg N-NO3/L', 'result', null, 350),
    ('no2', 'NO2', 'mg/L de N-O2', 'result', null, 360),
    ('n_tkn', 'N-TKN', 'mg/L', 'result', null, 370),
    ('n_total', 'N Total', 'mg/L-N', 'result', null, 380),
    ('ph_muestreo', 'pH muestreo', 'U. de pH', 'result', null, 390),
    ('plomo', 'Pb', 'mg/L', 'result', null, 400),
    ('pt', 'PT', 'mg P/L', 'result', null, 410),
    ('solidos_sedimentables', 'S. Sed', 'ml/L', 'result', null, 420),
    ('sst', 'SST', 'mg/L', 'result', null, 430),
    ('temperatura', 'Temperatura', '° C', 'result', null, 440),
    ('zn', 'Zn', 'mg/L', 'result', null, 450),
    ('enterococcos', 'Enterococcos', 'NMP/100mL', 'result', null, 460),
    ('cot', 'COT', 'mg/L', 'result', null, 470)
  )
  select p_sample_id, row_key, label, unit, row_type, aggregation, display_order from catalog
  on conflict (sample_id, row_key) do update set
    label = excluded.label, unit = excluded.unit, row_type = excluded.row_type,
    aggregation = excluded.aggregation, display_order = excluded.display_order;
end;
$$;

create or replace function public.keep_nom001_2021_24h_exact_rows()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.row_key in ('ph', 'cromo_vi') and exists (
    select 1 from public.samples s join public.analysis_orders ao on ao.id = s.order_id
    join public.analysis_packages ap on ap.id = ao.package_id
    where s.id = new.sample_id and ap.code = 'NOM-001-2021-24H'
  ) then
    perform public.ensure_nom001_2021_24h_exact_template(new.sample_id);
  end if;
  return new;
end;
$$;

drop trigger if exists keep_nom001_2021_24h_exact_rows on public.analysis_order_rows;
create trigger keep_nom001_2021_24h_exact_rows
after insert on public.analysis_order_rows for each row execute function public.keep_nom001_2021_24h_exact_rows();

select public.ensure_nom001_2021_24h_exact_template(s.id)
from public.samples s
join public.analysis_orders ao on ao.id = s.order_id
join public.analysis_packages ap on ap.id = ao.package_id
where ap.code = 'NOM-001-2021-24H';
