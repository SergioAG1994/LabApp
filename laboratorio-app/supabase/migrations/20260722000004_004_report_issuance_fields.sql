-- Campos que se llenan al emitir el informe final.
alter table public.analysis_orders
  add column if not exists issued_at date;
