import type { FastifyInstance } from 'fastify';
import { buildApp } from '../../src/app.js';
import type { TaskRepository } from '../../src/tasks/repository.js';
import { createInMemoryTaskRepository } from './in-memory-task-repository.js';

export async function buildTestApp(
  repository: TaskRepository = createInMemoryTaskRepository(),
): Promise<FastifyInstance> {
  const app = await buildApp({ config: { LOG_LEVEL: 'silent' }, repository });
  await app.ready();
  return app;
}
