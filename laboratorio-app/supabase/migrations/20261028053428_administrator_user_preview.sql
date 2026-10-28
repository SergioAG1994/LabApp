-- SER-35: the actor keeps their Auth session; only transaction-local Data API
-- claims change. Existing RLS and read RPCs therefore see the observed account.
begin;
set local lock_timeout = '5s';

create table private.user_preview_sessions (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references auth.users(id),
  auth_session_id uuid not null,
  target_id uuid not null references public.profiles(id),
  started_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '1 hour'),
  ended_at timestamptz,
  end_reason text,
  check (actor_id <> target_id)
);
alter table private.user_preview_sessions enable row level security;
revoke all on private.user_preview_sessions from public, anon, authenticated;
create unique index user_preview_active_session_idx
  on private.user_preview_sessions(auth_session_id) where ended_at is null;
create index user_preview_actor_idx on private.user_preview_sessions(actor_id);
create index user_preview_target_idx on private.user_preview_sessions(target_id);

create function private.close_user_preview(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare item private.user_preview_sessions;
begin
  update private.user_preview_sessions set ended_at = clock_timestamp(), end_reason = p_reason
  where id = p_id and ended_at is null returning * into item;
  if found then
    insert into public.audit_events(actor_id, entity_type, entity_id, action, after_data)
    values (item.actor_id, 'user_preview_sessions', item.id, 'end_user_preview',
      jsonb_build_object('target_id', item.target_id, 'started_at', item.started_at,
        'ended_at', item.ended_at, 'reason', p_reason));
  end if;
end $$;

create function private.user_preview_payload(p_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', s.id, 'userId', p.id,
    'fullName', coalesce(nullif(p.full_name, ''), u.email, 'Usuario'),
    'role', case when p.role::text = 'revisor' then 'recepcion' else p.role::text end,
    'expiresAt', s.expires_at)
  from private.user_preview_sessions s join public.profiles p on p.id = s.target_id
  join auth.users u on u.id = p.id where s.id = p_id
$$;

create function public.get_user_preview()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  sid uuid := nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'session_id';
  item private.user_preview_sessions;
begin
  if current_setting('app.preview_hook_ready', true) is distinct from 'true' then
    raise exception 'Falta activar la migración de vista simulada en el servidor' using errcode = 'P0001';
  end if;
  select * into item from private.user_preview_sessions
  where auth_session_id = sid and actor_id = auth.uid() and ended_at is null;
  if not found then return null; end if;
  if item.expires_at <= now()
     or not exists(select 1 from auth.sessions where id = sid and user_id = auth.uid() and (not_after is null or not_after > now()))
     or not exists(select 1 from public.profiles where id = auth.uid() and role = 'administrador')
     or not exists(select 1 from public.profiles where id = item.target_id) then
    perform private.close_user_preview(item.id, 'expired_or_revoked');
    return null;
  end if;
  return private.user_preview_payload(item.id);
end $$;

create function public.start_user_preview(p_target_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  sid uuid := nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'session_id';
  previous_id uuid;
  preview_id uuid;
begin
  if current_setting('app.preview_hook_ready', true) is distinct from 'true' then
    raise exception 'Falta activar la migración de vista simulada en el servidor';
  end if;
  if auth.uid() is null or not exists(
    select 1 from public.profiles where id = auth.uid() and role = 'administrador'
  ) then raise exception 'Sólo un administrador puede iniciar la vista simulada' using errcode = '42501'; end if;
  -- Serializes starts/exits for this real Auth session (including other tabs).
  perform 1 from auth.sessions where id = sid and user_id = auth.uid()
    and (not_after is null or not_after > now()) for update;
  if not found then raise exception 'La sesión no es válida' using errcode = '42501'; end if;
  if p_target_id = auth.uid() or not exists(
    select 1 from public.profiles p join auth.users u on u.id = p.id
    where p.id = p_target_id and p.role::text in ('administrador','recepcion','analista','revisor')
  ) then raise exception 'Selecciona otra cuenta válida'; end if;
  select id into previous_id from private.user_preview_sessions where auth_session_id = sid and ended_at is null;
  perform private.close_user_preview(previous_id, 'replaced');
  insert into private.user_preview_sessions(actor_id, auth_session_id, target_id)
    values(auth.uid(), sid, p_target_id) returning id into preview_id;
  insert into public.audit_events(actor_id, entity_type, entity_id, action, after_data)
    values(auth.uid(), 'user_preview_sessions', preview_id, 'start_user_preview',
      jsonb_build_object('target_id', p_target_id, 'started_at', now()));
  return private.user_preview_payload(preview_id);
end $$;

create function public.end_user_preview()
returns void language plpgsql security definer set search_path = '' as $$
declare
  sid uuid := nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'session_id';
  preview_id uuid;
begin
  -- The original actor can always exit, even after losing administrator access.
  perform 1 from auth.sessions where id = sid and user_id = auth.uid() for update;
  select id into preview_id from private.user_preview_sessions
    where auth_session_id = sid and actor_id = auth.uid() and ended_at is null;
  perform private.close_user_preview(preview_id, 'exited');
end $$;

create function private.apply_user_preview()
returns void language plpgsql security definer set search_path = '' as $$
declare
  claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  headers jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  request_path text := current_setting('request.path', true);
  method text := current_setting('request.method', true);
  actor uuid := nullif(claims->>'sub', '')::uuid;
  sid uuid := nullif(claims->>'session_id', '')::uuid;
  item private.user_preview_sessions;
  target_claims jsonb;
begin
  perform set_config('app.preview_hook_ready', 'true', true);
  -- Control calls retain the actor's identity and are the only allowed writes.
  if request_path in ('/rpc/get_user_preview','/rpc/start_user_preview','/rpc/end_user_preview') then return; end if;
  if claims->>'role' is distinct from 'authenticated' then return; end if;
  select * into item from private.user_preview_sessions
    where auth_session_id = sid and actor_id = actor and ended_at is null;
  if not found then
    if nullif(headers->>'x-user-preview', '') is not null then
      raise exception 'La vista simulada terminó. Actualiza la aplicación.' using errcode = '42501';
    end if;
    return;
  end if;
  if (nullif(headers->>'x-user-preview', '') is not null and headers->>'x-user-preview' <> item.id::text)
     or item.expires_at <= now()
     or not exists(select 1 from auth.sessions where id = sid and user_id = actor and (not_after is null or not_after > now()))
     or not exists(select 1 from public.profiles where id = actor and role = 'administrador') then
    raise exception 'La vista simulada caducó o fue revocada. Sal de la vista simulada.' using errcode = '42501';
  end if;
  -- No arbitrary RPCs, including those invoked with GET: privileged RPCs can
  -- write independently of RLS. Only audited, read-only application RPCs pass.
  if request_path like '/rpc/%' then
    if request_path not in ('/rpc/list_staff_samples','/rpc/list_completed_staff_samples',
      '/rpc/load_staff_sample_worksheet','/rpc/list_assignable_staff','/rpc/list_sample_report_staff')
      or method not in ('GET','HEAD','POST') then
      raise exception 'La vista simulada es de solo lectura' using errcode = '42501';
    end if;
  elsif method not in ('GET','HEAD') then
    raise exception 'La vista simulada es de solo lectura' using errcode = '42501';
  end if;
  select jsonb_build_object('sub', u.id, 'role', 'authenticated', 'aud', 'authenticated',
    'email', u.email, 'app_metadata', u.raw_app_meta_data, 'user_metadata', u.raw_user_meta_data,
    'session_id', sid, 'aal', claims->>'aal') into target_claims
    from auth.users u join public.profiles p on p.id = u.id where u.id = item.target_id;
  if target_claims is null then raise exception 'La cuenta observada ya no existe' using errcode = '42501'; end if;
  perform set_config('request.jwt.claims', target_claims::text, true);
  perform set_config('request.jwt.claim.sub', item.target_id::text, true);
end $$;

-- Defense for other database entry points (e.g. GraphQL) and for future read
-- RPCs that accidentally acquire a side effect. No application writes may run
-- while this real Auth session has an active preview.
create function private.reject_user_preview_write()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
begin
  if claims->>'role' = 'authenticated'
     and current_setting('request.path', true) is distinct from '/rpc/start_user_preview'
     and exists(select 1 from private.user_preview_sessions
       where auth_session_id = nullif(claims->>'session_id', '')::uuid and ended_at is null) then
    raise exception 'La vista simulada es de solo lectura' using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then return old; else return new; end if;
end $$;
revoke all on function private.reject_user_preview_write() from public, anon, authenticated;
do $$ declare item record; begin
  for item in select tablename from pg_tables where schemaname = 'public' loop
    execute format('create trigger aa_reject_user_preview_write before insert or update or delete on public.%I for each row execute function private.reject_user_preview_write()', item.tablename);
  end loop;
end $$;

revoke all on function private.close_user_preview(uuid,text), private.user_preview_payload(uuid),
  private.apply_user_preview() from public, anon, authenticated;
revoke all on function public.get_user_preview(), public.start_user_preview(uuid),
  public.end_user_preview() from public, anon, authenticated;
grant execute on function public.get_user_preview(), public.start_user_preview(uuid),
  public.end_user_preview() to authenticated;
grant usage on schema private to anon, authenticated, service_role;
grant execute on function private.apply_user_preview() to anon, authenticated, service_role;

-- Do not silently replace another integration's pre-request hook.
do $$ begin
  if exists(select 1 from pg_db_role_setting s, unnest(s.setconfig) c
    where c like 'pgrst.db_pre_request=%' and c <> 'pgrst.db_pre_request=private.apply_user_preview') then
    raise exception 'Ya existe un db_pre_request. Integra ambos controles antes de continuar.';
  end if;
end $$;
alter role authenticator set pgrst.db_pre_request = 'private.apply_user_preview';
notify pgrst, 'reload config';
notify pgrst, 'reload schema';
commit;
