"""Backfill known identities without guessing ambiguous historical attribution."""
from pathlib import Path
import runpy


def test(_db):
    harness = runpy.run_path(str(Path(__file__).with_name('run.py')))
    app = harness['APP']
    with harness['Database']() as db:
        db.sql(harness['BOOTSTRAP'])
        for migration in sorted((app / 'supabase/migrations').glob('[0-9]*.sql')):
            if migration.name == '20260722000045_043_staff_and_audit.sql':
                break
            db.sql(migration.read_text())
        db.sql("""
          insert into auth.users(id) values('43200000-0000-0000-0000-000000000001');
          update public.profiles set role='recepcion' where id='43200000-0000-0000-0000-000000000001';
          select set_config('request.jwt.claim.sub','43200000-0000-0000-0000-000000000001',false);
          insert into public.clients(id,name) values('43200000-0000-0000-0000-000000000002','Legacy client');
          insert into public.parameters(id,name) values('43200000-0000-0000-0000-000000000003','Legacy measurement');
          insert into public.laboratory_staff(id,full_name,initials,position_title,functions,active) values
           ('43200000-0000-0000-0000-000000000010','Retired Person','RP','Analyst',array['analista','muestreador'],false),
           ('43200000-0000-0000-0000-000000000011','Shared Name','SN1','Reviewer',array['revisor'],true),
           ('43200000-0000-0000-0000-000000000012','Shared Name','SN2','Reviewer',array['revisor'],true);
          select public.create_sample_entry_batch_auto_for_client('43200000-0000-0000-0000-000000000002','[{"parameter_ids":["43200000-0000-0000-0000-000000000003"]}]',true,'LEGACY','2088-01-01',p_sampler_name=>' Retired Person ');
          update public.analysis_results set result_value='1',uncertainty=0.1,analyst_reference='12345',analyzed_at=current_date,analyst_name=' rp ',released_by='Shared Name';
          select public.issue_report((select id from public.analysis_orders where op_number='28801001'),'0043');
        """)
        audit_before = db.sql('select count(*) from public.audit_events;').stdout.strip()
        db.sql((app / 'supabase/migrations/20260722000045_043_staff_and_audit.sql').read_text())
        assert db.sql('select count(*) from public.audit_events;').stdout.strip() == audit_before, 'backfill polluted activity history'
        assert db.sql("select analyst_staff_id::text||':'||(released_by_staff_id is null)::text||':'||analyst_name||':'||released_by from public.analysis_results;").stdout.strip() == '43200000-0000-0000-0000-000000000010:true: rp :Shared Name'
        assert db.sql("select sampler_staff_id::text||':'||sampler_name||':'||status from public.analysis_orders;").stdout.strip() == '43200000-0000-0000-0000-000000000010:Retired Person:informe_emitido'
        assert db.sql("select count(*) from pg_trigger where tgname in ('analysis_results_lock_exported_worksheet','analysis_orders_protect_workflow') and tgenabled='O';").stdout.strip() == '2'
        failure = db.sql("set role authenticated;select set_config('request.jwt.claim.sub','43200000-0000-0000-0000-000000000001',false);update public.analysis_results set result_value='2';",check=False)
        assert failure.returncode and 'exportada' in failure.stderr, failure.stderr
