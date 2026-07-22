-- Campos manuales por parámetro, de acuerdo con el formato de Orden de Análisis.
alter table public.analysis_order_rows
  add column if not exists uncertainty numeric(14,5),
  add column if not exists analyst_reference text,
  add column if not exists released_by text;

alter table public.analysis_order_rows
  drop constraint if exists analysis_order_rows_uncertainty_nonnegative;

alter table public.analysis_order_rows
  add constraint analysis_order_rows_uncertainty_nonnegative
  check (uncertainty is null or uncertainty >= 0);
