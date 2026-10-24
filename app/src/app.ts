import { randomUUID } from 'node:crypto';
import Fastify, { type FastifyInstance } from 'fastify';
import swagger from '@fastify/swagger';
import swaggerUi from '@fastify/swagger-ui';
import type { TypeBoxTypeProvider } from '@fastify/type-provider-typebox';
import { Type } from 'typebox';
import type pg from 'pg';
import type { Config } from './config.js';
import { HTTP_STATUS } from './http-status.js';
import { handleFrameworkError, ProblemDetails, registerErrorHandling } from './errors.js';
import { createTaskRepository } from './tasks/repository.js';
import { taskRoutes } from './tasks/routes.js';
import { validatorCompiler } from './validation.js';

// The largest valid task is a few KB; Fastify's 1 MiB default only feeds validation work.
const MAX_REQUEST_BODY_BYTES = 64 * 1024;

export interface AppDependencies {
  config: Pick<Config, 'LOG_LEVEL'>;
  pool: pg.Pool;
}

export async function buildApp({ config, pool }: AppDependencies): Promise<FastifyInstance> {
  const app = Fastify({
    logger: {
      level: config.LOG_LEVEL,
      redact: ['req.headers.authorization', 'req.headers.cookie'],
    },
    requestIdHeader: 'x-request-id',
    // Fastify's default ids are a per-process counter, which collide across ECS tasks.
    genReqId: () => randomUUID(),
    bodyLimit: MAX_REQUEST_BODY_BYTES,
    frameworkErrors: handleFrameworkError,
  }).withTypeProvider<TypeBoxTypeProvider>();

  app.setValidatorCompiler(validatorCompiler);
  app.addHook('onRequest', async (request, reply) => {
    reply.header('x-request-id', request.id);
  });
  registerErrorHandling(app);
  app.addSchema(ProblemDetails);

  await app.register(swagger, {
    openapi: {
      info: {
        title: 'TaskFlow API',
        version: '1.0.0',
        description: 'Internal task management service',
      },
      tags: [{ name: 'tasks' }, { name: 'ops' }],
    },
  });
  await app.register(swaggerUi, { routePrefix: '/docs' });

  // Liveness only: a database outage must not make ECS restart every task (see ADR 0002).
  app.get(
    '/health',
    {
      schema: {
        tags: ['ops'],
        summary: 'Liveness probe for the ALB and ECS',
        response: { [HTTP_STATUS.OK]: Type.Object({ status: Type.Literal('ok') }) },
      },
    },
    () => ({ status: 'ok' as const }),
  );

  await app.register(taskRoutes, { repository: createTaskRepository(pool) });

  return app;
}
