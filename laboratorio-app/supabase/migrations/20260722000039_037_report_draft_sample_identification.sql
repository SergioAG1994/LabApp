-- Datos manuales de identificación que se conservan con el pre-informe.

alter table public.report_drafts
  add column if not exists sample_identification text not null default '',
  add column if not exists requested_by text not null default '';
