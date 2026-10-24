import { readFileSync } from 'node:fs';
import pg from 'pg';
import type { Config } from './config.js';

export function createPool(config: Config): pg.Pool {
  return new pg.Pool({
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
    max: config.DB_POOL_MAX,
    // Fail fast instead of queueing forever when the pool is exhausted or RDS is unreachable.
    connectionTimeoutMillis: 5_000,
    idleTimeoutMillis: 30_000,
    statement_timeout: config.DB_STATEMENT_TIMEOUT_MS,
  });
}
