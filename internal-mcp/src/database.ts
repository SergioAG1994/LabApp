import pg from "pg";
import { parse } from "pgsql-parser";
import { ToolError } from "./errors.js";

export interface Database {
  query(sql: string, params?: unknown[]): Promise<Record<string, unknown>>;
}
export const MAX_ROWS = 1000;
const MAX_OUTPUT_BYTES = 1_000_000;
// This is a credential audit, not a SQL authorization mechanism. PostgreSQL grants
// remain authoritative, including when a SELECT invokes a function or writable CTE.
export const AUDIT_SQL = `SELECT
  current_user = 'labapp_mcp_reader' AND NOT EXISTS (
    SELECT FROM pg_roles WHERE rolname = current_user AND
      (rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls)
  ) AND NOT EXISTS (SELECT FROM pg_auth_members WHERE member = (SELECT oid FROM pg_roles WHERE rolname = current_user))
  AND NOT has_database_privilege(current_database(), 'CREATE')
  AND NOT has_database_privilege(current_database(), 'TEMP')
  AND NOT EXISTS (SELECT FROM pg_namespace WHERE has_schema_privilege(oid, 'CREATE'))
  AND NOT EXISTS (
    SELECT FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE (p.prosecdef OR n.nspname NOT IN ('pg_catalog','information_schema')
      OR p.proname IN ('lo_create','lo_creat','lo_from_bytea','lo_put','lo_unlink','lowrite','lo_truncate','lo_truncate64','lo_import','lo_export'))
      AND has_schema_privilege(n.oid,'USAGE') AND has_function_privilege(p.oid,'EXECUTE')
  ) AND NOT EXISTS (
    SELECT FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname !~ '^pg_toast'
    AND ((c.relkind IN ('r','p','v','m','f') AND (
      has_table_privilege(c.oid,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
      OR has_any_column_privilege(c.oid,'INSERT,UPDATE,REFERENCES')
      OR (has_any_column_privilege(c.oid,'SELECT') AND NOT
        (n.nspname='public' AND c.relname IN ('parameters','analysis_packages','package_parameters') AND c.relkind IN ('r','p')))
    )) OR (c.relkind='S' AND has_sequence_privilege(c.oid,'USAGE,UPDATE')))
  ) AND NOT EXISTS (
    SELECT FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relname IN ('parameters','analysis_packages','package_parameters')
    AND a.attnum>0 AND NOT a.attisdropped AND has_column_privilege(c.oid,a.attname,'SELECT')
    AND NOT ((c.relname='parameters' AND a.attname IN ('id','name','par_form','unit','method_reference','decimal_places','result_kind','active'))
      OR (c.relname='analysis_packages' AND a.attname IN ('id','code','name','active'))
      OR (c.relname='package_parameters' AND a.attname IN ('package_id','parameter_id')))
  ) AND NOT EXISTS (
    SELECT FROM pg_operator o JOIN pg_proc p ON p.oid=o.oprcode
    JOIN pg_namespace n ON n.oid=o.oprnamespace
    WHERE has_schema_privilege(n.oid,'USAGE') AND
      (p.prosecdef OR p.pronamespace <> 'pg_catalog'::regnamespace)
  ) AND NOT EXISTS (
    SELECT FROM pg_cast c JOIN pg_proc p ON p.oid=c.castfunc
    WHERE p.prosecdef OR p.pronamespace <> 'pg_catalog'::regnamespace
  ) AS safe`;

export async function validateStatement(sql: string) {
  let ast;
  try {
    ast = await parse(sql);
  } catch {
    throw new ToolError("INVALID_SQL", "SQL could not be parsed.");
  }
  if (!ast.stmts || ast.stmts.length !== 1)
    throw new ToolError(
      "SINGLE_STATEMENT_REQUIRED",
      "Supply exactly one SQL statement.",
    );
  const kind = Object.keys(ast.stmts[0]!.stmt!)[0];
  // Prevent ending the wrapper transaction, changing roles/settings, and opening
  // cursors. This supplements (and cannot replace) SELECT-only database grants.
  if (!["SelectStmt", "ExplainStmt", "VariableShowStmt"].includes(kind ?? ""))
    throw new ToolError(
      "UNSUPPORTED_STATEMENT",
      "Only query, SHOW and EXPLAIN statements are supported. Database permissions enforce read-only access.",
    );
}

export class PostgresDatabase implements Database {
  constructor(
    private pool: pg.Pool,
    private timeoutMs = 15_000,
  ) {}
  async query(sql: string, params: unknown[] = []) {
    await validateStatement(sql);
    const client = await this.pool.connect().catch(() => {
      throw new ToolError(
        "DATABASE_UNAVAILABLE",
        "Could not connect to the database.",
      );
    });
    try {
      await client.query("BEGIN READ ONLY");
      await client.query(
        `SELECT set_config('statement_timeout', $1, true), set_config('lock_timeout', $1, true), set_config('search_path', 'pg_catalog,public', true)`,
        [String(this.timeoutMs)],
      );
      const audit = await client.query(AUDIT_SQL);
      if (audit.rows[0]?.safe !== true)
        throw new ToolError(
          "UNSAFE_DATABASE_ROLE",
          "Database role failed the permission audit. See the provisioning guide.",
        );
      // Stream rows instead of buffering the entire result. Never inject LIMIT:
      // the output cap is independent of database work and total row count.
      return await new Promise<Record<string, unknown>>((resolve, reject) => {
        const rows: unknown[][] = [];
        let rowCount = 0,
          bytes = 0,
          outputFull = false;
        const q = new pg.Query({
          text: sql,
          values: params,
          rowMode: "array",
          queryMode: "extended",
        } as pg.QueryConfig);
        q.on("row", (row: unknown[]) => {
          rowCount++;
          if (outputFull) return;
          const size = Buffer.byteLength(JSON.stringify(row));
          if (rows.length === MAX_ROWS || bytes + size > MAX_OUTPUT_BYTES) {
            outputFull = true;
            return;
          }
          bytes += size;
          rows.push(row);
        });
        q.on("error", reject);
        q.on("end", (result: pg.QueryResult) =>
          resolve({
            rows,
            columns: result.fields.map((f) => f.name),
            rowCount,
            returnedRowCount: rows.length,
            truncated: outputFull,
            truncationNotice: outputFull
              ? "Output truncated at 1,000 rows or 1 MB. The database processed the full statement; rowCount is the total result row count."
              : null,
          }),
        );
        client.query(q);
      });
    } catch (error) {
      if (error instanceof ToolError) throw error;
      const code = (error as { code?: string }).code;
      throw new ToolError(
        code === "57014" ? "QUERY_TIMEOUT" : "QUERY_FAILED",
        code === "57014"
          ? "Database statement exceeded its timeout."
          : "Database rejected or could not complete the query.",
        { sqlState: /^[0-9A-Z]{5}$/.test(code ?? "") ? code : undefined },
      );
    } finally {
      // Destroy the session: SELECT set_config(), advisory locks and session state
      // must never survive into another agent's call. Disconnect rolls back.
      client.release(true);
    }
  }
}
