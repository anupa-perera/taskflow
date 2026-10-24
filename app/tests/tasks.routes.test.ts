import type { FastifyInstance } from 'fastify';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { ProblemDetails } from '../src/errors.js';
import { HTTP_STATUS } from '../src/http-status.js';
import type { Task } from '../src/tasks/types.js';
import { buildTestApp } from './helpers/build-test-app.js';
import { createInMemoryTaskRepository } from './helpers/in-memory-task-repository.js';

const JSON_HEADERS = { 'content-type': 'application/json' };
const UNKNOWN_ID = '00000000-0000-4000-8000-000000000000';

describe('task routes', () => {
  let app: FastifyInstance;

  beforeEach(async () => {
    app = await buildTestApp();
  });

  afterEach(async () => {
    await app.close();
  });

  const createTask = async (body: object) => {
    const response = await app.inject({
      method: 'POST',
      url: '/tasks',
      headers: JSON_HEADERS,
      payload: body,
    });
    return { response, task: response.json<Task>() };
  };

  describe('POST /tasks', () => {
    it('creates a task with defaults and a Location header', async () => {
      const { response, task } = await createTask({ title: 'Write runbook' });

      expect(response.statusCode).toBe(HTTP_STATUS.CREATED);
      expect(response.headers.location).toBe(`/tasks/${task.id}`);
      expect(task).toMatchObject({ title: 'Write runbook', description: null, status: 'todo' });
    });

    it('keeps an empty description as an empty string, not null', async () => {
      const { task } = await createTask({ title: 'x', description: '' });

      expect(task.description).toBe('');
    });

    it.each([
      ['missing title', {}, 'body.title'],
      ['blank title', { title: '   ' }, 'body.title'],
      ['title over 200 characters', { title: 'a'.repeat(201) }, 'body.title'],
      ['NUL character in description', { title: 'x', description: 'a\u0000b' }, 'body.description'],
      ['number as description', { title: 'x', description: 0 }, 'body.description'],
      ['unknown status', { title: 'x', status: 'archived' }, 'body.status'],
      ['unknown field', { title: 'x', colour: 'red' }, 'body.colour'],
    ])('rejects %s with a problem+json 400', async (_case, body, field) => {
      const { response } = await createTask(body);
      const problem = response.json<ProblemDetails>();

      expect(response.statusCode).toBe(HTTP_STATUS.BAD_REQUEST);
      expect(response.headers['content-type']).toContain('application/problem+json');
      expect(problem.errors?.map((error) => error.field)).toContain(field);
    });

    it('rejects malformed JSON', async () => {
      const response = await app.inject({
        method: 'POST',
        url: '/tasks',
        headers: JSON_HEADERS,
        payload: '{"title":',
      });

      expect(response.statusCode).toBe(HTTP_STATUS.BAD_REQUEST);
      expect(response.json<ProblemDetails>().title).toBe('Bad Request');
    });
  });

  describe('GET /tasks', () => {
    // B and C share a timestamp, so their order comes from the id tie-breaker.
    const seededTask = (suffix: string, createdAt: string, status: Task['status']): Task => ({
      id: `00000000-0000-4000-8000-00000000000${suffix}`,
      title: `task ${suffix}`,
      description: null,
      status,
      createdAt,
      updatedAt: createdAt,
    });
    const A = seededTask('1', '2026-10-24T09:00:00.000Z', 'done');
    const B = seededTask('2', '2026-10-24T10:00:00.000Z', 'todo');
    const C = seededTask('3', '2026-10-24T10:00:00.000Z', 'done');
    const D = seededTask('4', '2026-10-24T11:00:00.000Z', 'done');

    const listIds = async (query = '') => {
      const seeded = await buildTestApp(createInMemoryTaskRepository([A, B, C, D]));
      const response = await seeded.inject({ method: 'GET', url: `/tasks${query}` });
      await seeded.close();
      const body = response.json<{ items: Task[]; limit: number; offset: number }>();
      return { response, body, ids: body.items.map((task) => task.id) };
    };

    it('lists newest first, breaking timestamp ties by id, with default paging', async () => {
      const { response, body, ids } = await listIds();

      expect(response.statusCode).toBe(HTTP_STATUS.OK);
      expect(body).toMatchObject({ limit: 20, offset: 0 });
      expect(ids).toEqual([D.id, C.id, B.id, A.id]);
    });

    it('filters by status before paging', async () => {
      expect((await listIds('?status=done')).ids).toEqual([D.id, C.id, A.id]);
    });

    it('applies limit and offset to the filtered, ordered list', async () => {
      const { body, ids } = await listIds('?status=done&limit=1&offset=1');

      expect(body).toMatchObject({ limit: 1, offset: 1 });
      expect(ids).toEqual([C.id]);
    });

    it('filters before paging, so the offset skips only matching tasks', async () => {
      // Paging first would land on B (todo) and filter it out, returning nothing.
      expect((await listIds('?status=done&limit=1&offset=2')).ids).toEqual([A.id]);
    });

    it.each(['limit=0', 'limit=101', 'offset=-1', 'offset=10001', 'status=archived', 'page=2'])(
      'rejects %s',
      async (query) => {
        const response = await app.inject({ method: 'GET', url: `/tasks?${query}` });

        expect(response.statusCode).toBe(HTTP_STATUS.BAD_REQUEST);
      },
    );
  });

  describe('GET /tasks/:id', () => {
    it('returns an existing task', async () => {
      const { task } = await createTask({ title: 'x' });

      const response = await app.inject({ method: 'GET', url: `/tasks/${task.id}` });

      expect(response.statusCode).toBe(HTTP_STATUS.OK);
      expect(response.json<Task>()).toEqual(task);
    });

    it('returns 404 for an unknown id', async () => {
      const response = await app.inject({ method: 'GET', url: `/tasks/${UNKNOWN_ID}` });

      expect(response.statusCode).toBe(HTTP_STATUS.NOT_FOUND);
      expect(response.json<ProblemDetails>().detail).toBe(`Task ${UNKNOWN_ID} not found`);
    });

    it('returns 400 for an id that is not a UUID', async () => {
      const response = await app.inject({ method: 'GET', url: '/tasks/not-a-uuid' });

      expect(response.statusCode).toBe(HTTP_STATUS.BAD_REQUEST);
      expect(response.json<ProblemDetails>().errors?.[0]?.field).toBe('params.id');
    });
  });

  describe('PATCH /tasks/:id', () => {
    it('updates only the fields sent, and null clears the description', async () => {
      const { task } = await createTask({ title: 'x', description: 'old' });

      const response = await app.inject({
        method: 'PATCH',
        url: `/tasks/${task.id}`,
        headers: JSON_HEADERS,
        payload: { status: 'done', description: null },
      });

      expect(response.statusCode).toBe(HTTP_STATUS.OK);
      expect(response.json<Task>()).toMatchObject({
        title: 'x',
        status: 'done',
        description: null,
      });
    });

    it('rejects an empty body', async () => {
      const { task } = await createTask({ title: 'x' });

      const response = await app.inject({
        method: 'PATCH',
        url: `/tasks/${task.id}`,
        headers: JSON_HEADERS,
        payload: {},
      });

      expect(response.statusCode).toBe(HTTP_STATUS.BAD_REQUEST);
    });

    it('returns 404 for an unknown id', async () => {
      const response = await app.inject({
        method: 'PATCH',
        url: `/tasks/${UNKNOWN_ID}`,
        headers: JSON_HEADERS,
        payload: { status: 'done' },
      });

      expect(response.statusCode).toBe(HTTP_STATUS.NOT_FOUND);
    });
  });

  describe('DELETE /tasks/:id', () => {
    it('deletes a task, after which it is gone', async () => {
      const { task } = await createTask({ title: 'x' });

      const deleted = await app.inject({ method: 'DELETE', url: `/tasks/${task.id}` });
      const fetched = await app.inject({ method: 'GET', url: `/tasks/${task.id}` });

      expect(deleted.statusCode).toBe(HTTP_STATUS.NO_CONTENT);
      expect(deleted.body).toBe('');
      expect(fetched.statusCode).toBe(HTTP_STATUS.NOT_FOUND);
    });

    it('returns 404 for an unknown id', async () => {
      const response = await app.inject({ method: 'DELETE', url: `/tasks/${UNKNOWN_ID}` });

      expect(response.statusCode).toBe(HTTP_STATUS.NOT_FOUND);
    });
  });
});
