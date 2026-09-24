-- Corrige los privilegios por defecto de las funciones SECURITY DEFINER
-- reemplazadas en 016. Las funciones operativas sólo se exponen a usuarios
-- autenticados; la función de trigger no se expone como RPC.

revoke all on function public.create_analysis_order(text, text, integer, date)
  from public;

revoke all on function public.create_analysis_order(text, text, integer, date)
  from anon;

grant execute on function public.create_analysis_order(text, text, integer, date)
  to authenticated;

revoke all on function public.create_nom001_2021_24h_rows(uuid)
  from public;

revoke all on function public.create_nom001_2021_24h_rows(uuid)
  from anon;

grant execute on function public.create_nom001_2021_24h_rows(uuid)
  to authenticated;

revoke all on function public.create_sample_entry(
  text,
  text,
  text,
  text,
  date,
  date,
  text,
  text,
  text,
  boolean
) from public;

revoke all on function public.create_sample_entry(
  text,
  text,
  text,
  text,
  date,
  date,
  text,
  text,
  text,
  boolean
) from anon;

grant execute on function public.create_sample_entry(
  text,
  text,
  text,
  text,
  date,
  date,
  text,
  text,
  text,
  boolean
) to authenticated;

revoke all on function public.keep_nom001_2021_24h_exact_rows()
  from public;

revoke all on function public.keep_nom001_2021_24h_exact_rows()
  from anon;

revoke all on function public.keep_nom001_2021_24h_exact_rows()
  from authenticated;
