"""Replay 042 over representative legacy rows, including a mismatched draft."""
from pathlib import Path
import runpy


def test(_db):
    harness = runpy.run_path(str(Path(__file__).with_name('run.py')))
    app = harness['APP']
    with harness['Database']() as db:
        db.sql(harness['BOOTSTRAP'])
        for migration in [app / 'supabase/schema.sql', *sorted((app / 'supabase').glob('[0-9]*.sql'))]:
            if migration.name.startswith('042_'):
                break
            db.sql(migration.read_text())
        db.sql("""
          insert into auth.users(id) values('42000000-0000-0000-0000-000000000001');
          update public.profiles set role='recepcion' where id='42000000-0000-0000-0000-000000000001';
          insert into public.clients(id,name) values('42000000-0000-0000-0000-000000000002','Legacy client');
          insert into public.parameters(id,name) values('42000000-0000-0000-0000-000000000005','Legacy parameter');
          insert into public.analysis_orders(id,op_number,client_id,received_at,due_date) values
            ('42000000-0000-0000-0000-000000000010','28303097','42000000-0000-0000-0000-000000000002','2083-03-03','2083-03-04'),
            ('42000000-0000-0000-0000-000000000011','28301002','42000000-0000-0000-0000-000000000002','2083-01-01','2083-01-02');
          insert into public.samples(id,order_id,sample_code) values
            ('42000000-0000-0000-0000-000000000020','42000000-0000-0000-0000-000000000010','830303-0500');
          insert into public.report_drafts(id,order_id,sample_id) values
            ('42000000-0000-0000-0000-000000000030','42000000-0000-0000-0000-000000000011','42000000-0000-0000-0000-000000000020');
          insert into public.reports(order_id,report_number,report_year) values('42000000-0000-0000-0000-000000000010','0600',2083);
        """)
        sql = (app / 'supabase/042_references_and_numbering.sql').read_text()
        failure = db.sql(sql, check=False)
        assert failure.returncode != 0 and '42000000-0000-0000-0000-000000000030' in failure.stderr, failure.stderr
        assert db.sql("select to_regclass('public.document_counters') is null;").stdout.strip() == 't', 'failed migration partially applied'
        db.sql("update public.report_drafts set order_id='42000000-0000-0000-0000-000000000010';")
        db.sql(sql)
        assert db.sql("select document_type||':'||last_number from public.document_counters where document_year=2083 order by document_type;").stdout.strip().splitlines() == ['order:97','report:600','sample:500']
        db.sql("delete from public.reports; delete from public.analysis_orders;")
        created = db.sql("""
          set role authenticated;
          select set_config('request.jwt.claim.sub','42000000-0000-0000-0000-000000000001',false);
          select (public.create_sample_entry_batch_auto_for_client('42000000-0000-0000-0000-000000000002','[{"parameter_ids":["42000000-0000-0000-0000-000000000005"]}]',false,null,'2083-04-01')).op_number;
        """).stdout.strip().splitlines()[-1]
        assert created == '28304098', created
        assert db.sql('select sample_code from public.samples;').stdout.strip() == '830401-0501'
        assert db.sql("select public.next_document_number('report',2083);").stdout.strip() == '601'
