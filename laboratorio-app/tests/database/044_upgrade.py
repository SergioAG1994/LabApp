"""Conservative measurement backfill preserves raw historical/issued data and history."""
from pathlib import Path
import runpy


def test(_db):
    harness = runpy.run_path(str(Path(__file__).with_name('run.py')))
    app = harness['APP']
    with harness['Database']() as db:
        db.sql(harness['BOOTSTRAP'])
        for migration in [app / 'supabase/schema.sql', *sorted((app / 'supabase').glob('[0-9]*.sql'))]:
            if migration.name.startswith('044_'):
                break
            db.sql(migration.read_text())
        db.sql("""
          insert into auth.users(id) values('44200000-0000-0000-0000-000000000001');
          update public.profiles set role='recepcion' where id='44200000-0000-0000-0000-000000000001';
          select set_config('request.jwt.claim.sub','44200000-0000-0000-0000-000000000001',false);
          insert into public.clients(id,name) values('44200000-0000-0000-0000-000000000002','Legacy measurements');
          insert into public.parameters(id,name) values('44200000-0000-0000-0000-000000000003','Precise measurement'),('44200000-0000-0000-0000-000000000004','Ambiguous measurement');
          select public.create_sample_entry_batch_auto_for_client('44200000-0000-0000-0000-000000000002','[{"parameter_ids":["44200000-0000-0000-0000-000000000003","44200000-0000-0000-0000-000000000004"]}]',false,null,'2090-01-01');
          update public.analysis_results set result_value=case parameter_id when '44200000-0000-0000-0000-000000000003' then '  <9007199254740993.123456789123456789  ' else '1,234' end,uncertainty=.1,analyst_reference='12345',analyzed_at=current_date,analyst_name='Unknown',released_by='Unknown';
          select public.issue_report((select id from public.analysis_orders where op_number='29001001'),'0044');
        """)
        # Compare every original result column, not just reported text; separately
        # check worksheet revisions, report contents, and complete audit history.
        results_before = db.sql('select jsonb_agg(to_jsonb(r) order by id) from public.analysis_results r;').stdout
        history_before = db.sql('select jsonb_agg(to_jsonb(a) order by id) from public.audit_events a;').stdout
        worksheets_before = db.sql('select jsonb_agg(to_jsonb(w) order by id) from public.analysis_worksheets w;').stdout
        reports_before = db.sql('select jsonb_agg(to_jsonb(r) order by id) from public.reports r;').stdout
        db.sql((app / 'supabase/044_structured_results.sql').read_text())
        assert db.sql("select jsonb_agg(to_jsonb(r)-array['result_input_kind','result_type','result_numeric','result_qualifier','result_text'] order by id) from public.analysis_results r;").stdout == results_before, 'backfill modified historical columns'
        assert db.sql('select jsonb_agg(to_jsonb(a) order by id) from public.audit_events a;').stdout == history_before, 'backfill polluted activity history'
        assert db.sql('select jsonb_agg(to_jsonb(w) order by id) from public.analysis_worksheets w;').stdout == worksheets_before, 'backfill changed worksheet revisions/timestamps'
        assert db.sql('select jsonb_agg(to_jsonb(r) order by id) from public.reports r;').stdout == reports_before, 'backfill changed issued reports'
        assert db.sql("select result_input_kind||':'||result_type||':'||result_numeric||':'||result_qualifier from public.analysis_results where parameter_id='44200000-0000-0000-0000-000000000003';").stdout.strip() == 'auto:number:9007199254740993.123456789123456789:lt'
        assert db.sql("select result_type||':'||result_text from public.analysis_results where parameter_id='44200000-0000-0000-0000-000000000004';").stdout.strip() == 'text:1,234'
        assert db.sql("select count(*) from pg_trigger where tgrelid='public.analysis_results'::regclass and tgname in ('analysis_results_lock_exported_worksheet','results_credited_staff','results_advance_revision','record_change','results_derive_value') and tgenabled='O';").stdout.strip() == '5'
        failure = db.sql("set role authenticated;select set_config('request.jwt.claim.sub','44200000-0000-0000-0000-000000000001',false);update public.analysis_results set result_input_kind='text';",check=False)
        assert failure.returncode and 'exportada' in failure.stderr, failure.stderr
