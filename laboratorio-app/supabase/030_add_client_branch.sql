-- Sucursal del cliente utilizada en recepción e informes.

alter table public.clients
  add column if not exists branch text;

comment on column public.clients.branch is
  'Sucursal, planta o ubicación operativa del cliente.';

drop function if exists public.create_client(text, text, text, text, text, text, text);

create function public.create_client(
  p_name text,
  p_contact_name text default null,
  p_email text default null,
  p_phone text default null,
  p_address text default null,
  p_rfc text default null,
  p_attention_to text default null,
  p_branch text default null
)
returns public.clients
language plpgsql
security definer
set search_path = public
as $$
declare v_client public.clients;
begin
  if auth.uid() is null or public.current_role() not in ('administrador', 'recepcion') then
    raise exception 'No tienes permiso para dar de alta clientes';
  end if;
  if nullif(trim(coalesce(p_name, '')), '') is null then
    raise exception 'El nombre del cliente es obligatorio';
  end if;

  insert into public.clients (
    name, contact_name, email, phone, address, rfc, attention_to, branch
  ) values (
    trim(p_name), nullif(trim(p_contact_name), ''), nullif(trim(p_email), ''),
    nullif(trim(p_phone), ''), nullif(trim(p_address), ''), nullif(trim(p_rfc), ''),
    nullif(trim(p_attention_to), ''), nullif(trim(p_branch), '')
  )
  on conflict (name) do update set
    contact_name = coalesce(excluded.contact_name, public.clients.contact_name),
    email = coalesce(excluded.email, public.clients.email),
    phone = coalesce(excluded.phone, public.clients.phone),
    address = coalesce(excluded.address, public.clients.address),
    rfc = coalesce(excluded.rfc, public.clients.rfc),
    attention_to = coalesce(excluded.attention_to, public.clients.attention_to),
    branch = coalesce(excluded.branch, public.clients.branch)
  returning * into v_client;

  return v_client;
end;
$$;

revoke execute on function public.create_client(text, text, text, text, text, text, text, text)
  from public, anon;
grant execute on function public.create_client(text, text, text, text, text, text, text, text)
  to authenticated;
