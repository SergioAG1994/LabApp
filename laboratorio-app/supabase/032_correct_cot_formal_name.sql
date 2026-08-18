-- Corrige el nombre formal de COT reportado en el catálogo fuente.

update public.parameters
set par_form = 'Carbono Orgánico Total'
where name = 'COT';
