const hongKongFormatter = new Intl.DateTimeFormat('en-CA', {
  timeZone: 'Asia/Hong_Kong',
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
});

export function hongKongDate(instant) {
  return hongKongFormatter.format(instant);
}

export function createTaskRequest(requestId, title, relativeDate, firstSeenAt) {
  const request = { request_id: requestId, title: title.trim(), project_id: 'personal' };
  if (relativeDate === '今日') {
    request.due_date = hongKongDate(firstSeenAt);
  } else if (relativeDate === '聽日' || relativeDate === '聽晚') {
    // Hong Kong uses UTC+08:00 year-round for current scheduling.
    request.due_date = hongKongDate(new Date(firstSeenAt.getTime() + 86_400_000));
  } else if (relativeDate != null) {
    throw new RangeError('未能辨認到期日期');
  }
  return Object.freeze(request);
}

export function taskBucket(task, now) {
  if (task.status === 'completed') return 'completed';
  if (!task.due_at && !task.due_date) return 'unscheduled';
  const today = hongKongDate(now);
  if (task.due_at && new Date(task.due_at) < now) return 'overdue';
  const dueDate = task.due_at ? hongKongDate(new Date(task.due_at)) : task.due_date;
  if (dueDate < today) return 'overdue';
  return dueDate === today ? 'today' : 'later';
}
