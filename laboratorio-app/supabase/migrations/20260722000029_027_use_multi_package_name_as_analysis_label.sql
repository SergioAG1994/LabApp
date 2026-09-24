begin;

create or replace function public.set_multi_package_analysis_label()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if new.multi_package_id is not null then
    select mp.name
      into new.analysis_label
    from public.multi_packages mp
    where mp.id = new.multi_package_id;
  end if;

  return new;
end;
$$;

drop trigger if exists set_multi_package_analysis_label on public.samples;
create trigger set_multi_package_analysis_label
before insert or update of multi_package_id on public.samples
for each row execute function public.set_multi_package_analysis_label();

update public.samples s
set analysis_label = mp.name
from public.multi_packages mp
where s.multi_package_id = mp.id
  and s.analysis_label is distinct from mp.name;

commit;
