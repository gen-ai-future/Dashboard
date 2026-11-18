\set ON_ERROR_STOP on
-- Run as a disposable database's schema owner, immediately after migration.
begin;
insert into dashboard.principals values (session_user, '00000000-0000-4000-8000-000000000010');
do $$
declare
  request uuid := gen_random_uuid();
  other_request uuid := gen_random_uuid();
  created jsonb;
  completed jsonb;
  independent jsonb;
  payload jsonb := '{"title":"測試還書","due_date":"2026-11-18"}';
begin
  created := dashboard.write_task(request, 'create', null, null, payload);
  if created->>'due_date' is distinct from '2026-11-18' or created->>'due_at' is not null then
    raise exception 'date-only task changed meaning';
  end if;
  if dashboard.request_result(request) is distinct from created then
    raise exception 'receipt lookup failed';
  end if;
  completed := dashboard.write_task(gen_random_uuid(), 'set_status', (created->>'id')::uuid, 1,
    '{"status":"completed"}');
  if (completed->>'version')::integer is distinct from 2 or completed->>'completed_at' is null then
    raise exception 'completion was not stored';
  end if;
  if dashboard.write_task(request, 'create', null, null, payload) is distinct from created
    or (select status from dashboard.list_tasks() where id = (created->>'id')::uuid)
      is distinct from 'completed' then
    raise exception 'replay changed the original task';
  end if;
  begin
    perform dashboard.write_task(request, 'create', null, null, '{"title":"different"}');
    raise exception 'replay with different contents accepted';
  exception when sqlstate 'P4091' then null;
  end;
  begin
    perform dashboard.write_task(gen_random_uuid(), 'update', (created->>'id')::uuid, 1, '{"title":"stale"}');
    raise exception 'stale write accepted';
  exception when sqlstate 'P4092' then null;
  end;
  independent := dashboard.write_task(other_request, 'create', null, null, payload);
  if independent->>'id' = created->>'id'
    or (select count(*) from dashboard.list_tasks()) <> 2 then
    raise exception 'independent same-title creation was merged';
  end if;
  if dashboard.write_task(gen_random_uuid(), 'set_status', (created->>'id')::uuid, 2,
    '{"status":"open"}')->>'completed_at' is not null then
    raise exception 'reopening retained completion time';
  end if;
end
$$;
rollback;
