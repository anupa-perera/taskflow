import { buildApp } from './app.js';
import { loadConfig } from './config.js';
import { createPool } from './db.js';

const config = loadConfig();
const pool = createPool(config);
const app = buildApp({ config, pool });

// An idle client losing its connection (e.g. RDS failover) emits here; unhandled, it crashes the process.
pool.on('error', (error) => {
  app.log.error({ err: error }, 'idle database client error');
});

let shuttingDown = false;

// ECS deregisters the task from the ALB and waits out the deregistration delay *before* sending
// SIGTERM, so no new traffic arrives here; we only need to finish in-flight work within stopTimeout.
async function shutdown(signal: NodeJS.Signals): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  app.log.info({ signal }, 'shutdown started');
  try {
    await app.close(); // stops accepting connections, waits for in-flight requests
    await pool.end(); // then releases database connections
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
