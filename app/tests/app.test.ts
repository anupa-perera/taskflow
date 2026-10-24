import type { FastifyInstance } from 'fastify';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { ProblemDetails } from '../src/errors.js';
import { HTTP_STATUS } from '../src/http-status.js';
import type { TaskRepository } from '../src/tasks/repository.js';
import { buildTestApp } from './helpers/build-test-app.js';
import { createInMemoryTaskRepository } from './helpers/in-memory-task-repository.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

describe('app', () => {
  let app: FastifyInstance;

  beforeEach(async () => {
    app = await buildTestApp();
  });

  afterEach(async () => {
    await app.close();
  });

  it('answers the liveness probe', async () => {
    const response = await app.inject({ method: 'GET', url: '/health' });

    expect(response.statusCode).toBe(HTTP_STATUS.OK);
    expect(response.json()).toEqual({ status: 'ok' });
  });

  it('sends a UUID request id on every response', async () => {
    const response = await app.inject({ method: 'GET', url: '/health' });

    expect(response.headers['x-request-id']).toMatch(UUID);
  });

  it('echoes a caller-supplied request id', async () => {
    const response = await app.inject({
      method: 'GET',
      url: '/health',
      headers: { 'x-request-id': 'trace-123' },
    });

    expect(response.headers['x-request-id']).toBe('trace-123');
  });

  it('returns problem+json 404 for an unknown route', async () => {
    const response = await app.inject({ method: 'GET', url: '/nope' });

    expect(response.statusCode).toBe(HTTP_STATUS.NOT_FOUND);
    expect(response.headers['content-type']).toContain('application/problem+json');
    expect(response.json<ProblemDetails>().detail).toBe('Route GET /nope not found');
  });

  it('returns problem+json 400 with a request id for a malformed URL', async () => {
    const response = await app.inject({ method: 'GET', url: '/tasks/%ZZ' });

    expect(response.statusCode).toBe(HTTP_STATUS.BAD_REQUEST);
    expect(response.headers['content-type']).toContain('application/problem+json');
    expect(response.headers['x-request-id']).toMatch(UUID);
  });

  it('rejects bodies over the size limit', async () => {
    const response = await app.inject({
      method: 'POST',
      url: '/tasks',
      headers: { 'content-type': 'application/json' },
      payload: JSON.stringify({ title: 'a'.repeat(100_000) }),
    });

    expect(response.statusCode).toBe(HTTP_STATUS.PAYLOAD_TOO_LARGE);
  });

  it('serves the OpenAPI document with problem+json error responses', async () => {
    const response = await app.inject({ method: 'GET', url: '/docs/json' });
    const spec = response.json<{
      paths: Record<string, Record<string, { responses: Record<string, { content?: object }> }>>;
    }>();

    expect(response.statusCode).toBe(HTTP_STATUS.OK);
    expect(Object.keys(spec.paths)).toEqual(expect.arrayContaining(['/tasks', '/tasks/{id}']));
    expect(spec.paths['/tasks']?.post?.responses['400']?.content).toHaveProperty(
      'application/problem+json',
    );
  });
});

describe('unexpected errors', () => {
  it('hide internal details behind a generic 500', async () => {
    const failing: TaskRepository = {
      ...createInMemoryTaskRepository(),
      list: () => Promise.reject(new Error('connect ECONNREFUSED 10.0.3.17:5432')),
    };
    const app = await buildTestApp(failing);

    const response = await app.inject({ method: 'GET', url: '/tasks' });
    const problem = response.json<ProblemDetails>();
    await app.close();

    expect(response.statusCode).toBe(HTTP_STATUS.INTERNAL_SERVER_ERROR);
    expect(problem.detail).not.toContain('10.0.3.17');
    expect(problem.detail).toContain('request id');
  });
});
