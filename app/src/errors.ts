import { STATUS_CODES } from 'node:http';
import type {
  FastifyError,
  FastifyInstance,
  FastifyReply,
  FastifyRequest,
  FastifySchemaValidationError,
} from 'fastify';
import { Type, type Static } from 'typebox';
import { HTTP_STATUS, isClientError } from './http-status.js';
import { patternMessage } from './patterns.js';

// RFC 9457 "Problem Details for HTTP APIs".
export const ProblemDetails = Type.Object(
  {
    type: Type.String(),
    title: Type.String(),
    status: Type.Integer(),
    detail: Type.Optional(Type.String()),
    instance: Type.Optional(Type.String()),
    errors: Type.Optional(
      Type.Array(Type.Object({ field: Type.String(), message: Type.String() })),
    ),
  },
  { $id: 'ProblemDetails' },
);
export type ProblemDetails = Static<typeof ProblemDetails>;

export class NotFoundError extends Error {
  override name = 'NotFoundError';
}

export function problem(
  status: number,
  extras: Omit<ProblemDetails, 'type' | 'title' | 'status'> = {},
): ProblemDetails {
  // RFC default: with "about:blank" the status and its standard title carry the meaning.
  return { type: 'about:blank', title: STATUS_CODES[status] ?? 'Error', status, ...extras };
}

// "body" + "/title" -> "body.title"; Ajv reports missing and unknown properties on the parent.
function fieldOf(context: string | undefined, issue: FastifySchemaValidationError): string {
  const segments = issue.instancePath.split('/').filter(Boolean);
  const { missingProperty, additionalProperty } = issue.params;
  const property = missingProperty ?? additionalProperty;
  if (typeof property === 'string') segments.push(property);
  return [context ?? 'request', ...segments].join('.');
}

export function toProblem(error: FastifyError): ProblemDetails {
  if (error.validation) {
    return problem(HTTP_STATUS.BAD_REQUEST, {
      detail: `Invalid ${error.validationContext ?? 'request'}`,
      errors: error.validation.map((issue) => ({
        field: fieldOf(error.validationContext, issue),
        message:
          (typeof issue.params.pattern === 'string' && patternMessage(issue.params.pattern)) ||
          (issue.message ?? 'is invalid'),
      })),
    });
  }

  if (error instanceof NotFoundError) {
    return problem(HTTP_STATUS.NOT_FOUND, { detail: error.message });
  }

  // Fastify's 4xx messages describe the caller's own request, so they are safe to return.
  const status = error.statusCode;
  if (status !== undefined && isClientError(status)) {
    return problem(status, { detail: error.message });
  }

  // Unexpected errors may carry SQL or hostnames: the client gets the request id, the log gets the rest.
  return problem(HTTP_STATUS.INTERNAL_SERVER_ERROR, {
    detail: 'An unexpected error occurred. Quote the request id when reporting it.',
  });
}

// Malformed URLs (e.g. /tasks/%ZZ) fail before routing, so hooks and the error handler never run.
export function handleFrameworkError(
  error: FastifyError,
  request: FastifyRequest,
  reply: FastifyReply,
): void {
  void reply
    .status(HTTP_STATUS.BAD_REQUEST)
    .header('x-request-id', request.id)
    .type('application/problem+json')
    .send(problem(HTTP_STATUS.BAD_REQUEST, { detail: error.message }));
}

export function registerErrorHandling(app: FastifyInstance): void {
  app.setErrorHandler((error: FastifyError, request, reply) => {
    const body = toProblem(error);
    // 4xx already appear in the request log; 5xx also need the stack trace.
    if (body.status >= HTTP_STATUS.INTERNAL_SERVER_ERROR)
      request.log.error({ err: error }, 'request failed');
    return reply
      .status(body.status)
      .type('application/problem+json')
      .send({ ...body, instance: request.url });
  });

  app.setNotFoundHandler((request, reply) =>
    reply
      .status(HTTP_STATUS.NOT_FOUND)
      .type('application/problem+json')
      .send(
        problem(HTTP_STATUS.NOT_FOUND, {
          detail: `Route ${request.method} ${request.url} not found`,
        }),
      ),
  );
}
