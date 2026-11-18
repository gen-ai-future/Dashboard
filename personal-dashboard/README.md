# Personal Dashboard

This directory contains a staged PostgreSQL backend for the private ToolJet MVP. It is only the fallback if the existing private store and ToolJet Database cannot meet the requirements. The ToolJet app, production database and live conversation integration require deployment and verification.

## Install and serve

1. In the intended ToolJet Cloud workspace check the existing app, subscription, supported Google sign-in, server-side query authorization, and administrator access. Use a private app accessible only to the verified Ryan account. Keep synthetic tests in a separate app and database.
2. If PostgreSQL is selected, apply `tasks.sql` as a dedicated schema owner in an empty target database. Provision separate, non-owner logins for ToolJet server-side queries and the scoped Codex runtime. Map each login to the same private owner UUID in `dashboard.principals`. Restrict network access and use encrypted connections. Use the real database login for each identity because the mapping uses PostgreSQL `session_user`.
3. Grant the runtime logins only `USAGE` on schema `dashboard` and `EXECUTE` on the functions below. Store credentials server-side. Verify that workspace authorization is enforced on each ToolJet query request and that no other role can execute that query or use the data source. Keep generic database execution out of the assistant tool interface.
4. Bind these parameterized queries through ToolJet and the authorized Codex tool. A replay returns the original receipt, while `get_task` returns the current task version. Keep the submitted command, including its resolved due date, for retries.

| Operation | Parameterized SQL |
| --- | --- |
| List projects | `select * from dashboard.list_projects()` |
| List tasks | `select * from dashboard.list_tasks()` |
| Read task | `select * from dashboard.get_task($1::uuid)` |
| Write task | `select dashboard.write_task($1::uuid, $2::text, $3::uuid, $4::integer, $5::jsonb)` |
| Recover receipt | `select dashboard.request_result($1::uuid)` |

Writes use `create`, `update` or `set_status`. For creation leave task ID and expected version null. For updates send the observed version and changed fields. Date-only and timed due dates are mutually exclusive. When switching between them, explicitly clear the old field in the same update. Status changes use `{"status":"completed"}` or `{"status":"open"}`. An unknown write outcome requires a receipt lookup before retrying the identical command. Use the operation ID from the first submission across delivery retries. Read back by task ID before confirming success. Report `P4091` as a request ID conflict and `P4092` as a version conflict, then refresh the task. Use the default READ COMMITTED transaction isolation for concurrent replay.

## Build and verify

Bind native ToolJet pages 今日 and 待辦 to the queries. Put 新增待辦 above the lists on mobile. Use the classification logic in `dates.mjs` for Hong Kong dates, and render time using 24-hour Hong Kong formatting. Preserve newer confirmed versions when reads arrive out of order. Refresh on page load, sign-in, user refresh, successful write and Hong Kong midnight. Keep pending, error and empty states distinct.

Run `node --test --test-isolation=none personal-dashboard/tests/dates.test.mjs`. In an isolated PostgreSQL database, run `psql -X -v ON_ERROR_STOP=1 -f personal-dashboard/tasks.sql -f personal-dashboard/tests/tasks.sql`. For the concurrent and multi-identity tests, use a fresh local cluster with an empty database named `dashboard_mvp_test`. Set `PGHOST`, `PGPORT`, `PGUSER`, and `PGDATABASE`, then run `python personal-dashboard/tests/postgres_connections.py` with libpq available. This suite installs the schema and creates synthetic test roles and data in that disposable cluster. Verify data-request access with the real signed-in, signed-out and unauthorized identities. Record 390/768/1024px viewport results separately from real iPad and phone results.

The release gate is the real Codex 「今日還書」 command, backend readback, completion by Ryan on iPad, the matching completed record on phone, replay with unchanged completion, and persistence after signing out and back in. Keep the GitHub definition free of credentials, endpoint configuration and real data. Store private backups separately and verify app restoration and data restoration independently before handoff.
