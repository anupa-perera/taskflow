import type { FastifyError } from 'fastify';
import { describe, expect, it } from 'vitest';
import { NotFoundError, problem, toProblem } from '../src/errors.js';
import { HTTP_STATUS } from '../src/http-status.js';

const fastifyError = (fields: Partial<FastifyError>): FastifyError =>
  Object.assign(new Error(fields.message ?? 'boom'), fields) as FastifyError;

describe('problem', () => {
  it('derives the title from the status code', () => {
    expect(problem(HTTP_STATUS.NOT_FOUND)).toEqual({
      type: 'about:blank',
      title: 'Not Found',
      status: HTTP_STATUS.NOT_FOUND,
    });
  });
});

describe('toProblem', () => {
  it('maps validation errors to 400 with dotted field paths', () => {
    const error = fastifyError({
      validationContext: 'body',
      validation: [
        {
          keyword: 'required',
          instancePath: '',
          schemaPath: '',
          params: { missingProperty: 'title' },
          message: "must have required property 'title'",
        },
        {
          keyword: 'additionalProperties',
          instancePath: '',
          schemaPath: '',
          params: { additionalProperty: 'colour' },
          message: 'must NOT have additional properties',
        },
        {
          keyword: 'maxLength',
          instancePath: '/description',
          schemaPath: '',
          params: {},
          message: 'must NOT have more than 2000 characters',
        },
      ],
    });

    const result = toProblem(error);

    expect(result.status).toBe(HTTP_STATUS.BAD_REQUEST);
    expect(result.detail).toBe('Invalid body');
    expect(result.errors?.map((issue) => issue.field)).toEqual([
      'body.title',
      'body.colour',
      'body.description',
    ]);
  });

  it('replaces regex-echoing pattern messages with plain language', () => {
    const error = fastifyError({
      validationContext: 'body',
      validation: [
        {
          keyword: 'pattern',
          instancePath: '/title',
          schemaPath: '',
          params: { pattern: '^\\s*[^\\s\\u0000][^\\u0000]*$' },
          message: 'must match pattern "^\\s*[^\\s\\u0000][^\\u0000]*$"',
        },
      ],
    });

    expect(toProblem(error).errors?.[0]?.message).toBe(
      'must not be blank or contain NUL characters',
    );
  });

  it('maps NotFoundError to 404 with its message', () => {
    const result = toProblem(new NotFoundError('Task 1 not found') as FastifyError);

    expect(result).toMatchObject({ status: HTTP_STATUS.NOT_FOUND, detail: 'Task 1 not found' });
  });

  it("passes through Fastify's own client errors", () => {
    const result = toProblem(
      fastifyError({
        statusCode: HTTP_STATUS.UNSUPPORTED_MEDIA_TYPE,
        message: 'Unsupported Media Type',
      }),
    );

    expect(result).toMatchObject({
      status: HTTP_STATUS.UNSUPPORTED_MEDIA_TYPE,
      title: 'Unsupported Media Type',
    });
  });

  it('hides the message of unexpected errors', () => {
    const result = toProblem(fastifyError({ message: 'relation "tasks" does not exist' }));

    expect(result.status).toBe(HTTP_STATUS.INTERNAL_SERVER_ERROR);
    expect(result.detail).not.toContain('relation');
  });

  it('treats a 5xx statusCode as unexpected', () => {
    const result = toProblem(
      fastifyError({
        statusCode: HTTP_STATUS.SERVICE_UNAVAILABLE,
        message: 'pool exhausted at 10.0.0.1',
      }),
    );

    expect(result.status).toBe(HTTP_STATUS.INTERNAL_SERVER_ERROR);
    expect(result.detail).not.toContain('10.0.0.1');
  });
});
