// One-off migration task, run as the master user (ADR 0002).
import path from 'node:path';
import { runner } from 'node-pg-migrate';
import pg from 'pg';
import { pino } from 'pino';
import { loadMigrateConfig, type MigrateConfig } from './config.js';
import { connectionOptions, queryTimeouts } from './db.js';
import { scramSha256Verifier } from './scram.js';

const log = pino({ name: 'migrate' });

async function ensureAppRole(client: pg.Client, config: MigrateConfig): Promise<void> {
  const role = pg.escapeIdentifier(config.APP_DB_USER);
  const roleName = pg.escapeLiteral(config.APP_DB_USER);
  // ALTER ROLE takes no bind parameters, so the statement text could reach slow-query or error
  // logs: it carries a salted SCRAM verifier, never the password. Re-applied each run so the role
  // tracks the secret.
  const verifier = pg.escapeLiteral(scramSha256Verifier(config.APP_DB_PASSWORD));

  await client.query(`
    DO $$ BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = ${roleName}) THEN
        CREATE ROLE ${role} LOGIN;
      END IF;
    END $$;
    ALTER ROLE ${role} WITH LOGIN PASSWORD ${verifier};
    GRANT CONNECT ON DATABASE ${pg.escapeIdentifier(config.DB_NAME)} TO ${role};
    GRANT USAGE ON SCHEMA public TO ${role};
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ${role};
    REVOKE ALL ON TABLE pgmigrations FROM ${role};
  `);
}

const config = loadMigrateConfig();
// Covers DDL and waiting behind a concurrent run's lock.
const MIGRATION_TIMEOUT_MS = 300_000;
const client = new pg.Client({
  ...connectionOptions(config),
  ...queryTimeouts(MIGRATION_TIMEOUT_MS),
});

try {
  await client.connect();
  // Spans role provisioning too, so concurrent deploys queue instead of racing to CREATE ROLE.
  await client.query(`SELECT pg_advisory_lock(hashtext('taskflow:migrate'))`);
  const applied = await runner({
    dbClient: client,
    dir: path.join(import.meta.dirname, 'migrations'),
    direction: 'up',
    migrationsTable: 'pgmigrations',
    noLock: true, // the outer lock above already serialises runs
    logger: log,
  });
  await ensureAppRole(client, config);
  await client.query(`SELECT pg_advisory_unlock(hashtext('taskflow:migrate'))`);
  log.info({ applied: applied.map((migration) => migration.name) }, 'migrations complete');
  await client.end();
} catch (error) {
  log.fatal({ err: error }, 'migrations failed');
  await client.end().catch(() => undefined);
  process.exit(1);
}
