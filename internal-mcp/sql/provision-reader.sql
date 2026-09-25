-- Run as a database administrator after reviewing hardening-audit.sql.
-- No passwords in this file. Set the password with psql \password afterwards.
-- Intentional choice: no global RLS bypass. Cross-user access is limited to
-- these non-sensitive catalogs via explicit SELECT policies. No patient/client,
-- staff assignment, auth, orders, results, reports, or audit-event grants.
BEGIN;
CREATE ROLE labapp_mcp_reader LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
  NOINHERIT NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 5;
ALTER ROLE labapp_mcp_reader SET default_transaction_read_only = on;
ALTER ROLE labapp_mcp_reader SET statement_timeout = '15s';
ALTER ROLE labapp_mcp_reader SET idle_in_transaction_session_timeout = '20s';
ALTER ROLE labapp_mcp_reader SET search_path = pg_catalog, public;
GRANT CONNECT ON DATABASE :"DBNAME" TO labapp_mcp_reader;
GRANT USAGE ON SCHEMA public TO labapp_mcp_reader;
GRANT SELECT (id,name,par_form,unit,method_reference,decimal_places,result_kind,active)
  ON public.parameters TO labapp_mcp_reader;
GRANT SELECT (id,code,name,active) ON public.analysis_packages TO labapp_mcp_reader;
GRANT SELECT (package_id,parameter_id) ON public.package_parameters TO labapp_mcp_reader;
CREATE POLICY mcp_catalog_read ON public.parameters FOR SELECT TO labapp_mcp_reader USING (true);
CREATE POLICY mcp_catalog_read ON public.analysis_packages FOR SELECT TO labapp_mcp_reader USING (true);
CREATE POLICY mcp_catalog_read ON public.package_parameters FOR SELECT TO labapp_mcp_reader USING (true);
-- No blanket/default SELECT grants: newly added tables/columns require review.
COMMIT;
