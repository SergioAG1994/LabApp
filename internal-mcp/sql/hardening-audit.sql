-- READ-ONLY audit. Run as administrator before enabling production access and
-- after migrations. Do not automatically apply broad revokes to a Supabase DB.
-- A grant inherited from PUBLIC cannot be negated with REVOKE ... FROM reader.
-- Transfer required PUBLIC privileges to intended application roles, then revoke
-- PUBLIC privileges in an independently reviewed migration.
SELECT n.nspname AS schema, p.oid::regprocedure AS routine, p.prosecdef AS security_definer,
       pg_get_userbyid(p.proowner) AS owner, p.proacl,
       has_schema_privilege('labapp_mcp_reader', n.oid, 'USAGE')
       AND has_function_privilege('labapp_mcp_reader', p.oid, 'EXECUTE') AS callable
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE p.prosecdef OR n.nspname NOT IN ('pg_catalog','information_schema')
   OR p.proname IN ('lo_create','lo_creat','lo_from_bytea','lo_put','lo_unlink',
                   'lowrite','lo_truncate','lo_truncate64','lo_import','lo_export')
ORDER BY n.nspname,p.proname;
-- All callable SECURITY DEFINER routines are rejected, even in system schemas.
-- All callable non-system invoker routines are also rejected: they may wrap
-- definer routines, network extensions, or untrusted procedural languages.
SELECT datname, datacl FROM pg_database WHERE datname=current_database();
SELECT nspname,nspacl FROM pg_namespace;
SELECT r.rolname,r.rolsuper,r.rolcreaterole,r.rolcreatedb,r.rolreplication,r.rolbypassrls,
       r.rolconfig FROM pg_roles r WHERE r.rolname='labapp_mcp_reader';
SELECT * FROM pg_auth_members WHERE member=(SELECT oid FROM pg_roles WHERE rolname='labapp_mcp_reader');
-- Typical hardening actions, ONLY after preserving privileges needed by apps:
-- REVOKE TEMPORARY, CREATE ON DATABASE database_name FROM PUBLIC;
-- REVOKE CREATE ON SCHEMA public FROM PUBLIC;
-- REVOKE EXECUTE ON FUNCTION public.some_function(argtypes) FROM PUBLIC;
-- GRANT EXECUTE ON FUNCTION public.some_function(argtypes) TO authenticated;
-- Repeat default privilege rules for EVERY role that owns/creates routines:
-- ALTER DEFAULT PRIVILEGES FOR ROLE owner IN SCHEMA public
--   REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
-- Audit extension schemas too, including net/dblink/storage/auth as applicable.
-- Never grant this login membership in authenticated/service_role/admin roles.

-- Include the listed pg_catalog large-object mutation routines: they can create
-- or write large objects without table grants. Preserve required application
-- EXECUTE grants before revoking PUBLIC; changing default read-only alone is
-- not a replacement for these ACLs.
