-- Permite que recepción y administración den de alta parámetros desde la app.
-- La lectura existente permanece disponible para los roles operativos.

drop policy if exists "reception creates parameters" on public.parameters;

create policy "reception creates parameters"
on public.parameters
for insert
to authenticated
with check (
  public.current_role() in ('administrador', 'recepcion')
);
