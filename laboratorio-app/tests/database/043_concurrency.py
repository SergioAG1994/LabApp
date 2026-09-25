"""Concurrent full worksheet saves cannot silently overwrite an earlier save."""
from concurrent.futures import ThreadPoolExecutor
import json
import time


def test(db):
    db.sql("""
     insert into auth.users(id) values('43100000-0000-0000-0000-000000000001');
     update public.profiles set role='analista' where id='43100000-0000-0000-0000-000000000001';
     insert into public.clients(id,name) values('43100000-0000-0000-0000-000000000002','Concurrent worksheet client');
     insert into public.parameters(id,name) values('43100000-0000-0000-0000-000000000003','Concurrent result');
     insert into public.analysis_orders(id,op_number,client_id,received_at,due_date) values('43100000-0000-0000-0000-000000000004','concurrent-save','43100000-0000-0000-0000-000000000002','2088-01-01','2088-01-02');
     insert into public.samples(id,order_id,sample_code) values('43100000-0000-0000-0000-000000000005','43100000-0000-0000-0000-000000000004','concurrent-save');
     insert into public.analysis_worksheets(id,sample_id) values('43100000-0000-0000-0000-000000000006','43100000-0000-0000-0000-000000000005');
     insert into public.analysis_results(id,worksheet_id,parameter_id) values('43100000-0000-0000-0000-000000000007','43100000-0000-0000-0000-000000000006','43100000-0000-0000-0000-000000000003');
    """)
    revision = int(db.sql("select revision from public.analysis_worksheets where id='43100000-0000-0000-0000-000000000006';").stdout.strip())
    login = "set role authenticated;select set_config('request.jwt.claim.sub','43100000-0000-0000-0000-000000000001',false);"
    def save(value):
        rows = json.dumps([{'id':'43100000-0000-0000-0000-000000000007','result_value':value}])
        return f"select public.save_analysis_worksheet('43100000-0000-0000-0000-000000000005',{revision},'{rows}');"
    with ThreadPoolExecutor(max_workers=1) as pool:
        first = pool.submit(db.sql, login + 'begin;' + save('first') + 'select pg_sleep(2) /* worksheet_saved */;commit;')
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if db.sql("select exists(select 1 from pg_stat_activity where pid<>pg_backend_pid() and wait_event='PgSleep' and query like '%worksheet_saved%');").stdout.strip() == 't':
                break
            time.sleep(0.05)
        else:
            raise AssertionError('first save did not acquire its lock')
        second = db.sql(login + save('second'), check=False)
        first.result()
        assert second.returncode and 'Recarga' in second.stderr, second.stderr
    assert db.sql("select result_value from public.analysis_results where id='43100000-0000-0000-0000-000000000007';").stdout.strip() == 'first'
    assert db.sql("select count(*) from public.audit_events where entity_type='analysis_results' and after_data->>'result_value'='second';").stdout.strip() == '0'

    def wait_for_sleep(marker):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if db.sql("select exists(select 1 from pg_stat_activity where pid<>pg_backend_pid() and wait_event='PgSleep' and query like '%" + marker + "%');").stdout.strip() == 't':
                return
            time.sleep(0.05)
        raise AssertionError('expected lock holder did not start: ' + marker)

    result_id = '43100000-0000-0000-0000-000000000007'
    revision = int(db.sql("select revision from public.analysis_worksheets where id='43100000-0000-0000-0000-000000000006';").stdout.strip())
    with ThreadPoolExecutor(max_workers=1) as pool:
        # Reproduce the narrow inversion: atomic save owns the parent while an
        # old-client UPDATE owns a child row and waits on that parent in041.
        # An explicit fixture lock widens this window deterministically.
        parent = pool.submit(db.sql, "\\set VERBOSITY verbose\nbegin;select id from public.analysis_orders where id='43100000-0000-0000-0000-000000000004' for update;" + login + "select pg_sleep(2) /* parent_before_save */;" + save('must-not-save') + 'commit;', check=False)
        wait_for_sleep('parent_before_save')
        legacy = db.sql(login + "update public.analysis_results set result_value='legacy-wins' where id='" + result_id + "';")
        conflict = parent.result()
        assert conflict.returncode and '40001' in conflict.stderr and 'concurrentes' in conflict.stderr, conflict.stderr
        assert '40P01' not in conflict.stderr, conflict.stderr
    assert db.sql("select result_value from public.analysis_results where id='" + result_id + "';").stdout.strip() == 'legacy-wins'

    revision = int(db.sql("select revision from public.analysis_worksheets where id='43100000-0000-0000-0000-000000000006';").stdout.strip())
    with ThreadPoolExecutor(max_workers=1) as pool:
        # Opposite order: the old save already owns the parent. The new RPC waits,
        # then checks the committed revision and leaves the old result intact.
        legacy = pool.submit(db.sql, login + "begin;update public.analysis_results set result_value='legacy-first' where id='" + result_id + "';select pg_sleep(2) /* legacy_saved_first */;commit;")
        wait_for_sleep('legacy_saved_first')
        conflict = db.sql("\\set VERBOSITY verbose\n" + login + save('must-not-overwrite'),check=False)
        legacy.result()
        assert conflict.returncode and '40001' in conflict.stderr and 'Recarga' in conflict.stderr, conflict.stderr
    assert db.sql("select result_value from public.analysis_results where id='" + result_id + "';").stdout.strip() == 'legacy-first'
