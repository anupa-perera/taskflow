import { describe, expect, it } from 'vitest';
import { ConfigError, loadConfig, loadMigrateConfig } from '../src/config.js';

// Non-ASCII but invisible, the kind of character that breaks SCRAM without SASLprep.
const NON_BREAKING_SPACE = String.fromCharCode(0xa0);

const REQUIRED_DB_ENV = {
  DB_HOST: 'localhost',
  DB_NAME: 'taskflow',
  DB_USER: 'taskflow_app',
  DB_PASSWORD: 'secret',
};

describe('loadConfig', () => {
  it('applies defaults when only the required values are set', () => {
    expect(loadConfig(REQUIRED_DB_ENV)).toMatchObject({
      HOST: '0.0.0.0',
      PORT: 3000,
      LOG_LEVEL: 'info',
      DB_PORT: 5432,
      DB_SSL: true,
      DB_POOL_MAX: 10,
      DB_STATEMENT_TIMEOUT_MS: 5000,
      SHUTDOWN_TIMEOUT_MS: 25_000,
    });
  });

  it('converts numeric and boolean text', () => {
    const config = loadConfig({ ...REQUIRED_DB_ENV, PORT: '8080', DB_SSL: 'false' });

    expect(config.PORT).toBe(8080);
    expect(config.DB_SSL).toBe(false);
  });

  it('treats an empty string as unset', () => {
    expect(loadConfig({ ...REQUIRED_DB_ENV, PORT: '' }).PORT).toBe(3000);
  });

  it('drops variables it does not know', () => {
    expect(loadConfig({ ...REQUIRED_DB_ENV, PATH: '/usr/bin' })).not.toHaveProperty('PATH');
  });

  it('lists every missing variable at once', () => {
    expect(() => loadConfig({})).toThrow(/DB_HOST, DB_NAME, DB_USER, DB_PASSWORD/);
  });

  it.each([
    ['fractional integer', { PORT: '3000.9' }, /PORT must be integer/],
    ['boolean text as integer', { PORT: 'true' }, /PORT must be integer/],
    ['non-boolean text', { DB_SSL: 'yes' }, /DB_SSL must be boolean/],
    ['port above 65535', { PORT: '65536' }, /PORT must be <= 65535/],
    ['shutdown at the ECS stop timeout', { SHUTDOWN_TIMEOUT_MS: '30000' }, /must be <= 29000/],
    ['unknown log level', { LOG_LEVEL: 'verbose' }, /LOG_LEVEL/],
  ])('rejects a %s', (_case, overrides, message) => {
    expect(() => loadConfig({ ...REQUIRED_DB_ENV, ...overrides })).toThrow(message);
  });

  it('throws ConfigError so callers can tell config problems apart', () => {
    expect(() => loadConfig({})).toThrow(ConfigError);
  });

  it('never echoes a secret in the error message', () => {
    let message = '';
    try {
      loadConfig({ ...REQUIRED_DB_ENV, DB_PASSWORD: 'hunter2-secret', PORT: 'x' });
    } catch (error) {
      message = error instanceof Error ? error.message : '';
    }

    expect(message).toContain('PORT');
    expect(message).not.toContain('hunter2-secret');
  });
});

describe('loadMigrateConfig', () => {
  it('defaults the application role name', () => {
    const config = loadMigrateConfig({ ...REQUIRED_DB_ENV, APP_DB_PASSWORD: 'a'.repeat(16) });

    expect(config.APP_DB_USER).toBe('taskflow_app');
  });

  it('reports a non-ASCII password without echoing it', () => {
    const secret = `hunter2-${'x'.repeat(16)}${NON_BREAKING_SPACE}`;
    let message = '';
    try {
      loadMigrateConfig({ ...REQUIRED_DB_ENV, APP_DB_PASSWORD: secret });
    } catch (error) {
      message = error instanceof Error ? error.message : '';
    }

    expect(message).toContain('APP_DB_PASSWORD');
    expect(message).not.toContain('hunter2');
  });

  it.each([
    ['a short app password', { APP_DB_PASSWORD: 'short' }],
    ['an unsafe role name', { APP_DB_PASSWORD: 'a'.repeat(16), APP_DB_USER: 'Robert"; DROP' }],
    ['a non-ASCII app password', { APP_DB_PASSWORD: `${'a'.repeat(16)}${NON_BREAKING_SPACE}` }],
  ])('rejects %s', (_case, overrides) => {
    expect(() => loadMigrateConfig({ ...REQUIRED_DB_ENV, ...overrides })).toThrow(ConfigError);
  });
});
