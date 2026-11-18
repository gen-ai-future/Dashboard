-- PostgreSQL 14+. Install as a dedicated schema owner in the chosen private database.
begin;
create schema dashboard;
revoke all on schema dashboard from public;
set local search_path = dashboard, pg_catalog;

create table principals (
  login_role name primary key,
  owner_id uuid not null
);

create table projects (
  id text primary key,
  name text not null,
  active boolean not null default true
);
insert into projects (id, name) values ('personal', '私人'), ('project-q', 'Project Q');

create table tasks (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null,
  project_id text not null references projects,
  title text not null check (btrim(title) <> ''),
  status text not null default 'open' check (status in ('open', 'completed')),
  due_date date,
  due_at timestamptz,
  priority text check (priority in ('low', 'normal', 'high')),
  notes text,
  completed_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  version integer not null default 1,
  check (num_nonnulls(due_date, due_at) <= 1),
  check ((status = 'completed') = (completed_at is not null))
);
create index tasks_owner_idx on tasks(owner_id);

create table write_requests (
  owner_id uuid not null,
  request_id uuid not null,
  action text not null,
  fingerprint jsonb not null,
  result_id uuid references tasks,
  result_version integer,
  receipt jsonb,
  created_at timestamptz not null default clock_timestamp(),
  processed_at timestamptz,
  primary key (owner_id, request_id)
);

create function current_owner() returns uuid
language plpgsql stable security definer set search_path = pg_catalog, dashboard, pg_temp
as $$
declare
  owner uuid;
begin
  select owner_id into owner from principals where login_role = session_user;
  if not found then
    raise exception 'Task access denied' using errcode = '42501';
  end if;
  return owner;
end
$$;

create function list_tasks() returns setof tasks
language sql stable security definer set search_path = pg_catalog, dashboard, pg_temp
as $$
  select * from tasks where owner_id = current_owner() order by created_at, id
$$;

create function get_task(p_task_id uuid) returns setof tasks
language sql stable security definer set search_path = pg_catalog, dashboard, pg_temp
as $$
  select * from tasks where owner_id = current_owner() and id = p_task_id
$$;

create function list_projects() returns setof projects
language sql stable security definer set search_path = pg_catalog, dashboard, pg_temp
as $$
  select p.* from projects p where current_owner() is not null order by id
$$;

create function request_result(p_request_id uuid) returns jsonb
language sql stable security definer set search_path = pg_catalog, dashboard, pg_temp
as $$
  select receipt from write_requests
    where owner_id = current_owner() and request_id = p_request_id
$$;

create function write_task(
  p_request_id uuid, p_action text, p_task_id uuid, p_expected_version integer, p_payload jsonb
) returns jsonb
language plpgsql security definer set search_path = pg_catalog, dashboard, pg_temp
as $$
declare
  owner uuid := current_owner();
  fingerprint_value jsonb := jsonb_build_array(p_action, p_task_id, p_expected_version, p_payload);
  previous write_requests%rowtype;
  item tasks%rowtype;
  receipt_value jsonb;
  field text;
begin
  if p_request_id is null or p_action is null or p_action not in ('create', 'update', 'set_status')
    or jsonb_typeof(p_payload) is distinct from 'object'
    or (p_action = 'create' and (p_task_id is not null or p_expected_version is not null))
    or (p_action <> 'create' and (p_task_id is null or coalesce(p_expected_version, 0) <= 0)) then
    raise exception 'Invalid task command' using errcode = '22023';
  end if;
  for field in select jsonb_object_keys(p_payload) loop
    if (p_action = 'set_status' and field <> 'status')
      or (p_action <> 'set_status' and field not in ('project_id', 'title', 'due_date', 'due_at', 'priority', 'notes'))
      or jsonb_typeof(p_payload->field) not in ('string', 'null') then
      raise exception 'Invalid task field: %', field using errcode = '22023';
    end if;
  end loop;
  if p_payload->>'due_date' is not null and p_payload->>'due_date' !~ '^\d{4}-\d{2}-\d{2}$' then
    raise exception 'Expected ISO date' using errcode = '22023';
  end if;
  if p_payload->>'due_at' is not null and p_payload->>'due_at' !~
    '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$' then
    raise exception 'Expected ISO timestamp with offset' using errcode = '22023';
  end if;

  insert into write_requests (owner_id, request_id, action, fingerprint)
    values (owner, p_request_id, p_action, fingerprint_value)
    on conflict do nothing;
  if not found then
    select * into strict previous from write_requests
      where owner_id = owner and request_id = p_request_id;
    if previous.fingerprint is distinct from fingerprint_value then
      raise exception 'Request ID already used with different contents' using errcode = 'P4091';
    end if;
    return previous.receipt;
  end if;

  if p_action = 'create' then
    insert into tasks (owner_id, project_id, title, due_date, due_at, priority, notes)
      values (owner, coalesce(p_payload->>'project_id', 'personal'), btrim(p_payload->>'title'),
        (p_payload->>'due_date')::date, (p_payload->>'due_at')::timestamptz,
        p_payload->>'priority', p_payload->>'notes')
      returning * into item;
  else
    select * into item from tasks
      where owner_id = owner and id = p_task_id for update;
    if not found then
      raise exception 'Task not found' using errcode = 'P4040';
    end if;
    if item.version <> p_expected_version then
      raise exception 'Task version changed' using errcode = 'P4092';
    end if;
    if p_action = 'set_status' then
      if coalesce(p_payload->>'status', '') not in ('open', 'completed') then
        raise exception 'Invalid target status' using errcode = '22023';
      end if;
      if item.status <> p_payload->>'status' then
        update tasks set status = p_payload->>'status',
          completed_at = case when p_payload->>'status' = 'completed' then clock_timestamp() end,
          updated_at = clock_timestamp(), version = version + 1 where id = item.id returning * into item;
      end if;
    else
      item := jsonb_populate_record(item, p_payload);
      update tasks set title = btrim(item.title), project_id = item.project_id,
        due_date = item.due_date, due_at = item.due_at, priority = item.priority, notes = item.notes,
        updated_at = clock_timestamp(), version = version + 1 where id = item.id returning * into item;
    end if;
  end if;

  receipt_value := to_jsonb(item) - 'owner_id';
  update write_requests set result_id = item.id, result_version = item.version,
    receipt = receipt_value, processed_at = clock_timestamp()
    where owner_id = owner and request_id = p_request_id;
  return receipt_value;
end
$$;

revoke all on all functions in schema dashboard from public;
commit;
