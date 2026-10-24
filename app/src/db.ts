import { readFileSync } from 'node:fs';
import pg from 'pg';
import type { Config, DatabaseConfig } from './config.js';

const CONNECT_TIMEOUT_MS = 5_000;
const IDLE_CLIENT_TIMEOUT_MS = 30_000;
// Lets Postgres's own statement_timeout fire first, so its clearer error wins.
const QUERY_TIMEOUT_GRACE_MS = 1_000;

// statement_timeout runs in Postgres; query_timeout also frees the client when the network stalls.
export const queryTimeouts = (statementTimeoutMs: number) => ({
  statement_timeout: statementTimeoutMs,
  query_timeout: statementTimeoutMs + QUERY_TIMEOUT_GRACE_MS,
});

export function connectionOptions(config: DatabaseConfig): pg.ClientConfig {
  return {
    host: config.DB_HOST,
    port: config.DB_PORT,
    database: config.DB_NAME,
    user: config.DB_USER,
    password: config.DB_PASSWORD,
    ssl: config.DB_SSL
      ? {
          rejectUnauthorized: true,
          ...(config.DB_SSL_CA_FILE && { ca: readFileSync(config.DB_SSL_CA_FILE, 'utf8') }),
        }
      : false,
    connectionTimeoutMillis: CONNECT_TIMEOUT_MS,
    ...queryTimeouts(config.DB_STATEMENT_TIMEOUT_MS),
  };
}

export function createPool(config: Config): pg.Pool {
  return new pg.Pool({
    ...connectionOptions(config),
    max: config.DB_POOL_MAX,
    idleTimeoutMillis: IDLE_CLIENT_TIMEOUT_MS,
  });
}
