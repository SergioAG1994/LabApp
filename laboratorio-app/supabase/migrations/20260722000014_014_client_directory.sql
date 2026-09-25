-- Directorio de clientes con folio legible para recepción e informes.
-- Ejecutar después de 013_worksheet_report_action.sql.

create sequence if not exists public.client_number_seq start with 1;

alter table public.clients
  add column if not exists client_number bigint;

update public.clients
set client_number = nextval('public.client_number_seq')
where client_number is null;

alter table public.clients
  alter column client_number set default nextval('public.client_number_seq'),
  alter column client_number set not null;

alter sequence public.client_number_seq owned by public.clients.client_number;

create unique index if not exists clients_client_number_unique
on public.clients (client_number);

create or replace function public.create_client(
  p_name text,
  p_contact_name text default null,
  p_email text default null,
  p_phone text default null,
  p_address text default null,
  p_rfc text default null,
  p_attention_to text default null
)
returns public.clients
language plpgsql security definer set search_path = public as $$
declare v_client public.clients;
begin
  if auth.uid() is null or public.current_role() not in ('administrador', 'recepcion') then
    raise exception 'No tienes permiso para dar de alta clientes';
  end if;
  if nullif(trim(coalesce(p_name, '')), '') is null then
    raise exception 'El nombre del cliente es obligatorio';
  end if;
  insert into public.clients (name, contact_name, email, phone, address, rfc, attention_to)
  values (
    trim(p_name), nullif(trim(p_contact_name), ''), nullif(trim(p_email), ''),
    nullif(trim(p_phone), ''), nullif(trim(p_address), ''), nullif(trim(p_rfc), ''),
    nullif(trim(p_attention_to), '')
  )
  on conflict (name) do update set
    contact_name = coalesce(excluded.contact_name, public.clients.contact_name),
    email = coalesce(excluded.email, public.clients.email),
    phone = coalesce(excluded.phone, public.clients.phone),
    address = coalesce(excluded.address, public.clients.address),
    rfc = coalesce(excluded.rfc, public.clients.rfc),
    attention_to = coalesce(excluded.attention_to, public.clients.attention_to)
  returning * into v_client;
  return v_client;
end;
$$;

-- Recepción puede consultar el cliente por número sin repetir sus datos en la OP.
create or replace function public.get_client_by_number(p_client_number bigint)
returns public.clients
language sql stable security definer set search_path = public as $$
  select * from public.clients where client_number = p_client_number and active = true;
$$;

grant usage, select on sequence public.client_number_seq to authenticated;
grant execute on function public.create_client(text, text, text, text, text, text, text) to authenticated;
grant execute on function public.get_client_by_number(bigint) to authenticated;
