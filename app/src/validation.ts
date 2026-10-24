import Ajv, { type AnySchema } from 'ajv';
import addFormats from 'ajv-formats';
import type { FastifySchemaCompiler } from 'fastify';

// URL values arrive as text and need coercion; coercing JSON bodies would turn "" into null.
function createAjv(coerceTypes: 'array' | false) {
  return addFormats.default(
    new Ajv.default({ coerceTypes, useDefaults: true, removeAdditional: false, allErrors: true }),
  );
}

const bodyAjv = createAjv(false);
const urlAjv = createAjv('array');

export const validatorCompiler: FastifySchemaCompiler<AnySchema> = ({ schema, httpPart }) =>
  (httpPart === 'body' ? bodyAjv : urlAjv).compile(schema);
