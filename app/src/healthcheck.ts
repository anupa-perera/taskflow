// Container health probe for ECS and Docker: the distroless image has no shell or curl.
import { loadConfig } from './config.js';
import { HTTP_STATUS } from './http-status.js';

// Well inside the ECS health check timeout, so a hung server fails the probe instead of hanging it.
const PROBE_TIMEOUT_MS = 2_000;

const { PORT } = loadConfig();

try {
  const response = await fetch(`http://127.0.0.1:${String(PORT)}/health`, {
    signal: AbortSignal.timeout(PROBE_TIMEOUT_MS),
  });
  process.exit(response.status === HTTP_STATUS.OK ? 0 : 1);
} catch {
  process.exit(1);
}
