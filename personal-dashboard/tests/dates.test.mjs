import test from 'node:test';
import assert from 'node:assert/strict';

const dates = () => import('../dates.mjs');

test('香港午夜過後，新請求用新日期，原請求保留原日期', async () => {
  const { createTaskRequest } = await dates();
  const timestamp = new Date('2026-11-18T15:59:00Z');
  const request = createTaskRequest('request-1', '還書', '今日', timestamp);
  const nextDay = new Date('2026-11-18T16:00:00Z');
  assert.equal(createTaskRequest('request-2', '還書', '今日', nextDay).due_date, '2026-11-19');
  assert.deepEqual(JSON.parse(JSON.stringify(request)), {
    request_id: 'request-1', title: '還書', project_id: 'personal', due_date: '2026-11-18',
  });
});

test('日期及時間按香港規則分類', async () => {
  const { taskBucket } = await dates();
  const now = new Date('2026-11-18T15:59:00Z');
  assert.equal(taskBucket({}, now), 'unscheduled');
  assert.equal(taskBucket({ due_date: '2026-11-18' }, now), 'today');
  assert.equal(taskBucket({ due_date: '2026-11-17' }, now), 'overdue');
  assert.equal(taskBucket({ due_at: '2026-11-18T15:58:00Z' }, now), 'overdue');
  assert.equal(taskBucket({ due_at: '2026-11-18T16:00:00Z' }, now), 'later');
  assert.equal(taskBucket({ status: 'completed', due_date: '2026-11-17' }, now), 'completed');
  assert.equal(taskBucket({ due_date: '2026-11-18' }, new Date('2026-11-18T16:00:00Z')), 'overdue');
});
