import { Type, type Static, type TObject } from 'typebox';
import { Value } from 'typebox/value';
import { PATTERNS } from './patterns.js';

const MAX_TCP_PORT = 65_535;
const DEFAULT_HTTP_PORT = 3000;
const DEFAULT_POSTGRES_PORT = 5432;
const MIN_STATEMENT_TIMEOUT_MS = 100;
const DEFAULT_STATEMENT_TIMEOUT_MS = 5_000;
const DEFAULT_POOL_SIZE = 10;
const MAX_POOL_SIZE = 100;
// Must match the container stopTimeout in the ECS task definition.
const ECS_STOP_TIMEOUT_MS = 30_000;
// One second of headroom to log the timeout before ECS sends SIGKILL.
const MAX_SHUTDOWN_TIMEOUT_MS = ECS_STOP_TIMEOUT_MS - 1_000;
const MIN_SHUTDOWN_TIMEOUT_MS = 1_000;
const DEFAULT_SHUTDOWN_TIMEOUT_MS = 25_000;
const MIN_APP_DB_PASSWORD_LENGTH = 16;

const tcpPort = (defaultPort: number) =>
  Type.Integer({ minimum: 1, maximum: MAX_TCP_PORT, default: defaultPort });

const databaseProperties = {
  DB_HOST: Type.String({ minLength: 1 }),
  DB_PORT: tcpPort(DEFAULT_POSTGRES_PORT),
  DB_NAME: Type.String({ minLength: 1 }),
  DB_USER: Type.String({ minLength: 1 }),
  DB_PASSWORD: Type.String({ minLength: 1 }),
  // RDS for PostgreSQL 15+ enforces TLS (rds.force_ssl=1).
  DB_SSL: Type.Boolean({ default: true }),
  // Node's default CA store does not include the RDS CA.
  DB_SSL_CA_FILE: Type.Optional(Type.String({ minLength: 1 })),
  DB_STATEMENT_TIMEOUT_MS: Type.Integer({
    minimum: MIN_STATEMENT_TIMEOUT_MS,
    default: DEFAULT_STATEMENT_TIMEOUT_MS,
  }),
};

const ConfigSchema = Type.Object({
  ...databaseProperties,
  HOST: Type.String({ default: '0.0.0.0' }),
  PORT: tcpPort(DEFAULT_HTTP_PORT),
  LOG_LEVEL: Type.Enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace', 'silent'], {
    default: 'info',
  }),
  // Peak tasks (including deployment overlap) x DB_POOL_MAX must stay below max_connections.
  DB_POOL_MAX: Type.Integer({ minimum: 1, maximum: MAX_POOL_SIZE, default: DEFAULT_POOL_SIZE }),
  SHUTDOWN_TIMEOUT_MS: Type.Integer({
    minimum: MIN_SHUTDOWN_TIMEOUT_MS,
    maximum: MAX_SHUTDOWN_TIMEOUT_MS,
    default: DEFAULT_SHUTDOWN_TIMEOUT_MS,
  }),
});

const MigrateConfigSchema = Type.Object({
  ...databaseProperties,
  APP_DB_USER: Type.String({ pattern: PATTERNS.postgresRoleName.regex, default: 'taskflow_app' }),
  APP_DB_PASSWORD: Type.String({
    minLength: MIN_APP_DB_PASSWORD_LENGTH,
    pattern: PATTERNS.printableAscii.regex,
  }),
});

export type Config = Static<typeof ConfigSchema>;
export type MigrateConfig = Static<typeof MigrateConfigSchema>;
export type DatabaseConfig = Pick<Config, keyof typeof databaseProperties>;

export class ConfigError extends Error {}

// Value.Convert is lenient ("3000.9" -> 3000, "true" -> 1), so these are checked as text first.
const DIGITS_ONLY = /^\d+$/;
const TRUE_OR_FALSE = /^(true|false)$/;
const STRICT_TEXT: Partial<Record<string, RegExp>> = {
  integer: DIGITS_ONLY,
  boolean: TRUE_OR_FALSE,
};

function parseEnv<Schema extends TObject>(schema: Schema, env: NodeJS.ProcessEnv): Static<Schema> {
  // Compose files and CI often set "" to mean unset.
  const provided = Object.fromEntries(
    Object.entries(env).filter((entry): entry is [string, string] => entry[1] !== ''),
  );

  const malformed = Object.entries(schema.properties).flatMap(([key, property]) => {
    const type = 'type' in property && typeof property.type === 'string' ? property.type : '';
    const value = provided[key];
    return value !== undefined && STRICT_TEXT[type]?.test(value) === false
      ? [`/${key} must be ${type}, got "${value}"`]
      : [];
  });

  const candidate = Value.Clean(schema, Value.Convert(schema, Value.Default(schema, provided)));
  if (malformed.length === 0 && Value.Check(schema, candidate)) return candidate;

  const problems = [
    ...malformed,
    ...[...Value.Errors(schema, candidate)].map(
      (error) => `${error.instancePath || '/'} ${error.message}`,
    ),
  ];
  throw new ConfigError(`Invalid configuration: ${problems.join('; ')}`);
}

export const loadConfig = (env: NodeJS.ProcessEnv = process.env): Config =>
  parseEnv(ConfigSchema, env);

export const loadMigrateConfig = (env: NodeJS.ProcessEnv = process.env): MigrateConfig =>
  parseEnv(MigrateConfigSchema, env);
