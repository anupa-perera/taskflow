import { buildApp } from './app.js';
import { loadConfig } from './config.js';
import { createPool } from './db.js';

const config = loadConfig();
const pool = createPool(config);
const app = await buildApp({ config, pool });

// Unhandled, an idle client's connection loss (e.g. RDS failover) crashes the process.
pool.on('error', (error) => {
  app.log.error({ err: error }, 'idle database client error');
});

let shuttingDown = false;

// ECS deregisters the task from the ALB before SIGTERM, so only in-flight requests remain (ADR 0002).
async function shutdown(signal: NodeJS.Signals): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  app.log.info({ signal }, 'shutdown started');
  // If draining hangs, fail loudly before ECS SIGKILLs us silently.
  setTimeout(() => {
    app.log.error({ timeoutMs: config.SHUTDOWN_TIMEOUT_MS }, 'shutdown timed out');
    process.exit(1);
  }, config.SHUTDOWN_TIMEOUT_MS).unref();
  try {
    await app.close();
    await pool.end();
    app.log.info('shutdown complete');
    process.exit(0);
  } catch (error) {
    app.log.error({ err: error }, 'shutdown failed');
    process.exit(1);
  }
}

process.once('SIGTERM', (signal) => void shutdown(signal));
process.once('SIGINT', (signal) => void shutdown(signal));

try {
  await app.listen({ host: config.HOST, port: config.PORT });
} catch (error) {
  app.log.fatal({ err: error }, 'failed to start');
  await pool.end();
  process.exit(1);
}
