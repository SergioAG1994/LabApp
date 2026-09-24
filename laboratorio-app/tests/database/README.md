# Database regression tests

Run `python3 laboratorio-app/tests/database/run.py` from the repository root with Docker running. The default image is `supabase/postgres:17.4.1.074` (override with `DB_TEST_IMAGE` if necessary). Pull it before the first run.

The runner creates a fresh PostgreSQL container with networking disabled, no exposed ports and no host mounts. It creates minimal synthetic Supabase auth roles/users infrastructure, applies `schema.sql` then numbered SQL files in filename order, and runs the numbered SQL tests. Each SQL test should wrap its synthetic fixtures in `begin` / `rollback`. `pg_temp.assert` and `pg_temp.assert_raises` are supplied. Numbered Python tests can expose `test(db)` when multiple concurrent connections are required.

The container and its anonymous volumes are removed on completion or failure. No production credentials are needed or read. These tests exercise PostgreSQL permissions and application functions; they do not simulate the hosted Auth service, PostgREST, or a production migration baseline.

Historical migrations have duplicate numeric prefixes. The runner deliberately preserves their existing filename order; it is not a production deployment tool. Before applying new migrations in production, verify its actual schema and migration history. CI validates changes but does not deploy them.
