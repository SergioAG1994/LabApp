create index if not exists analysis_orders_multi_package_id_idx
  on public.analysis_orders (multi_package_id);

create index if not exists analysis_results_parameter_id_idx
  on public.analysis_results (parameter_id);
