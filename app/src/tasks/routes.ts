import type { FastifyPluginAsyncTypebox } from '@fastify/type-provider-typebox';
import { Type } from 'typebox';
import { NotFoundError } from '../errors.js';
import { HTTP_STATUS } from '../http-status.js';
import { BadRequestResponse, notFoundResponse } from '../openapi-responses.js';
import type { TaskRepository } from './repository.js';
import {
  CreateTaskBodySchema,
  DEFAULT_OFFSET,
  DEFAULT_PAGE_SIZE,
  ListTasksQuerySchema,
  TaskSchema,
  TaskListSchema,
  TaskParamsSchema,
  UpdateTaskBodySchema,
} from './schema.js';

const TaskNotFoundResponse = notFoundResponse('task');

export const taskRoutes: FastifyPluginAsyncTypebox<{ repository: TaskRepository }> = (
  app,
  { repository },
) => {
  const tags = ['tasks'];
  const taskNotFound = (id: string) => new NotFoundError(`Task ${id} not found`);

  app.post(
    '/tasks',
    {
      schema: {
        tags,
        summary: 'Create a task',
        body: CreateTaskBodySchema,
        response: { [HTTP_STATUS.CREATED]: TaskSchema, ...BadRequestResponse },
      },
    },
    async (request, reply) => {
      const task = await repository.create(request.body);
      return reply.status(HTTP_STATUS.CREATED).header('location', `/tasks/${task.id}`).send(task);
    },
  );

  app.get(
    '/tasks',
    {
      schema: {
        tags,
        summary: 'List tasks, newest first',
        querystring: ListTasksQuerySchema,
        response: { [HTTP_STATUS.OK]: TaskListSchema, ...BadRequestResponse },
      },
    },
    async (request) => {
      const { status, limit = DEFAULT_PAGE_SIZE, offset = DEFAULT_OFFSET } = request.query;
      const items = await repository.list({ status, limit, offset });
      return { items, limit, offset };
    },
  );

  app.get(
    '/tasks/:id',
    {
      schema: {
        tags,
        summary: 'Get a task',
        params: TaskParamsSchema,
        response: { [HTTP_STATUS.OK]: TaskSchema, ...BadRequestResponse, ...TaskNotFoundResponse },
      },
    },
    async (request) => {
      const task = await repository.get(request.params.id);
      if (!task) throw taskNotFound(request.params.id);
      return task;
    },
  );

  app.patch(
    '/tasks/:id',
    {
      schema: {
        tags,
        summary: 'Update some fields of a task',
        params: TaskParamsSchema,
        body: UpdateTaskBodySchema,
        response: { [HTTP_STATUS.OK]: TaskSchema, ...BadRequestResponse, ...TaskNotFoundResponse },
      },
    },
    async (request) => {
      const task = await repository.update(request.params.id, request.body);
      if (!task) throw taskNotFound(request.params.id);
      return task;
    },
  );

  app.delete(
    '/tasks/:id',
    {
      schema: {
        tags,
        summary: 'Delete a task',
        params: TaskParamsSchema,
        response: {
          [HTTP_STATUS.NO_CONTENT]: Type.Null(),
          ...BadRequestResponse,
          ...TaskNotFoundResponse,
        },
      },
    },
    async (request, reply) => {
      if (!(await repository.remove(request.params.id))) throw taskNotFound(request.params.id);
      return reply.status(HTTP_STATUS.NO_CONTENT).send(null);
    },
  );

  return Promise.resolve();
};
