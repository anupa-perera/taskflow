import Fastify, { type FastifyInstance } from 'fastify';
import type { TypeBoxTypeProvider } from '@fastify/type-provider-typebox';
import { Type } from 'typebox';
import type pg from 'pg';
import type { Config } from './config.js';

export interface AppDependencies {
  config: Pick<Config, 'LOG_LEVEL'>;
  pool: pg.Pool;
}

export function buildApp({ config }: AppDependencies): FastifyInstance {
  const app = Fastify({
    logger: {
      level: config.LOG_LEVEL,
      redact: ['req.headers.authorization', 'req.headers.cookie'],
    },
    // Fastify generates a request id per request and adds it to every log line for that request.
    requestIdHeader: 'x-request-id',
  }).withTypeProvider<TypeBoxTypeProvider>();

  // Liveness only: a database outage must not make ECS restart every task (see ADR 0002).
  app.get(
    '/health',
    { schema: { response: { 200: Type.Object({ status: Type.Literal('ok') }) } } },
    () => ({ status: 'ok' as const }),
  );

  return app;
}
