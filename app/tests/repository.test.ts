import type pg from 'pg';
import { describe, expect, it, vi } from 'vitest';
import { createTaskRepository } from '../src/tasks/repository.js';

const CREATED_AT = new Date('2026-10-24T09:00:00.000Z');
const ROW = {
  id: '6f1c2a3b-0000-4000-8000-000000000001',
  title: 'Write runbook',
  description: null,
  status: 'todo',
  created_at: CREATED_AT,
  updated_at: CREATED_AT,
};
const COLUMNS = 'id, title, description, status, created_at, updated_at';

// Stub of pg.Pool: records each query and answers with the given result.
function fakePool(result: { rows?: object[]; rowCount?: number } = {}) {
  const query = vi.fn().mockResolvedValue({ rows: [], rowCount: 0, ...result });
  return { pool: { query } as unknown as pg.Pool, query };
}

// Exact SQL, whitespace-normalised: without a real database this is what catches a dropped WHERE.
const sentQuery = (query: ReturnType<typeof vi.fn>) => {
  const [sql, params] = query.mock.calls[0] as [string, unknown[]];
  return { sql: sql.replace(/\s+/g, ' ').trim(), params };
};

describe('task repository', () => {
  it('create inserts with NULL defaults and maps the returned row', async () => {
    const { pool, query } = fakePool({ rows: [ROW] });

    const task = await createTaskRepository(pool).create({ title: 'Write runbook' });

    expect(sentQuery(query)).toEqual({
      sql: `INSERT INTO tasks (title, description, status) VALUES ($1, $2, COALESCE($3, 'todo')) RETURNING ${COLUMNS}`,
      params: ['Write runbook', null, null],
    });
    expect(task).toEqual({
      id: ROW.id,
      title: 'Write runbook',
      description: null,
      status: 'todo',
      createdAt: '2026-10-24T09:00:00.000Z',
      updatedAt: '2026-10-24T09:00:00.000Z',
    });
  });

  it('create fails loudly if the INSERT returns no row', async () => {
    const { pool } = fakePool({ rows: [] });

    await expect(createTaskRepository(pool).create({ title: 'x' })).rejects.toThrow(/no row/);
  });

  it('list filters, orders deterministically and pages with parameters', async () => {
    const { pool, query } = fakePool({ rows: [ROW] });

    await createTaskRepository(pool).list({ status: 'done', limit: 5, offset: 10 });

    expect(sentQuery(query)).toEqual({
      sql: `SELECT ${COLUMNS} FROM tasks WHERE ($1::text IS NULL OR status = $1) ORDER BY created_at DESC, id DESC LIMIT $2 OFFSET $3`,
      params: ['done', 5, 10],
    });
  });

  it('list without a status filter sends NULL', async () => {
    const { pool, query } = fakePool();

    await createTaskRepository(pool).list({ limit: 20, offset: 0 });

    expect(sentQuery(query).params).toEqual([null, 20, 0]);
  });

  it('get selects one task by id', async () => {
    const { pool, query } = fakePool({ rows: [ROW] });

    const task = await createTaskRepository(pool).get(ROW.id);

    expect(sentQuery(query)).toEqual({
      sql: `SELECT ${COLUMNS} FROM tasks WHERE id = $1`,
      params: [ROW.id],
    });
    expect(task?.id).toBe(ROW.id);
  });

  it('get returns undefined when no row matches', async () => {
    const { pool } = fakePool({ rows: [] });

    expect(await createTaskRepository(pool).get(ROW.id)).toBeUndefined();
  });

  it('update targets one id and sets only the fields sent, numbered after the id', async () => {
    const { pool, query } = fakePool({ rows: [ROW] });

    await createTaskRepository(pool).update(ROW.id, { status: 'done', description: null });

    expect(sentQuery(query)).toEqual({
      sql: `UPDATE tasks SET status = $2, description = $3, updated_at = now() WHERE id = $1 RETURNING ${COLUMNS}`,
      params: [ROW.id, 'done', null],
    });
  });

  it('update never puts an unknown key into the SQL text', async () => {
    const { pool, query } = fakePool({ rows: [ROW] });
    const injected = { status: 'done', 'id = id; DROP TABLE tasks; --': 'x' };

    await createTaskRepository(pool).update(ROW.id, injected as { status: 'done' });

    expect(sentQuery(query)).toEqual({
      sql: `UPDATE tasks SET status = $2, updated_at = now() WHERE id = $1 RETURNING ${COLUMNS}`,
      params: [ROW.id, 'done'],
    });
  });

  it('update returns undefined when the task does not exist', async () => {
    const { pool } = fakePool({ rows: [] });

    expect(await createTaskRepository(pool).update(ROW.id, { title: 'x' })).toBeUndefined();
  });

  it('remove deletes one task by id', async () => {
    const { pool, query } = fakePool({ rowCount: 1 });

    await createTaskRepository(pool).remove(ROW.id);

    expect(sentQuery(query)).toEqual({ sql: 'DELETE FROM tasks WHERE id = $1', params: [ROW.id] });
  });

  it.each([
    [1, true],
    [0, false],
  ])('remove with rowCount %i returns %s', async (rowCount, expected) => {
    const { pool } = fakePool({ rowCount });

    expect(await createTaskRepository(pool).remove(ROW.id)).toBe(expected);
  });
});
