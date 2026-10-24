import { Type, type Static } from 'typebox';
import { Value } from 'typebox/value';

const ConfigSchema = Type.Object({
  NODE_ENV: Type.Union(
    [Type.Literal('development'), Type.Literal('test'), Type.Literal('production')],
    {
      default: 'production',
    },
  ),
  HOST: Type.String({ default: '0.0.0.0' }),
  PORT: Type.Integer({ minimum: 1, maximum: 65535, default: 3000 }),
  LOG_LEVEL: Type.Union(
    ['fatal', 'error', 'warn', 'info', 'debug', 'trace', 'silent'].map((level) =>
      Type.Literal(level),
    ),
    { default: 'info' },
  ),

  DB_HOST: Type.String({ minLength: 1 }),
  DB_PORT: Type.Integer({ minimum: 1, maximum: 65535, default: 5432 }),
  DB_NAME: Type.String({ minLength: 1 }),
  DB_USER: Type.String({ minLength: 1 }),
  DB_PASSWORD: Type.String({ minLength: 1 }),
  // RDS for PostgreSQL 15+ enforces TLS (rds.force_ssl=1); only local Postgres turns this off.
  DB_SSL: Type.Boolean({ default: true }),
  // PEM bundle used to verify the server certificate; Node's default store does not include the RDS CA.
  DB_SSL_CA_FILE: Type.Optional(Type.String({ minLength: 1 })),
  // Budget: peak tasks (including deployment overlap) x DB_POOL_MAX must stay below max_connections.
  DB_POOL_MAX: Type.Integer({ minimum: 1, maximum: 100, default: 10 }),
  DB_STATEMENT_TIMEOUT_MS: Type.Integer({ minimum: 100, default: 5000 }),
});

export type Config = Static<typeof ConfigSchema>;

export class ConfigError extends Error {}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  // An empty string (common in compose files and CI) means "unset", so defaults still apply.
  const provided = Object.fromEntries(Object.entries(env).filter(([, value]) => value !== ''));
  const candidate = Value.Clean(
    ConfigSchema,
    Value.Convert(ConfigSchema, Value.Default(ConfigSchema, provided)),
  );

  if (!Value.Check(ConfigSchema, candidate)) {
    const problems = [...Value.Errors(ConfigSchema, candidate)].map(
      (error) => `${error.instancePath || '/'} ${error.message}`,
    );
    throw new ConfigError(`Invalid configuration: ${problems.join('; ')}`);
  }
  return candidate;
}
