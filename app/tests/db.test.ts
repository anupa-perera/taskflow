import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterAll, describe, expect, it } from 'vitest';
import { loadConfig } from '../src/config.js';
import { connectionOptions, createPool, queryTimeouts } from '../src/db.js';

const baseEnv = { DB_HOST: 'db', DB_NAME: 'taskflow', DB_USER: 'app', DB_PASSWORD: 'secret' };
const tempDir = mkdtempSync(path.join(tmpdir(), 'taskflow-db-test-'));

afterAll(() => {
  rmSync(tempDir, { recursive: true, force: true });
});

describe('connectionOptions', () => {
  it('disables TLS only when DB_SSL is false', () => {
    expect(connectionOptions(loadConfig({ ...baseEnv, DB_SSL: 'false' })).ssl).toBe(false);
  });

  it('verifies the server certificate by default', () => {
    expect(connectionOptions(loadConfig(baseEnv)).ssl).toEqual({ rejectUnauthorized: true });
  });

  it('trusts the CA bundle from DB_SSL_CA_FILE', () => {
    const caFile = path.join(tempDir, 'rds-ca.pem');
    writeFileSync(caFile, 'PEM-CONTENT');

    const options = connectionOptions(loadConfig({ ...baseEnv, DB_SSL_CA_FILE: caFile }));

    expect(options.ssl).toEqual({ rejectUnauthorized: true, ca: 'PEM-CONTENT' });
  });

  it('sets a client-side query timeout just above the statement timeout', () => {
    const options = connectionOptions(loadConfig({ ...baseEnv, DB_STATEMENT_TIMEOUT_MS: '2000' }));

    expect(options.statement_timeout).toBe(2000);
    expect(options.query_timeout).toBeGreaterThan(2000);
  });
});

describe('queryTimeouts', () => {
  it('keeps the client timeout behind the server timeout', () => {
    const { statement_timeout, query_timeout } = queryTimeouts(5000);

    expect(query_timeout).toBeGreaterThan(statement_timeout);
  });
});

describe('createPool', () => {
  it('caps the pool at DB_POOL_MAX without connecting', async () => {
    const pool = createPool(loadConfig({ ...baseEnv, DB_POOL_MAX: '3' }));

    expect(pool.options.max).toBe(3);
    expect(pool.totalCount).toBe(0);
    await pool.end();
  });
});
