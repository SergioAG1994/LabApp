#!/usr/bin/env python3
"""Replay repository migrations and test synthetic data in an isolated PostgreSQL container.

Requires Docker and Python 3. No ports, host mounts, or production credentials are used.
"""
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

APP = Path(__file__).resolve().parents[2]
IMAGE = os.environ.get("DB_TEST_IMAGE", "supabase/postgres:17.4.1.074")


class Database:
    def __init__(self):
        self.name = "labapp-db-test-" + uuid.uuid4().hex[:12]

    def command(self, *args, **kwargs):
        return subprocess.run(args, text=True, capture_output=True, timeout=120, **kwargs)

    def sql(self, source, *, check=True):
        result = self.command("docker", "exec", "-i", self.name, "psql", "-h", "/tmp", "-U", "postgres",
                              "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", input=source)
        if check and result.returncode:
            raise RuntimeError(result.stderr.strip())
        return result

    def __enter__(self):
        result = self.command("docker", "run", "-d", "--network", "none", "--name", self.name,
                              "--user", "postgres", "--entrypoint", "sh", IMAGE, "-c",
                              "initdb -D /tmp/labapp-test-pg -A trust >/tmp/init.log && "
                              "exec postgres -D /tmp/labapp-test-pg -k /tmp -c listen_addresses=''")
        if result.returncode:
            self.cleanup()
            raise RuntimeError(result.stderr.strip())
        try:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                ready = self.command("docker", "exec", self.name, "pg_isready", "-h", "/tmp", "-U", "postgres")
                if ready.returncode == 0:
                    return self
                time.sleep(0.2)
            logs = self.command("docker", "logs", self.name)
            raise RuntimeError("Database did not start: " + logs.stderr)
        except BaseException:
            self.cleanup()
            raise

    def cleanup(self):
        self.command("docker", "rm", "-fv", self.name)

    def __exit__(self, *_):
        self.cleanup()


BOOTSTRAP = """
create role anon nologin;
create role authenticated nologin;
create schema auth;
create table auth.users(id uuid primary key, raw_user_meta_data jsonb);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
grant usage on schema auth, public to authenticated, anon;
grant execute on function auth.uid() to authenticated, anon;
alter default privileges in schema public grant select, insert, update, delete on tables to authenticated, anon;
alter default privileges in schema public grant usage, select on sequences to authenticated, anon;
"""

ASSERTIONS = """
create function pg_temp.assert(ok boolean, message text) returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'Assertion failed: %', message; end if;
end $$;
create function pg_temp.assert_raises(statement text, expected text) returns void language plpgsql as $$
declare caught text;
begin
  begin
    execute statement;
  exception when others then caught := sqlerrm;
  end;
  if caught is null then raise exception 'Expected failure: %', statement; end if;
  if position(expected in caught) = 0 then raise exception 'Expected error containing %, got %', expected, caught; end if;
end $$;
"""


def main():
    with Database() as db:
        db.sql(BOOTSTRAP)
        migrations = sorted((APP / "supabase/migrations").glob("[0-9]*.sql"))
        if not migrations:
            raise RuntimeError("No versioned migrations found")
        for migration in migrations:
            db.sql(migration.read_text())
        print(f"PASS: replayed {len(migrations)} schema/migration files", flush=True)
        for test in sorted(Path(__file__).parent.glob("[0-9]*.sql")):
            result = db.sql(ASSERTIONS + "\n" + test.read_text())
            print(f"PASS: {test.name}", flush=True)
        # Optional tests that need separate connections (e.g. concurrent numbering).
        for test in sorted(Path(__file__).parent.glob("[0-9]*.py")):
            import runpy
            runpy.run_path(str(test))["test"](db)
            print(f"PASS: {test.name}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.SubprocessError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
