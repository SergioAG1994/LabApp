-- Seguridad de las plantillas importadas. Ejecutar después de 015.

alter table public.analysis_package_rows enable row level security;

create policy "authenticated read analysis package rows"
on public.analysis_package_rows for select to authenticated using (true);

revoke all on function public.create_template_rows_for_sample() from public, anon, authenticated;
revoke execute on function public.create_analysis_order_rows_from_package(uuid) from public, anon;
grant execute on function public.create_analysis_order_rows_from_package(uuid) to authenticated;
