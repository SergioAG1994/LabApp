import test from "node:test";
import assert from "node:assert/strict";
import pg from "pg";
import { readFile } from "node:fs/promises";
import { PostgresDatabase } from "../src/database.js";
import { harness } from "./helpers.js";
// This test owns its disposable database. Never point at production.
const url = process.env.TEST_DATABASE_URL;
test(
  "PostgreSQL grants, RLS, output limits, timeouts, and definer audit through MCP",
  { skip: !url || process.env.LABAPP_MCP_DISPOSABLE_DB !== "1" },
  async (t) => {
    const admin = new pg.Pool({ connectionString: url });
    t.after(() => admin.end());
    await admin.query(`CREATE TABLE public.parameters(id uuid,name text,par_form text,unit text,method_reference text,decimal_places int,result_kind text,active bool,assigned_analyst_id uuid);
 CREATE TABLE public.analysis_packages(id uuid,code text,name text,active bool);
 CREATE TABLE public.package_parameters(package_id uuid,parameter_id uuid);
 CREATE TABLE public.private_clients(id int,secret text);
 INSERT INTO public.parameters(id,name,active) VALUES ('11111111-1111-4111-8111-111111111111','pH',true);
 ALTER TABLE public.parameters ENABLE ROW LEVEL SECURITY;
 ALTER TABLE public.analysis_packages ENABLE ROW LEVEL SECURITY;
 ALTER TABLE public.package_parameters ENABLE ROW LEVEL SECURITY;
 REVOKE TEMPORARY,CREATE ON DATABASE postgres FROM PUBLIC;
 REVOKE CREATE ON SCHEMA public FROM PUBLIC;
 DO $$ DECLARE routine record; BEGIN
 FOR routine IN SELECT oid::regprocedure AS signature FROM pg_proc
 WHERE pronamespace='pg_catalog'::regnamespace AND proname IN
 ('lo_create','lo_creat','lo_from_bytea','lo_put','lo_unlink','lowrite','lo_truncate','lo_truncate64','lo_import','lo_export')
 LOOP EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC',routine.signature); END LOOP;
 END $$;`);
    const provision = (
      await readFile(
        new URL("../sql/provision-reader.sql", import.meta.url),
        "utf8",
      )
    ).replace(':"DBNAME"', "postgres");
    await admin.query(provision);
    await admin.query(
      "ALTER ROLE labapp_mcp_reader PASSWORD 'reader-test-only'",
    );
    const readerUrl = new URL(url!);
    readerUrl.username = "labapp_mcp_reader";
    readerUrl.password = "reader-test-only";
    const pool = new pg.Pool({
      connectionString: readerUrl.toString(),
      max: 5,
    });
    t.after(() => pool.end());
    // Exercise the production timeout. A 100 ms test override can cancel the
    // permission audit itself on a cold or contended CI runner.
    const h = await harness({ database: new PostgresDatabase(pool) });
    t.after(h.close);
    const call = (sql: string, params?: unknown[]) =>
      h.call("query", { sql, params });
    let r = await call("select $1::text as value, $2::int as count", [
      "a';select 2",
      7,
    ]);
    assert(!r.error, JSON.stringify(r.value));
    assert.deepEqual(r.value.rows, [["a';select 2", 7]]);
    assert.deepEqual(r.value.columns, ["value", "count"]);
    assert.equal(r.value.truncated, false);
    r = await call("select $1::jsonb as data", [{ nested: { ok: true } }]);
    assert.deepEqual(r.value.rows, [[{ nested: { ok: true } }]]);
    r = await call("SHOW transaction_read_only");
    assert.deepEqual(r.value.rows, [["on"]]);
    r = await call("SHOW statement_timeout");
    assert.deepEqual(r.value.rows, [["15s"]]);
    r = await call("select i from generate_series(1,1005) i");
    assert(!r.error, JSON.stringify(r.value));
    assert.equal(r.value.rows.length, 1000);
    assert.equal(r.value.rowCount, 1005);
    assert.equal(r.value.truncated, true);
    assert.match(r.value.truncationNotice, /processed the full/);
    r = await call("select repeat('x',10000) from generate_series(1,150)");
    assert(!r.error);
    assert(r.value.rows.length < 150);
    assert.equal(r.value.rowCount, 150);
    assert(r.value.truncated);
    r = await call("select name from public.parameters");
    assert.deepEqual(r.value.rows, [["pH"]]);
    for (const sql of [
      "select * from private_clients",
      "select assigned_analyst_id from parameters",
      "WITH changed AS (DELETE FROM parameters RETURNING *) SELECT * FROM changed",
      "EXPLAIN ANALYZE DELETE FROM parameters",
      "select 1; select 2",
    ]) {
      r = await call(sql);
      assert(r.error, sql);
    }
    r = await call("select pg_sleep(30)");
    assert(r.error);
    assert.equal(r.value.code, "QUERY_TIMEOUT");
    // Grants still prevent writes even after explicitly disabling read-only mode.
    const direct = await pool.connect();
    try {
      await direct.query("SET default_transaction_read_only=off");
      await assert.rejects(
        direct.query("INSERT INTO parameters(name) VALUES('bad')"),
      );
      await assert.rejects(direct.query("CREATE TEMP TABLE bad(i int)"));
      await assert.rejects(direct.query("SELECT lo_create(0)"));
    } finally {
      direct.release(true);
    }
    await admin.query(
      "CREATE FUNCTION public.unsafe_write() RETURNS void LANGUAGE sql SECURITY DEFINER AS $$INSERT INTO private_clients VALUES(1,'bad')$$",
    );
    r = await call("select 1");
    assert(r.error);
    assert.equal(r.value.code, "UNSAFE_DATABASE_ROLE");
    await admin.query(
      "REVOKE EXECUTE ON FUNCTION public.unsafe_write() FROM PUBLIC",
    );
    r = await call("select 1");
    assert(!r.error, JSON.stringify(r.value));
    await admin.query("GRANT SELECT ON private_clients TO labapp_mcp_reader");
    r = await call("select 1");
    assert.equal(r.value.code, "UNSAFE_DATABASE_ROLE");
    await admin.query(
      "REVOKE SELECT ON private_clients FROM labapp_mcp_reader",
    );
    await admin.query("GRANT UPDATE(name) ON parameters TO labapp_mcp_reader");
    r = await call("select 1");
    assert.equal(r.value.code, "UNSAFE_DATABASE_ROLE");
    await admin.query(
      "REVOKE UPDATE(name) ON parameters FROM labapp_mcp_reader",
    );
    assert.equal(
      (await admin.query("SELECT count(*)::int AS count FROM private_clients"))
        .rows[0].count,
      0,
    );
  },
);
