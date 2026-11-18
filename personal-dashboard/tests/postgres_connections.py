import ctypes as c
import concurrent.futures
import os
from pathlib import Path

pq = c.CDLL('libpq.so.5')
for name, result, args in [
    ('PQconnectdb', c.c_void_p, [c.c_char_p]),
    ('PQexec', c.c_void_p, [c.c_void_p, c.c_char_p]),
    ('PQresultStatus', c.c_int, [c.c_void_p]),
    ('PQresultErrorField', c.c_char_p, [c.c_void_p, c.c_int]),
    ('PQgetvalue', c.c_char_p, [c.c_void_p, c.c_int, c.c_int]),
    ('PQclear', None, [c.c_void_p]),
    ('PQfinish', None, [c.c_void_p]),
]:
    method = getattr(pq, name)
    method.restype = result
    method.argtypes = args

def sql(query, user=None, expected=''):
    conn = pq.PQconnectdb(f'user={user}'.encode() if user else b'')
    res = pq.PQexec(conn, query.encode())
    try:
        code = pq.PQresultErrorField(res, ord('C'))
        if expected:
            assert code == expected.encode(), (expected, code)
        else:
            assert pq.PQresultStatus(res) in (1, 2), (code, pq.PQresultErrorField(res, ord('M')))
            if pq.PQresultStatus(res) == 2:
                return pq.PQgetvalue(res, 0, 0).decode()
    finally:
        pq.PQclear(res)
        pq.PQfinish(conn)

# This suite creates persistent test-only roles and rows. Use a fresh local cluster.
if os.environ.get('PGDATABASE') != 'dashboard_mvp_test':
    raise SystemExit('Use a disposable cluster and set PGDATABASE=dashboard_mvp_test')
root = Path(__file__).resolve().parents[1]
sql(root.joinpath('tasks.sql').read_text())
sql('\n'.join(line for line in root.joinpath('tests/tasks.sql').read_text().splitlines() if not line.startswith(chr(92))))
print('PASS: SQL fixture and rollback')
sql("""
create role test_tooljet login;
create role test_codex login;
create role test_other login;
create role test_unauthorized login;
insert into dashboard.principals values
  ('test_tooljet', '00000000-0000-4000-8000-000000000010'),
  ('test_codex', '00000000-0000-4000-8000-000000000010'),
  ('test_other', '00000000-0000-4000-8000-000000000011');
grant usage on schema dashboard to test_tooljet, test_codex, test_other, test_unauthorized;
grant execute on function dashboard.write_task(uuid,text,uuid,integer,jsonb),
  dashboard.request_result(uuid), dashboard.list_tasks(), dashboard.get_task(uuid)
  to test_tooljet, test_codex, test_other, test_unauthorized;
""")
req = '00000000-0000-4000-8000-000000000020'
query = f"""select dashboard.write_task('{req}', 'create', null, null, '{{"title":"測試還書"}}')->>'id'"""
with concurrent.futures.ThreadPoolExecutor(8) as executor:
    ids = list(executor.map(lambda _: sql(query, 'test_codex'), range(8)))
assert len(set(ids)) == 1 and ids[0]
assert sql('select count(*) from dashboard.list_tasks()', 'test_tooljet') == '1'
lost_response_request = '00000000-0000-4000-8000-000000000021'
sql(query.replace(req, lost_response_request), 'test_codex')  # Discard the committed response.
recovered_id = sql(f"select dashboard.request_result('{lost_response_request}')->>'id'", 'test_codex')
assert recovered_id and recovered_id != ids[0]
assert sql(query.replace(req, lost_response_request), 'test_codex') == recovered_id
assert sql('select count(*) from dashboard.list_tasks()', 'test_tooljet') == '2'
assert sql('select count(*) from dashboard.list_tasks()', 'test_other') == '0'
sql('select count(*) from dashboard.list_tasks()', 'test_unauthorized', expected='42501')
sql('select * from dashboard.tasks', 'test_codex', expected='42501')
print('PASS: 8 concurrent replies, one record, fresh-connection receipt lookup, cross-identity authorization and direct table denial')
