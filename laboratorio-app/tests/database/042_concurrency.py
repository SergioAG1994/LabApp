"""Concurrent batches must allocate distinct annual order and sample sequences."""
from concurrent.futures import ThreadPoolExecutor


def test(db):
    db.sql("""
      insert into auth.users(id) values('42000000-0000-0000-0000-000000000001');
      update public.profiles set role='recepcion' where id='42000000-0000-0000-0000-000000000001';
      insert into public.clients(id,name) values('42000000-0000-0000-0000-000000000002','Concurrent client');
      insert into public.parameters(id,name) values('42000000-0000-0000-0000-000000000005','Concurrent parameter');
    """)
    login = "set role authenticated; select set_config('request.jwt.claim.sub','42000000-0000-0000-0000-000000000001',false);"
    args = "'[{\"parameter_ids\":[\"42000000-0000-0000-0000-000000000005\"]},{\"parameter_ids\":[\"42000000-0000-0000-0000-000000000005\"]}]',false,null,'2087-01-01'"
    def create(i):
        if i % 2:
            rpc = "public.create_sample_entry_batch_auto((select client_number::text from public.clients where id='42000000-0000-0000-0000-000000000002'),"
        else:
            rpc = "public.create_sample_entry_batch_auto_for_client('42000000-0000-0000-0000-000000000002',"
        return db.sql(login + "select (" + rpc + args + ")).op_number;").stdout.strip().splitlines()[-1]
    with ThreadPoolExecutor(max_workers=6) as pool:
        numbers = list(pool.map(create, range(12)))
    assert set(numbers) == {f"28701{i:03d}" for i in range(1, 13)}, numbers
    samples = db.sql("select sample_code from public.samples where sample_code like '870101-%' order by sample_code;").stdout.strip().splitlines()
    assert samples == [f"870101-{i:04d}" for i in range(1, 25)], samples
    # Report allocation uses the same atomic helper, independently per year/type.
    with ThreadPoolExecutor(max_workers=6) as pool:
        reports = list(pool.map(lambda _: db.sql("select public.next_document_number('report',2087);").stdout.strip(), range(12)))
    assert {int(n) for n in reports} == set(range(1, 13)), reports
    db.sql("""
      delete from public.analysis_orders where client_id='42000000-0000-0000-0000-000000000002';
      delete from public.audit_events where actor_id='42000000-0000-0000-0000-000000000001';
      delete from public.parameters where id='42000000-0000-0000-0000-000000000005';
      delete from public.clients where id='42000000-0000-0000-0000-000000000002';
      delete from auth.users where id='42000000-0000-0000-0000-000000000001';
    """)
