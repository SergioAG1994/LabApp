# Database regression tests

Run `python3 laboratorio-app/tests/database/run.py` from the repository root with Docker running. The default image is `supabase/postgres:17.4.1.074` (override with `DB_TEST_IMAGE` if necessary). Pull it before the first run.

The runner creates a fresh PostgreSQL container with networking disabled, no exposed ports and no host mounts. It creates minimal synthetic Supabase auth roles/users infrastructure, applies `schema.sql` then numbered SQL files in filename order, and runs the numbered SQL tests. Each SQL test should wrap its synthetic fixtures in `begin` / `rollback`. `pg_temp.assert` and `pg_temp.assert_raises` are supplied. Numbered Python tests can expose `test(db)` when multiple concurrent connections are required.

The container and its anonymous volumes are removed on completion or failure. No production credentials are needed or read. These tests exercise PostgreSQL permissions and application functions; they do not simulate the hosted Auth service, PostgREST, or a production migration baseline.

Historical migrations have duplicate numeric prefixes. The runner deliberately preserves their existing filename order; it is not a production deployment tool. Before applying new migrations in production, verify its actual schema and migration history. The runner validates changes but does not deploy them.

The GitHub Actions `Validate` workflow runs this harness on pull requests and pushes to `main`. A separate application job runs UI helper tests, lint, and a production build with placeholder public Supabase settings. Both jobs use standard Ubuntu runners and need no repository secrets. For equivalent local application checks, run `node --test tests/ui/*.test.mjs`, `npm run lint`, and `npm run build` from `laboratorio-app` with Node 22.18+.
