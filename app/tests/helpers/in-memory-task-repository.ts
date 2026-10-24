import { randomUUID } from 'node:crypto';
import type { ListOptions, TaskRepository } from '../../src/tasks/repository.js';
import type { CreateTaskBody, Task, UpdateTaskBody } from '../../src/tasks/types.js';

// Test double for route tests; production storage is always Postgres.
export function createInMemoryTaskRepository(seed: Task[] = []): TaskRepository {
  const tasks = new Map(seed.map((task) => [task.id, task]));

  return {
    create(input: CreateTaskBody) {
      const now = new Date().toISOString();
      const task: Task = {
        id: randomUUID(),
        title: input.title,
        description: input.description ?? null,
        status: input.status ?? 'todo',
        createdAt: now,
        updatedAt: now,
      };
      tasks.set(task.id, task);
      return Promise.resolve(task);
    },

    list({ status, limit, offset }: ListOptions) {
      const matching = [...tasks.values()]
        .filter((task) => status === undefined || task.status === status)
        .sort((a, b) => b.createdAt.localeCompare(a.createdAt) || b.id.localeCompare(a.id));
      return Promise.resolve(matching.slice(offset, offset + limit));
    },

    get(id: string) {
      return Promise.resolve(tasks.get(id));
    },

    update(id: string, changes: UpdateTaskBody) {
      const existing = tasks.get(id);
      if (!existing) return Promise.resolve(undefined);
      const updated: Task = { ...existing, ...changes, updatedAt: new Date().toISOString() };
      tasks.set(id, updated);
      return Promise.resolve(updated);
    },

    remove(id: string) {
      return Promise.resolve(tasks.delete(id));
    },
  };
}
