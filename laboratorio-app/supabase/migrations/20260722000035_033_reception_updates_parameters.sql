-- Permite corregir el catálogo sin exponerlo a los roles de análisis/revisión.

drop policy if exists "reception updates parameters" on public.parameters;

create policy "reception updates parameters"
on public.parameters
for update
to authenticated
using (public.current_role() in ('administrador', 'recepcion'))
with check (public.current_role() in ('administrador', 'recepcion'));
