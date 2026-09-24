"""Issuance and editing must serialize in both lock acquisition orders."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import time


def test(db):
    # Reuse the SQL role/record fixture, without its rollback transaction.
    fixture = Path(__file__).with_name("041_access.sql").read_text().split("select pg_temp.assert", 1)[0]
    fixture = fixture.replace("begin;", "", 1).replace(", true);", ", false);")
    db.sql(fixture)
    target = "worksheet_id in (select id from public.analysis_worksheets where sample_id='41000000-0000-0000-0000-000000000030')"
    db.sql("update public.analysis_results set result_value='1.5', uncertainty=0.01, analyst_reference='12345', analyzed_at=current_date, analyst_name='AAA', released_by='BBB' where " + target)
    login = "set role authenticated; select set_config('request.jwt.claim.sub','41000000-0000-0000-0000-000000000002',false);"

    def wait_for_sleep(marker):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            active = db.sql("select exists(select 1 from pg_stat_activity where pid<>pg_backend_pid() and wait_event='PgSleep' and query like '%" + marker + "%');").stdout.strip()
            if active == "t":
                return
            time.sleep(0.05)
        raise AssertionError("transaction never acquired its lock: " + marker)

    with ThreadPoolExecutor(max_workers=1) as pool:
        # Writer holds the order lock and invalidates a required value. Issuer must
        # wait and validate the committed change, rather than its earlier snapshot.
        writer = pool.submit(db.sql, login + "begin; update public.analysis_results set result_value='' where " + target + "; select pg_sleep(2) /* writer_holds_order */; commit;")
        wait_for_sleep("writer_holds_order")
        issue = db.sql(login + "select public.issue_report('41000000-0000-0000-0000-000000000020','9999');", check=False)
        writer.result()
        assert issue.returncode != 0 and "incompleta" in issue.stderr, issue.stderr
        assert db.sql("select count(*) from public.reports where order_id='41000000-0000-0000-0000-000000000020';").stdout.strip() == "0"

        db.sql(login + "update public.analysis_results set result_value='1.5' where " + target)
        issuer = pool.submit(db.sql, login + "begin; select public.issue_report('41000000-0000-0000-0000-000000000020','9999'); select pg_sleep(2) /* issuer_holds_order */; commit;")
        wait_for_sleep("issuer_holds_order")
        edit = db.sql(login + "update public.analysis_results set result_value='99' where " + target, check=False)
        issuer.result()
        assert edit.returncode != 0 and "exportada" in edit.stderr, edit.stderr
        assert db.sql("select result_value from public.analysis_results where " + target).stdout.strip() == "1.5"

    # Fixture cleanup is privileged and local to this disposable test database.
    # Production cannot disable this trigger through application roles.
    db.sql("""
      begin;
      alter table public.analysis_orders disable trigger analysis_orders_protect_workflow;
      delete from public.reports where order_id::text like '41000000%';
      delete from public.analysis_orders where id::text like '41000000%';
      alter table public.analysis_orders enable trigger analysis_orders_protect_workflow;
      delete from public.audit_events where actor_id::text like '41000000%';
      delete from public.package_parameters where package_id::text like '41000000%';
      delete from public.analysis_packages where id::text like '41000000%';
      delete from public.parameters where id::text like '41000000%';
      delete from public.clients where id::text like '41000000%';
      delete from auth.users where id::text like '41000000%';
      commit;
    """)
